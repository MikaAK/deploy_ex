defmodule Mix.Tasks.Terraform.Plan do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Shows terraforms potential changes if you were to apply"
  @moduledoc """
  Deploys with terraform to AWS

  ## Options
  - `directory` - Set the directory for terraform (defaults to #{@terraform_default_path})
  - `force` - Force create things without asking
  - `quiet` - Don't output messages
  - `auto_approve` - Automatically say yes when applying
  - `var-file` - Set a specific variables file
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
      aliases: [f: :force, q: :quit, d: :directory],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
      ]
    )

    opts
  end

  defp run_command(args, opts) do
    cmd = "terraform plan #{DeployExHelpers.to_terraform_args(args)}"

    DeployExHelpers.run_command_with_input(cmd, opts[:directory])
  end
end
