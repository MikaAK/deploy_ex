defmodule Mix.Tasks.Terraform.Init do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Initializes terraform in the project directory"
  @moduledoc """
  Runs `terraform init` to initialize the working directory containing Terraform configuration files.

  ## Example
  ```bash
  mix terraform.init
  mix terraform.init --upgrade
  ```

  ## Options
  - `directory` - Terraform directory path (default: #{@terraform_default_path})
  - `upgrade` - Upgrade modules and plugins (alias: `u`)
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- run_terraform_init(args, opts) do
      :ok
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [d: :directory, u: :upgrade],
      switches: [
        directory: :string,
        upgrade: :boolean
      ]
    )

    opts
  end

  defp run_terraform_init(args, opts) do
    cmd = "init #{DeployEx.Terraform.parse_args(args, :init)}"
    cmd = if opts[:upgrade], do: "#{cmd} --upgrade", else: cmd

    DeployEx.Terraform.run_command_with_input(cmd, opts[:directory])
  end
end
