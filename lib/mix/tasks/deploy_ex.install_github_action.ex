defmodule Mix.Tasks.DeployEx.InstallGithubAction do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @github_action_path "./.github/workflows/deploy-ex-release.yml"
  @github_action_template_path DeployExHelpers.priv_file("github-action.yml.eex")

  @github_action_scripts_paths [{
    DeployExHelpers.priv_file("github-action-maybe-commit-terraform-changes.sh"),
    "./.github/github-action-maybe-commit-terraform-changes.sh"
  }, {
    DeployExHelpers.priv_file("github-actions-secrets-to-json-file.sh"),
    "./.github/github-actions-secrets-to-json-file.sh"
  }]

  @shortdoc "Installs a github action to manage terraform & ansible from within it"
  @moduledoc """
  Adds a github action to manage terraform & ansible. This will automatically do a few things:

  1) On push will ensure terraform is up to date, if not it will apply changes and submit changes to git
  2) On push new releases will be built if there are updates for the app
  3) Built releases will be deployed to S3 bucket
  4) Built releases will have ansible run on them to deploy them to changed servers
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:pem_directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         {:ok, pem_file_path} <- DeployExHelpers.find_pem_file(opts[:pem_directory]) do
      @github_action_path |> Path.dirname |> File.mkdir_p!

      DeployExHelpers.write_template(
        @github_action_template_path,
        @github_action_path,
        %{
          app_names: releases |> Keyword.keys |> Enum.map(&to_string/1),
          pem_file_path: pem_file_path
        },
        opts
      )

      Enum.each(@github_action_scripts_paths, fn {input_path, output_path} ->
        DeployExHelpers.check_file_exists!(input_path)

        DeployExHelpers.write_file(
          output_path,
          File.read!(input_path),
          opts
        )
      end)
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :pem_directory],
      switches: [
        force: :boolean,
        quiet: :boolean,
        pem_directory: :boolean
      ]
    )

    opts
  end
end

