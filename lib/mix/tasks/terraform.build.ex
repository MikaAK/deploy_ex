defmodule Mix.Tasks.Terraform.Build do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()
  @default_aws_region DeployEx.Config.aws_region()

  @default_aws_release_bucket DeployEx.Config.aws_release_bucket()
  @default_aws_log_bucket DeployEx.Config.aws_log_bucket()

  @shortdoc "Builds/Updates terraform files or adds it to your project"
  @moduledoc """
  Builds or updates terraform files within the project.

  ## Options
  - `directory` - Directory for the terraform files (default: `#{@terraform_default_path}`)
  - `aws-region` - Region for aws (default: `#{@default_aws_region}`)
  - `aws-bucket` - Region for aws (default: `#{@default_aws_release_bucket}`)
  - `aws-log-bucket` - Region for aws (default: `#{@default_aws_log_bucket}`)
  - `availability-zone` - Shared AZ for monitoring/DB peer instances (default: aws-region's "a" zone)
  - `env` - Environment for terraform (default: `Mix.env()`)
  - `quiet` - Supress output
  - `force` - Force create files without asking
  - `verbose` - Log extra details about the process

  """

  def run(args) do
    opts = build_opts(args)

    with :ok <- DeployExHelpers.check_valid_project(),
         :ok <- DeployEx.ToolInstaller.ensure_installed(:terraform),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         :ok <- ensure_terraform_directory_exists(opts[:directory]) do
      random_bytes = 6 |> :crypto.strong_rand_bytes |> Base.encode32(padding: false)

      terraform_app_releases_variables = releases
        |> Keyword.keys
        |> Enum.map_join(",\n\n", &(&1 |> to_string |> generate_terraform_release_variables()))

      params = %{
        directory: opts[:directory],
        environment: opts[:env],

        aws_region: opts[:aws_region],
        aws_release_bucket: opts[:aws_release_bucket],

        use_db: !opts[:no_database],
        db_password: !opts[:no_database] && generate_db_password(),

        release_bucket_name: opts[:aws_release_bucket],
        logging_bucket_name: opts[:aws_log_bucket],

        aws_release_state_bucket: opts[:aws_release_state_bucket],
        aws_release_state_lock_table: opts[:aws_release_state_lock_table],

        terraform_backend: DeployEx.Config.terraform_backend(),

        pem_app_name: "#{DeployExHelpers.kebab_project_name()}-#{random_bytes}",
        app_name: DeployExHelpers.underscored_project_name(),
        kebab_app_name: DeployExHelpers.kebab_project_name(),

        use_loki: !opts[:no_logging],
        use_grafana: !opts[:no_grafana],
        use_prometheus: !opts[:no_prometheus],
        use_redis: !opts[:no_redis],
        use_sentry: !opts[:no_sentry],
        use_database: !opts[:no_database],

        terraform_app_releases_variables: terraform_app_releases_variables,
        terraform_release_variables: terraform_app_releases_variables,
        terraform_redis_variables: terraform_redis_variables(opts),
        terraform_sentry_variables: terraform_sentry_variables(opts),
        terraform_grafana_variables: terraform_grafana_variables(opts),
        terraform_loki_variables: terraform_loki_variables(opts),
        terraform_prometheus_variables: terraform_prometheus_variables(opts),
        terraform_mimir_variables: DeployEx.Mimir.terraform_variables(opts),
      }

      write_terraform_template_files(params, opts)

      DeployEx.Terraform.run_command_with_input(
        "init",
        params[:directory]
      )
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  @doc false
  def build_opts(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)
      |> Keyword.put_new(:aws_region, @default_aws_region)
      |> Keyword.put_new(:aws_release_bucket, @default_aws_release_bucket)
      |> Keyword.put_new(:aws_log_bucket, DeployEx.Config.aws_log_bucket())
      |> Keyword.put_new(:aws_release_state_bucket, DeployEx.Config.aws_release_state_bucket())
      |> Keyword.put_new(:aws_release_state_lock_table, DeployEx.Config.aws_release_state_lock_table())
      |> Keyword.put_new(:env, Mix.env())

    no_logging = opts[:no_logging] || opts[:no_loki] || false
    opts = Keyword.put(opts, :no_logging, no_logging)

    Keyword.put_new(opts, :availability_zone, DeployEx.Config.aws_availability_zone(opts[:aws_region]))
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, v: :verbose],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        verbose: :boolean,
        aws_region: :string,
        availability_zone: :string,
        env: :string,
        no_database: :boolean,
        no_logging: :boolean,
        no_loki: :boolean,
        no_sentry: :boolean,
        no_grafana: :boolean,
        no_redis: :boolean,
        no_prometheus: :boolean,
        no_mimir: :boolean
      ]
    )

    opts
  end

  defp ensure_terraform_directory_exists(directory) do
    if File.exists?(directory) do
      :ok
    else
      Mix.shell().info([:green, "* copying terraform into ", :reset, directory])

      File.mkdir_p!(directory)

      "terraform"
        |> DeployExHelpers.priv_folder()
        |> File.cp_r!(directory)

      directory
        |> Path.join("**/*.eex")
        |> Path.wildcard
        |> Enum.map(&File.rm!/1)

      :ok
    end
  end

  defp generate_terraform_release_variables(release_name) do
    String.trim_trailing("""
        #{release_name} = {
          name = "#{DeployEx.Utils.upper_title_case(release_name)}"
          tags = {
            Vendor = "Self"
            Type   = "Self Made"
          }

          # Autoscaling Configuration (optional)
          # Uncomment and configure to enable AWS Auto Scaling Groups
          # autoscaling = {
          #   enable             = true
          #   min_size           = 1
          #   max_size           = 5
          #   desired_capacity   = 2
          #   cpu_target_percent = 60
          # }
        }
    """, "\n")
  end

  defp terraform_redis_variables(opts) do
    if opts[:no_redis] do
      ""
    else
      """
          #{DeployExHelpers.underscored_project_name()}_redis = {
            name                       = "#{DeployExHelpers.title_case_project_name()} Redis"
            instance_availability_zone = "#{opts[:availability_zone]}"

            # This is a suggestion for instance

            instance_type = "r7g.medium"

            ebs = {
              enable_secondary = true
              secondary_size   = 16
            }

            tags = {
              Vendor      = "Redis"
              Type        = "Database"
              DatabaseKey = "#{DeployExHelpers.underscored_project_name()}_redis"
            }
          },
      """
    end
  end

  defp terraform_sentry_variables(opts) do
    if opts[:no_sentry] do
      ""
    else
      """
          sentry = {
            name                       = "Sentry Monitoring"
            enable_eip                 = true
            instance_type              = "t3.large"
            instance_availability_zone = "#{opts[:availability_zone]}"

            # Sized for getsentry/self-hosted's "errors-only" compose profile
            # (COMPOSE_PROFILES=errors-only in
            # priv/ansible/roles/sentry_server/templates/env.j2) — upstream's
            # install.sh hard-exits below 2 vCPU / 7000MB for that profile;
            # t3.large (2 vCPU / 8GB) clears it. The "feature-complete"
            # profile needs >= 4 vCPU / 14000MB (t3.large does NOT clear
            # this — a deterministic preflight exit, not an occasional
            # failure). To upgrade: raise instance_type here to >= 4
            # vCPU/14GB (e.g. t3.xlarge), set
            # COMPOSE_PROFILES=feature-complete in env.j2, then
            # `mix terraform.apply --target 'module.ec2_instance["sentry"]'`.
            ebs = {
              enable_secondary = true
              secondary_size   = 64
            }

            tags = {
              Vendor = "Sentry"
              Type   = "Monitoring"
              MonitoringKey = "sentry"
            }
          },
      """
    end
  end

  defp terraform_loki_variables(opts) do
    if opts[:no_logging] do
      ""
    else
      """
          loki_aggregator = {
            name                       = "Grafana Loki Logs"
            instance_type              = "t3.micro"
            instance_availability_zone = "#{opts[:availability_zone]}"

            ebs = {
              enable_secondary = true
              secondary_size   = 8
            }

            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "loki_logger"
            }
          },
      """
    end
  end

  defp terraform_grafana_variables(opts) do
    if opts[:no_grafana] do
      ""
    else
      """
          grafana_ui = {
            name                       = "Grafana UI"
            enable_eip                 = true
            instance_availability_zone = "#{opts[:availability_zone]}"

            ebs = {
              enable_secondary = true
              secondary_size   = 8
            }

            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "grafana_ui"
            }
          },
      """
    end
  end

  defp terraform_prometheus_variables(opts) do
    if opts[:no_prometheus] do
      ""
    else
      """
          prometheus_db = {
            name                       = "Prometheus Metrics Database"
            instance_type              = "t3.micro"
            instance_availability_zone = "#{opts[:availability_zone]}"

            ebs = {
              enable_secondary = true
              secondary_size   = 16
            }

            tags = {
              Vendor = "Grafana"
              Type   = "Monitoring"
              MonitoringKey = "prometheus_db"
            }
          },
      """
    end
  end

  defp generate_db_password do
    "SuperSecretPassword#{Enum.random(111_111..999_999)}"
  end

  defp write_terraform_template_files(params, opts) do
    terraform_path = DeployExHelpers.priv_folder("terraform")

    terraform_path
      |> Path.join("*.eex")
      |> Path.wildcard
      |> Enum.map(fn template_file ->
        template = EEx.eval_file(template_file, assigns: params)

        template_file
          |> String.replace(terraform_path, "")
          |> String.replace(".eex", "")
          |> then(&Path.join(params[:directory], &1))
          |> DeployExHelpers.write_file(template, opts)
      end)
  end
end
