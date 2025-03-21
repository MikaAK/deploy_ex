defmodule Mix.Tasks.Ansible.Build do
  use Mix.Task

  alias DeployEx.Config

  @ansible_default_path Config.ansible_folder_path()
  @terraform_default_path Config.terraform_folder_path()
  @aws_credentials_regex ~r/aws_access_key_id = (?<access_key>[A-Z0-9]+)\naws_secret_access_key = (?<secret_key>[a-z-A-Z0-9\/\+]+)\n/

  @shortdoc "Builds ansible files into your repository"
  @moduledoc """
  Builds ansible files into the respository, this can be used if you
  change terraform settings and want to regenerate any ansible files

  ## Options
  - `directory` - Ansible directory path (default: #{@ansible_default_path})
  - `terraform_directory` - Terraform directory path (default: #{@terraform_default_path})
  - `force` - Force overwrite existing files
  - `quiet` - Suppress output messages
  - `host_only` - Only generate host configuration files
  - `new_only` - Only generate files for new applications
  - `auto_pull_aws` - Automatically pull AWS credentials from ~/.aws/credentials
  - `aws_release_bucket` - AWS S3 bucket for releases
  - `no_loki` - Disable Loki logging configuration
  - `no_sentry` - Disable Sentry error tracking configuration
  - `no_grafana` - Disable Grafana monitoring configuration
  - `no_prometheus` - Disable Prometheus metrics configuration
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)

    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @ansible_default_path)
      |> Keyword.put_new(:terraform_directory, @terraform_default_path)
      |> Keyword.put_new(:hosts_file, "./deploys/ansible/aws_ec2.yaml")
      |> Keyword.put_new(:config_file, "./deploys/ansible/ansible.cfg")
      |> Keyword.put_new(:group_vars_file, "./deploys/ansible/group_vars/all.yaml")
      |> Keyword.put_new(:aws_logging_bucket, Config.aws_log_bucket())
      |> Keyword.put_new(:aws_logging_region, Config.aws_log_region())
      |> Keyword.put_new(:aws_release_bucket, Config.aws_release_bucket())
      |> Keyword.put_new(:aws_region, Config.aws_region())

    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- ensure_ansible_directory_exists(opts[:directory], opts),
         :ok <- create_ansible_hosts_file(opts),
         :ok <- create_ansible_config_file(opts),
         :ok <- create_ansible_group_vars_file(opts),
         {:ok, app_names} <- DeployExHelpers.fetch_mix_release_names(),
         :ok <- create_ansible_playbooks(app_names, opts) do
      :ok
    else
      {:error, [h | tail]} ->
        Enum.each(tail, &Mix.shell().error(to_string(&1)))
        Mix.raise(to_string(h))

      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, a: :auto_pull_aws, h: :host_only, n: :new_only],
      switches: [
        new_only: :boolean,
        force: :boolean,
        host_only: :boolean,
        quiet: :boolean,
        directory: :string,
        terraform_directory: :string,
        auto_pull_aws: :boolean,
        aws_release_bucket: :string,
        no_loki: :boolean,
        no_sentry: :boolean,
        no_grafana: :boolean,
        no_prometheus: :boolean
      ]
    )

    opts
  end

  defp ensure_ansible_directory_exists(directory, opts) do
    if File.exists?(directory) do
      :ok
    else
      File.mkdir_p!(directory)

      Mix.shell().info([:green, "* copying ansible into ", :reset, directory])

      "ansible"
        |> DeployExHelpers.priv_file()
        |> File.cp_r!(directory)

      File.rm!(Path.join(directory, "group_vars/all.yaml.eex"))

      create_ansible_group_vars_file(opts)

      if opts[:auto_pull_aws] do
        pull_aws_credentials_into_awscli_variables(directory, opts)
      end

      :ok
    end
  end

  defp pull_aws_credentials_into_awscli_variables(ansible_directory, opts) do
    main_yaml_path = Path.join(ansible_directory, "group_vars/all.yaml")

    case search_for_aws_credentials() do
      {:ok, {aws_access_key, aws_secret_access_key}} ->
        new_contents = main_yaml_path
          |> File.read!
          |> String.replace(
            "AWS_ACCESS_KEY_ID: \"<INSERT_SECRET_OR_PRELOAD_ON_MACHINE>\"",
            "AWS_ACCESS_KEY_ID: \"#{aws_access_key}\""
          )
          |> String.replace(
            "AWS_SECRET_ACCESS_KEY: \"<INSERT_SECRET_OR_PRELOAD_ON_MACHINE>\"",
            "AWS_SECRET_ACCESS_KEY: \"#{aws_secret_access_key}\""
          )

        opts = opts
          |> Keyword.put_new(:force, true)
          |> Keyword.put(:message, [:green, "* injecting aws credentials into ", :reset, main_yaml_path])

        DeployExHelpers.write_file(main_yaml_path, new_contents, opts)

      {:error, e} ->
        Mix.shell().error(to_string(e))
    end
  end

  defp search_for_aws_credentials do
    credentials_file = Path.expand("~/.aws/credentials")

    if File.exists?(credentials_file) do
      credentials_content = File.read!(credentials_file)

      case Regex.named_captures(@aws_credentials_regex, credentials_content) do
        nil -> {:error, ErrorMessage.not_found("couldn't parse credentials in file at ~/.aws/credentials")}
        %{
          "access_key" => access_key,
          "secret_key" => secret_access_key
        } -> {:ok, {access_key, secret_access_key}}
      end
    else
      {:error, ErrorMessage.not_found("couldn't find credentials file at ~/.aws/credentials")}
    end
  end

  defp create_ansible_group_vars_file(opts) do
    if opts[:host_only] do
      :ok
    else
      variables = %{
        is_loki_enabled: !opts[:no_loki],
        is_prometheus_enabled: !opts[:no_prometheus],
        loki_logger_s3_region: opts[:aws_logging_bucket],
        loki_logger_s3_bucket_name: opts[:aws_logging_region]
      }

      DeployExHelpers.write_template(
        DeployExHelpers.priv_file("ansible/group_vars/all.yaml.eex"),
        opts[:group_vars_file],
        variables,
        opts
      )

      if File.exists?("#{opts[:group_vars_file]}.eex") do
        File.rm!("#{opts[:group_vars_file]}.eex")
      end

      :ok
    end
  end

  defp create_ansible_config_file(opts) do
    if opts[:host_only] do
      :ok
    else
      app_name = String.replace(DeployExHelpers.underscored_project_name(), "_", "-")

      variables = %{
        pem_file_path: pem_file_path(app_name, opts[:directory])
      }

      DeployExHelpers.write_template(
        DeployExHelpers.priv_file("ansible/ansible.cfg.eex"),
        opts[:config_file],
        variables,
        opts
      )

      if File.exists?("#{opts[:config_file]}.eex") do
        File.rm!("#{opts[:config_file]}.eex")
      end

      :ok
    end
  end

  defp create_ansible_hosts_file(opts) do
    variables = %{
      app_name: DeployExHelpers.underscored_project_name()
    }

    DeployExHelpers.write_template(
      DeployExHelpers.priv_file("ansible/aws_ec2.yaml.eex"),
      opts[:hosts_file],
      variables,
      opts
    )

    if File.exists?("#{opts[:hosts_file]}.eex") do
      File.rm!("#{opts[:hosts_file]}.eex")
    end

    :ok
  end

  defp pem_file_path(app_name, directory) do
    pem_file_path = directory
      |> String.split("/")
      |> Enum.drop(-1)
      |> Enum.join("/")
      |> Path.join("terraform/#{app_name}*pem")

    directory_path = pem_file_path
      |> Path.wildcard
      |> then(&(List.first(&1) || ""))
      |> String.split("/")
      |> Enum.drop(1)

    if directory_path === [] do
      Mix.raise("No PEM file found matching glob #{pem_file_path}, have you run mix terraform.apply yet?")
    end

    Enum.join([".." | directory_path], "/")
  end

  def host_name(host_name, index) do
    "#{host_name}_#{:io_lib.format("~3..0B", [index])}"
  end

  defp create_ansible_playbooks(app_names, opts) do
    if opts[:host_only] do
      :ok
    else
      project_playbooks_path = Path.join(opts[:directory], "playbooks")
      project_setup_playbooks_path = Path.join(opts[:directory], "setup")

      if not File.exists?(project_playbooks_path) do
        File.mkdir_p!(project_playbooks_path)
      end

      if not File.exists?(project_setup_playbooks_path) do
        File.mkdir_p!(project_setup_playbooks_path)
      end

      if opts[:new_only] do
        deploy_new_playbooks(app_names, project_playbooks_path, project_setup_playbooks_path, opts)
      else
        deploy_all_playbooks(app_names, opts)
      end

      remove_usless_copied_template_folder(opts)

      :ok
    end
  end

  defp deploy_all_playbooks(app_names, opts) do
    Enum.each(app_names, fn app_name ->
      build_host_setup_playbook(app_name, opts)
      build_host_playbook(app_name, opts)
    end)
  end

  defp deploy_new_playbooks(app_names, project_playbooks_path, project_setup_playbooks_path, opts) do
    project_deploy_files = File.ls!(project_playbooks_path)
    project_setup_files = File.ls!(project_setup_playbooks_path)

    Enum.each(app_names, fn app_name ->
      if not Enum.any?(project_setup_files, &(&1 =~ app_name)) do
        build_host_setup_playbook(app_name, opts)
      end

      if not Enum.any?(project_deploy_files, &(&1 =~ app_name)) do
        build_host_playbook(app_name, opts)
      end
    end)
  end

  defp build_host_playbook(app_name, opts) do
    host_playbook_template_path = DeployExHelpers.priv_file("ansible/app_playbook.yaml.eex")
    host_playbook_path = Path.join(opts[:directory], "playbooks/#{app_name}.yaml")

    variables = %{
      no_loki: opts[:no_loki],
      no_prometheus: opts[:no_prometheus],
      app_name: app_name,
      aws_release_bucket: opts[:aws_release_bucket],
      port: 80
    }

    DeployExHelpers.write_template(
      host_playbook_template_path,
      host_playbook_path,
      variables,
      opts
    )
  end

  defp build_host_setup_playbook(app_name, opts) do
    setup_playbook_path = DeployExHelpers.priv_file("ansible/app_setup_playbook.yaml.eex")
    setup_host_playbook = Path.join(opts[:directory], "setup/#{app_name}.yaml")

    variables = %{
      no_loki: opts[:no_loki],
      no_prometheus: opts[:no_prometheus],
      app_name: app_name,
      port: 80
    }

    DeployExHelpers.write_template(
      setup_playbook_path,
      setup_host_playbook,
      variables,
      opts
    )
  end

  defp remove_usless_copied_template_folder(opts) do
    template_file = Path.join(opts[:directory], "app_playbook.yaml.eex")
    setup_template_file = Path.join(opts[:directory], "app_setup_playbook.yaml.eex")

    if File.exists?(template_file) do
      File.rm!(template_file)
    end

    if File.exists?(setup_template_file) do
      File.rm!(setup_template_file)
    end
  end
end
