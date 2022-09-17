defmodule Mix.Tasks.Terraform.Replace do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Runs terraform replace with a node"
  @moduledoc """
  Runs terraform init

  ## Example
  ```bash
  $ mix terraform.replace <my_app>
  ```
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      cmd = "terraform apply --replace \"#{replace_string(opts[:release_name])}\""
      cmd = if opts[:auto_approve], do: "#{cmd} --auto-approve", else: cmd

      DeployExHelpers.run_command_with_input(cmd, opts[:directory])
    end
  end

  defp replace_string(release_name) do
    "module.ec2_instance[\\\"#{release_name}\\\"].aws_instance.ec2_instance"
  end

  defp parse_args(args) do
    {opts, extra_args} = OptionParser.parse!(args,
      aliases: [d: :directory, y: :auto_approve],
      switches: [
        directory: :string,
        auto_approve: :boolean
      ]
    )

    case DeployExHelpers.fetch_mix_releases() do
      {:error, e} -> Mix.raise(to_string(e))

      {:ok, releases} ->
        release_names = Keyword.keys(releases)

        Keyword.put(opts, :release_name, get_release_from_args(release_names, extra_args))
    end
  end

  defp get_release_from_args(release_names, [release_name]) do
    if String.to_atom(release_name) in release_names do
      release_name
    else
      release_names = Enum.join(release_names, ", ")

      Mix.raise("Error with arguments provided, #{release_name} is not a valid release name, must be one of: #{release_names}")
    end
  end

  defp get_release_from_args(_, _) do
    Mix.raise("Error with arguments provided, must specify one app name\nExample: mix terraform.replace my_app")
  end
end

