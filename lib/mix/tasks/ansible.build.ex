defmodule Mix.Tasks.Ansible.Build do
  use Mix.Task

  @shortdoc "Deploys to terraform resources using ansible"
  @moduledoc """
  Deploys to ansible
  """

  def run(args) do
    with :ok <- check_in_umbrella(),
         :ok <- create_ansible_hosts_file(parse_args(args)) do
      :ok
    else
      {:error, e} -> Mix.shell().error(to_string(e))
    end
  end

  defp check_in_umbrella do
    if Mix.Project.umbrella?() do
      :ok
    else
      {:error, ErrorMessage.bad_request("must be in umbrella root")}
    end
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit],
      switches: [
        force: :boolean,
        quiet: :boolean
      ]
    )

    opts
  end

  defp create_ansible_hosts_file(opts) do
    with {:ok, hostname_ips} <- terraform_instance_ips() do
      ansible_host_file = EEx.eval_file("./deploys/ansible/hosts.eex", [
        assigns: %{
          host_name_ips: hostname_ips
        }
      ])

      Mix.Generator.create_file("./deploys/ansible/hosts", ansible_host_file, opts)

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

