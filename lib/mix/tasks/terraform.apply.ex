defmodule Mix.Tasks.Terraform.Apply do
  use Mix.Task

  @terraform_default_path "./deploys/terraform"

  @shortdoc "Deploys to terraform resources using ansible"
  @moduledoc """
  Deploys with terraform to AWS
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      cmd = "terraform apply"
      cmd = if opts[:auto_approve], do: "#{cmd} --auto-approve", else: cmd

      DeployExHelpers.run_command_with_input(cmd, opts[:directory])

      maybe_chmod_pem_file(opts[:directory])
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

  defp maybe_chmod_pem_file(directory) do
    kebab_case_app_name = String.replace(DeployExHelpers.underscored_app_name(), "_", "-")
    file_dir = Path.join(directory, "#{kebab_case_app_name}-key-pair.pem")


    DeployExHelpers.check_file_exists!(file_dir)

    if File.lstat!(file_dir).access !== :read do
      File.chmod!(file_dir, 0o400)
    end
  end
end
