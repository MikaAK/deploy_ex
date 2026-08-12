defmodule Mix.Tasks.Terraform.Drop do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Destroys all resources built by terraform"
  @moduledoc """
  Destroys all infrastructure resources managed by Terraform.

  This is a destructive operation that will tear down all provisioned resources
  including compute instances, load balancers, security groups, and other infrastructure.

  ## Example
  ```bash
  mix terraform.drop
  mix terraform.drop --auto-approve
  ```

  ## Options
  - `directory` - Terraform directory path (default: #{@terraform_default_path})
  - `auto_approve` - Skip confirmation prompts (alias: `y`)
  - `target` - Target specific app resources (can be used multiple times)
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_valid_project() do
      cmd = "destroy #{DeployEx.Terraform.parse_args(args, :destroy)}"
      cmd = if opts[:auto_approve], do: "#{cmd} --auto-approve", else: cmd

      # Mix does NOT fail a task based on run/1's return value — only a raise produces a
      # non-zero exit. Returning the error tuple made a FAILED destroy exit 0. MEASURED: a
      # destroy that left an object-storage bucket behind ("409-BucketNotEmpty") still
      # reported success, so infrastructure you believe is gone is still there and billing.
      case DeployEx.Terraform.run_command_with_input(cmd, opts[:directory]) do
        :ok -> :ok
        {:error, error} -> Mix.raise(to_string(error))
      end
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, y: :auto_approve],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        auto_approve: :boolean
      ]
    )

    opts
  end
end
