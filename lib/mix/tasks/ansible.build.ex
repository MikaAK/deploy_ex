defmodule Mix.Tasks.Ansible.Build do
  use Mix.Task

  @terraform_default_path "./deploys/ansible"

  @shortdoc "Deploys to terraform resources using ansible"
  @moduledoc """
  Deploys to ansible
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)
      |> Keyword.put_new(:hosts_file, "./deploys/ansible/hosts")

    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- ensure_ansible_directory_exists(opts[:directory]),
         :ok <- create_ansible_hosts_file(opts) do
      :ok
    else
      {:error, e} -> Mix.shell().error(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit],
      switches: [
        force: :boolean,
        quiet: :boolean,
        directory: :string
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

  defp create_ansible_hosts_file(opts) do
    with {:ok, hostname_ips} <- terraform_instance_ips() do
      ansible_host_file = EEx.eval_file(DeployExHelpers.priv_file("ansible/hosts.eex"), [
        assigns: %{
          host_name_ips: hostname_ips,
          app_name: DeployExHelpers.underscored_app_name()
        }
      ])

      opts = if File.exists?(opts[:hosts_file]) do
        [{:message, [:green, "* rewriting ", :reset, opts[:hosts_file]]} | opts]
      else
        opts
      end

      DeployExHelpers.write_file(opts[:hosts_file], ansible_host_file, opts)

      File.rm!("#{opts[:hosts_file]}.eex")

      :ok
    end
  end

  defp terraform_instance_ips do
    case System.shell("terraform output --json", cd: Path.expand("./deploys/terraform")) do
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
end

