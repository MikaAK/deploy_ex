defmodule Mix.Tasks.Ansible.Ping do
  use Mix.Task

  @shortdoc "Pings all configured Ansible hosts"
  @moduledoc """
  Pings all hosts configured in the Ansible inventory file to verify connectivity.

  ## Example
  ```bash
  mix ansible.ping
  mix ansible.ping --provider oci
  ```

  ## Options
  - `provider` - Cloud provider whose inventory to ping (default: `DeployEx.Config.cloud_provider/0`)

  Any additional arguments passed will be forwarded directly to the ansible command.
  Common options include:
  - `-v` - Increase verbosity
  - `--limit hostname` - Only ping specific hosts
  """

  def run(args) do
    ansible_args = DeployEx.Ansible.parse_args(args)
    provider = args |> parse_args() |> resolve_provider()

    with :ok <- DeployExHelpers.check_valid_project(),
         :ok <- DeployEx.ToolInstaller.ensure_installed(:ansible) do
      inventory_filename = inventory_filename(provider)

      DeployExHelpers.check_file_exists!("./deploys/ansible/#{inventory_filename}")

      DeployEx.Utils.run_command(
        "ansible -i #{inventory_filename} #{ansible_args} all -m ping",
        "./deploys/ansible"
      )
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args, switches: [provider: :string])
    opts
  end

  # Matches the flag against the registered providers rather than calling to_existing_atom/1 —
  # see terraform.build.ex's identical resolve_provider/1 for the rationale.
  defp resolve_provider(opts) do
    case opts[:provider] do
      nil ->
        DeployEx.Config.cloud_provider()

      name ->
        known = DeployEx.Cloud.providers()

        case Enum.find(known, &(to_string(&1) === name)) do
          nil -> Mix.raise("unknown provider #{inspect(name)}, expected one of #{inspect(known)}")
          provider -> provider
        end
    end
  end

  defp inventory_filename(provider) do
    case DeployEx.Cloud.inventory(provider) do
      {:ok, %{filename: filename}} -> filename
      {:error, error} -> Mix.raise(to_string(error))
    end
  end
end
