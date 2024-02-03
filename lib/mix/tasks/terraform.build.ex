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
  - `env` - Environment for terraform (default: `Mix.env()`)
  - `quiet` - Supress output
  - `force` - Force create files without asking
  - `verbose` - Log extra details about the process

  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)
      |> Keyword.put_new(:aws_region, @default_aws_region)
      |> Keyword.put_new(:aws_release_bucket, @default_aws_release_bucket)
      |> Keyword.put_new(:aws_log_bucket, DeployEx.Config.aws_log_bucket())
      |> Keyword.put_new(:env, Mix.env())


    with :ok <- DeployExHelpers.check_in_umbrella(),
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

        pem_app_name: "#{DeployExHelpers.kebab_app_name()}-#{random_bytes}",
        app_name: DeployExHelpers.underscored_app_name(),
        kebab_app_name: DeployExHelpers.kebab_app_name(),

        terraform_app_releases_variables: terraform_app_releases_variables,
        terraform_release_variables: terraform_app_releases_variables,
        terraform_redis_variables: terraform_redis_variables(opts),
        terraform_sentry_variables: terraform_sentry_variables(opts),
        terraform_grafana_variables: terraform_grafana_variables(opts),
        terraform_loki_variables: terraform_loki_variables(opts),
        terraform_prometheus_variables: terraform_prometheus_variables(opts),
      }

      write_terraform_template_files(params, opts)
      run_terraform_init(params)
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
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
        env: :string,
        no_database: :boolean,
        no_loki: :boolean,
        no_sentry: :boolean,
        no_grafana: :boolean,
        no_redis: :boolean,
        no_prometheus: :boolean
      ]
    )

    opts
  end

  defp run_terraform_init(params) do
    DeployExHelpers.run_command_with_input("terraform init", params[:directory])
  end

  defp ensure_terraform_directory_exists(directory) do
    if File.exists?(directory) do
      :ok
    else
      Mix.shell().info([:green, "* copying terraform into ", :reset, directory])

      File.mkdir_p!(directory)

      "terraform"
        |> DeployExHelpers.priv_file()
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
          name = "#{DeployExHelpers.upper_title_case(release_name)}"
          tags = {
            Vendor = "Self"
            Type   = "Self Made"
          }
        }
    """, "\n")
  end

  defp terraform_redis_variables(opts) do
    if opts[:no_redis] do
      ""
    else
      """
          #{DeployExHelpers.underscored_app_name()}_redis = {
            name        = "#{DeployExHelpers.app_name()} Redis"
            private_ip  = "10.0.1.60"
            enable_ebs  = true

            instance_ebs_secondary_size = 16

            tags = {
              Vendor      = "Redis"
              Type        = "Database"
              DatabaseKey = "#{DeployExHelpers.underscored_app_name()}_redis"
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
            name = "Sentry Monitoring"
            tags = {
              Vendor = "Sentry"
              Type   = "Monitoring"
            }
          },
      """
    end
  end

  defp terraform_loki_variables(opts) do
    if opts[:no_loki] do
      ""
    else
      """
          loki_aggregator = {
            name          = "Grafana Loki Logs"
            instance_type = "t3.micro"
            private_ip    = "10.0.1.50"

            enable_ebs                  = true
            instance_ebs_secondary_size = 8

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
            name                        = "Grafana UI"
            enable_ebs                  = true
            enable_eip                  = true
            instance_ebs_secondary_size = 8

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
            name                        = "Prometheus Metrics Database"
            instance_type               = "t3.micro"
            enable_ebs                  = true
            instance_ebs_secondary_size = 16
            private_ip                  = "10.0.1.40"

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
    terraform_path = DeployExHelpers.priv_file("terraform")

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
