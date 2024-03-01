defmodule Mix.Tasks.Terraform.Init do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Runs terraform init"
  @moduledoc """
  Runs terraform init
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)
      |> Keyword.put(:iac_tool, DeployEx.Config.iac_tool())

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
    cmd = "#{opts[:iac_tool]} init #{DeployExHelpers.to_terraform_args(args)}"
    cmd = if opts[:upgrade], do: "#{cmd} --upgrade", else: cmd

    DeployExHelpers.run_command_with_input(cmd, opts[:directory])
  end
end
