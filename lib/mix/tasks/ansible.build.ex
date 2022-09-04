defmodule Mix.Tasks.Ansible.Build do
  use Mix.Task

  alias DeployEx.Config

  @ansible_default_path Config.ansible_folder_path()
  @terraform_default_path Config.terraform_folder_path()

  @shortdoc "Deploys to ansible resources using ansible"
  @moduledoc """
  Deploys to ansible
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)

    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @ansible_default_path)
      |> Keyword.put_new(:terraform_directory, @terraform_default_path)
      |> Keyword.put_new(:hosts_file, "./deploys/ansible/hosts")
      |> Keyword.put_new(:config_file, "./deploys/ansible/ansible.cfg")
      |> Keyword.put_new(:aws_bucket, Config.aws_release_bucket())
      |> Keyword.put_new(:aws_region, Config.aws_release_region())

    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- ensure_ansible_directory_exists(opts[:directory]),
         {:ok, hostname_ips} <- terraform_instance_ips(opts[:terraform_directory]),
         :ok <- create_ansible_hosts_file(hostname_ips, opts),
         :ok <- create_ansible_config_file(opts),
         :ok <- create_ansible_playbooks(Map.keys(hostname_ips), opts) do
      :ok
    else
      {:error, e} when is_list(e) -> Enum.each(e, &Mix.shell().error(to_string(&1)))
      {:error, e} -> Mix.shell().error(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory],
      switches: [
        force: :boolean,
        quiet: :boolean,
        directory: :string,
        terraform_directory: :string,
        aws_bucket: :string
      ]
    )

    opts
  end

  defp ensure_ansible_directory_exists(directory) do
    if File.exists?(directory) do
      :ok
    else
      File.mkdir_p!(directory)

      Mix.shell().info([:green, "* copying ansible into ", :reset, directory])

      "ansible"
        |> DeployExHelpers.priv_file()
        |> File.cp_r!(directory)

      :ok
    end
  end

  defp create_ansible_config_file(opts) do
    app_name = String.replace(DeployExHelpers.underscored_app_name(), "_", "-")

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

  defp create_ansible_hosts_file(hostname_ips, opts) do
    variables = %{
      host_name_ips: hostname_ips
    }

    DeployExHelpers.write_template(
      DeployExHelpers.priv_file("ansible/hosts.eex"),
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
    directory_path = directory
      |> String.split("/")
      |> Enum.drop(-1)
      |> Enum.join("/")
      |> Path.join("terraform/#{app_name}*pem")
      |> Path.wildcard
      |> List.first
      |> String.split("/")
      |> Enum.drop(1)

    Enum.join([".." | directory_path], "/")
  end

  def terraform_instance_ips(terraform_directory) do
    case System.shell("terraform output --json", cd: Path.expand(terraform_directory)) do
      {output, 0} ->
        {:ok, parse_terraform_output_to_ips(output)}

      {message, _} ->
        {:error, ErrorMessage.failed_dependency("terraform output failed", %{message: message})}
    end
  end

  defp parse_terraform_output_to_ips(output) do
    case Jason.decode!(output) do
      %{"public_ip" => %{"value" => values}} -> values
      _ -> []
    end
  end

  def host_name(host_name, index) do
    "#{host_name}_#{:io_lib.format("~3..0B", [index])}"
  end

  defp create_ansible_playbooks(app_names, opts) do
    project_playbooks_path = Path.join(opts[:directory], "playbooks")
    project_setup_playbooks_path = Path.join(opts[:directory], "setup")

    if not File.exists?(project_playbooks_path) do
      File.mkdir_p!(project_playbooks_path)
    end

    if not File.exists?(project_setup_playbooks_path) do
      File.mkdir_p!(project_setup_playbooks_path)
    end

    Enum.each(app_names, fn app_name ->
      build_host_setup_playbook(app_name, opts)
      build_host_playbook(app_name, opts)
    end)

    remove_usless_copied_template_folder(opts)

    :ok
  end

  defp build_host_playbook(app_name, opts) do
    host_playbook_template_path = DeployExHelpers.priv_file("ansible/app_playbook.yaml.eex")
    host_playbook_path = Path.join(opts[:directory], "playbooks/#{app_name}.yaml")

    variables = %{
      app_name: app_name,
      aws_release_bucket: opts[:aws_bucket],
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

    # with {:ok, remote_releases} <- ReleaseUploader.fetch_all_remote_releases(opts),
    #      {:ok, aws_release_file_map} <- ReleaseUploader.lastest_app_release(
    #        remote_releases,
    #        app_names
    #      ) do
    #   Enum.each(app_names, fn app_name ->
    #   end)
    # else
    #   {:error, e} when is_list(e) -> Enum.each(e, &Mix.shell().error(to_string(&1)))
    #   {:error, e} -> Mix.shell().error(to_string(e))
    # end

