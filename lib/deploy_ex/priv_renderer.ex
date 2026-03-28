defmodule DeployEx.PrivRenderer do
  @moduledoc """
  Renders all priv EEx templates into a temp directory using the same
  variables as terraform.build and ansible.build. The output mirrors
  what a fresh build would produce in ./deploys/.
  """

  require Logger

  # SECTION: Public API

  @spec render_to_temp(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}
  def render_to_temp(opts \\ []) do
    temp_dir = create_temp_dir()

    result =
      try do
        with :ok <- render_terraform(temp_dir, opts),
             :ok <- render_ansible(temp_dir, opts) do
          {:ok, temp_dir}
        else
          {:error, _} = error -> error
        end
      rescue
        e ->
          {:error, ErrorMessage.internal_server_error(
            "failed to render priv templates: #{Exception.message(e)}"
          )}
      end

    case result do
      {:ok, _} -> result
      {:error, _} = error ->
        File.rm_rf!(temp_dir)
        error
    end
  end

  # SECTION: Terraform Rendering

  defp render_terraform(temp_dir, opts) do
    priv_terraform = priv_source_path("terraform")
    target_dir = Path.join(temp_dir, "terraform")

    with :ok <- copy_directory(priv_terraform, target_dir),
         :ok <- remove_eex_files(target_dir),
         :ok <- render_terraform_templates(priv_terraform, target_dir, opts) do
      :ok
    end
  end

  defp render_terraform_templates(priv_terraform, target_dir, opts) do
    params = build_terraform_params(opts)

    priv_terraform
      |> Path.join("*.eex")
      |> Path.wildcard()
      |> Enum.each(fn template_file ->
        rendered = EEx.eval_file(template_file, assigns: params)

        output_name =
          template_file
          |> Path.basename()
          |> String.replace_suffix(".eex", "")

        output_path = Path.join(target_dir, output_name)

        File.write!(output_path, rendered)
      end)

    :ok
  end

  defp build_terraform_params(opts) do
    release_names = fetch_release_names()
    app_name = opts[:app_name] || DeployExHelpers.underscored_project_name()
    kebab_app_name = opts[:kebab_app_name] || DeployExHelpers.kebab_project_name()
    environment = opts[:environment] || DeployEx.Config.env()
    aws_region = opts[:aws_region] || DeployEx.Config.aws_region()
    aws_release_bucket = opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket()
    aws_log_bucket = opts[:aws_log_bucket] || DeployEx.Config.aws_log_bucket()

    terraform_app_releases_variables = release_names
      |> Enum.map_join(",\n\n", &generate_terraform_release_variables/1)

    random_bytes = 6 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false)

    %{
      directory: DeployEx.Config.terraform_folder_path(),
      environment: environment,
      aws_region: aws_region,
      aws_release_bucket: aws_release_bucket,

      use_db: !Keyword.get(opts, :no_database, false),
      db_password: "placeholder",

      release_bucket_name: aws_release_bucket,
      logging_bucket_name: aws_log_bucket,

      aws_release_state_bucket: DeployEx.Config.aws_release_state_bucket(),
      aws_release_state_lock_table: DeployEx.Config.aws_release_state_lock_table(),

      terraform_backend: DeployEx.Config.terraform_backend(),

      pem_app_name: "#{kebab_app_name}-#{random_bytes}",
      app_name: app_name,
      kebab_app_name: kebab_app_name,

      use_loki: !Keyword.get(opts, :no_logging, false),
      use_grafana: !Keyword.get(opts, :no_grafana, false),
      use_prometheus: !Keyword.get(opts, :no_prometheus, false),
      use_redis: !Keyword.get(opts, :no_redis, false),
      use_sentry: !Keyword.get(opts, :no_sentry, false),
      use_database: !Keyword.get(opts, :no_database, false),

      terraform_app_releases_variables: terraform_app_releases_variables,
      terraform_release_variables: terraform_app_releases_variables,
      terraform_redis_variables: terraform_redis_variables(opts),
      terraform_sentry_variables: terraform_sentry_variables(opts),
      terraform_grafana_variables: terraform_grafana_variables(opts),
      terraform_loki_variables: terraform_loki_variables(opts),
      terraform_prometheus_variables: terraform_prometheus_variables(opts)
    }
  end

  # SECTION: Ansible Rendering

  defp render_ansible(temp_dir, opts) do
    priv_ansible = priv_source_path("ansible")
    target_dir = Path.join(temp_dir, "ansible")

    with :ok <- copy_directory(priv_ansible, target_dir),
         :ok <- remove_eex_files_recursive(target_dir),
         :ok <- render_ansible_templates(priv_ansible, target_dir, opts) do
      :ok
    end
  end

  defp render_ansible_templates(priv_ansible, target_dir, opts) do
    app_name = opts[:app_name] || DeployExHelpers.underscored_project_name()
    aws_release_bucket = opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket()

    # ansible.cfg
    ansible_cfg_vars = %{
      pem_file_path: "../terraform/#{String.replace(app_name, "_", "-")}*pem"
    }

    render_template(
      Path.join(priv_ansible, "ansible.cfg.eex"),
      Path.join(target_dir, "ansible.cfg"),
      ansible_cfg_vars
    )

    # aws_ec2.yaml
    hosts_vars = %{app_name: app_name}

    render_template(
      Path.join(priv_ansible, "aws_ec2.yaml.eex"),
      Path.join(target_dir, "aws_ec2.yaml"),
      hosts_vars
    )

    # group_vars/all.yaml
    group_vars_vars = %{
      is_logging_enabled: !Keyword.get(opts, :no_logging, false),
      is_prometheus_enabled: !Keyword.get(opts, :no_prometheus, false),
      loki_logger_s3_region: DeployEx.Config.aws_log_region(),
      loki_logger_s3_bucket_name: DeployEx.Config.aws_log_bucket()
    }

    File.mkdir_p!(Path.join(target_dir, "group_vars"))

    render_template(
      Path.join(priv_ansible, "group_vars/all.yaml.eex"),
      Path.join(target_dir, "group_vars/all.yaml"),
      group_vars_vars
    )

    # Per-app playbooks
    release_names = fetch_release_names()

    File.mkdir_p!(Path.join(target_dir, "playbooks"))
    File.mkdir_p!(Path.join(target_dir, "setup"))

    Enum.each(release_names, fn release_name ->
      playbook_vars = %{
        no_logging: Keyword.get(opts, :no_logging, false),
        no_prometheus: Keyword.get(opts, :no_prometheus, false),
        app_name: release_name,
        aws_release_bucket: aws_release_bucket,
        port: 80
      }

      render_template(
        Path.join(priv_ansible, "app_playbook.yaml.eex"),
        Path.join(target_dir, "playbooks/#{release_name}.yaml"),
        playbook_vars
      )

      render_template(
        Path.join(priv_ansible, "app_setup_playbook.yaml.eex"),
        Path.join(target_dir, "setup/#{release_name}.yaml"),
        playbook_vars
      )
    end)

    # Remove the copied app-level EEx templates that shouldn't be in the output
    remove_if_exists(Path.join(target_dir, "app_playbook.yaml.eex"))
    remove_if_exists(Path.join(target_dir, "app_setup_playbook.yaml.eex"))

    :ok
  end

  # SECTION: Terraform Variable Generators

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
    if Keyword.get(opts, :no_redis, false) do
      ""
    else
      app_name = opts[:app_name] || DeployExHelpers.underscored_project_name()
      title = DeployExHelpers.title_case_project_name()

      """
          #{app_name}_redis = {
            name        = "#{title} Redis"
            private_ip  = "10.0.1.60"
            enable_ebs  = true

            # This is a suggestion for instance

            instance_type = "r7g.medium"

            instance_ebs_secondary_size = 16

            tags = {
              Vendor      = "Redis"
              Type        = "Database"
              DatabaseKey = "#{app_name}_redis"
            }
          },
      """
    end
  end

  defp terraform_sentry_variables(opts) do
    if Keyword.get(opts, :no_sentry, false) do
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
    if Keyword.get(opts, :no_logging, false) do
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
    if Keyword.get(opts, :no_grafana, false) do
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
    if Keyword.get(opts, :no_prometheus, false) do
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

  # SECTION: Helpers

  defp priv_source_path(subdirectory) do
    :deploy_ex |> :code.priv_dir() |> Path.join(subdirectory)
  end

  defp create_temp_dir do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "deploy_ex_render_#{unique}")
    File.mkdir_p!(dir)
    dir
  end

  defp copy_directory(source, target) do
    File.mkdir_p!(target)
    File.cp_r!(source, target)
    :ok
  end

  defp remove_eex_files(directory) do
    directory
      |> Path.join("*.eex")
      |> Path.wildcard()
      |> Enum.each(&File.rm!/1)

    :ok
  end

  defp remove_eex_files_recursive(directory) do
    directory
      |> Path.join("**/*.eex")
      |> Path.wildcard()
      |> Enum.each(&File.rm!/1)

    :ok
  end

  defp render_template(template_path, output_path, variables) do
    rendered = EEx.eval_file(template_path, assigns: variables)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, rendered)
  end

  defp remove_if_exists(path) do
    if File.exists?(path) do
      File.rm!(path)
    end
  end

  defp fetch_release_names do
    case DeployExHelpers.fetch_mix_release_names() do
      {:ok, names} -> Enum.map(names, &to_string/1)
      {:error, _} -> [DeployExHelpers.underscored_project_name()]
    end
  end
end
