defmodule Mix.Tasks.Terraform.Apply do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Applies terraform changes to provision AWS infrastructure"
  @moduledoc """
  Applies terraform changes to provision or update AWS infrastructure.

  ## Example
  ```bash
  mix terraform.apply
  mix terraform.apply --auto-approve
  mix terraform.apply --target my_app
  ```

  ## Options
  - `directory` - Terraform directory path (default: #{@terraform_default_path})
  - `force` - Force apply without asking
  - `quiet` - Suppress output messages
  - `auto_approve` - Skip confirmation prompts (alias: `y`)
  - `var-file` - Path to a Terraform variables file
  - `target` - Target specific app resources (can be used multiple times)
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- run_command(args, opts) do
      :ok
    else
      {:error, e} -> Mix.raise(to_string(e))
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

  defp run_command(args, opts) do
    cmd = "apply #{DeployEx.Terraform.parse_args(args, :apply)}"
    cmd = if opts[:auto_approve], do: "#{cmd} --auto-approve", else: cmd

    DeployEx.Terraform.run_command_with_input(cmd, opts[:directory])
  end
end
