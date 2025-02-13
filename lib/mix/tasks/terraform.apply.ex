defmodule Mix.Tasks.Terraform.Apply do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Deploys to terraform resources using ansible"
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
    cmd = "apply #{DeployEx.Terraform.parse_args(args)}"
    cmd = if opts[:auto_approve], do: "#{cmd} --auto-approve", else: cmd

    DeployEx.Terraform.run_command_with_input(cmd, opts[:directory])
  end
end
