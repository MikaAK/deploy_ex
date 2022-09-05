defmodule Mix.Tasks.DeployEx.InstallGithubAction do
  use Mix.Task

  @github_action_path "./.github/workflows/deploy-ex-release.yml"
  @github_action_template_path DeployExHelpers.priv_file("github-action.yml.eex")

  @github_action_script_output_path "./.github/github-action-maybe-commit-terraform-changes.sh"
  @github_action_script_path DeployExHelpers.priv_file("github-action-maybe-commit-terraform-changes.sh")

  @shortdoc "Installs a github action to manage terraform & ansible from within it"
  @moduledoc """
  Adds a github action to manage terraform & ansible. This will automatically do a few things:

  1) On push will ensure terraform is up to date, if not it will apply changes and submit changes to git
  2) On push new releases will be built if there are updates for the app
  3) Built releases will be deployed to S3 bucket
  4) Built releases will have ansible run on them to deploy them to changed servers
  """

  def run(args) do
    opts = parse_args(args)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases() do
      @github_action_path |> Path.dirname |> File.mkdir_p!

      DeployExHelpers.write_template(
        @github_action_template_path,
        @github_action_path,
        %{
          app_names: releases |> Keyword.keys |> Enum.map(&to_string/1)
        },
        opts
      )

      DeployExHelpers.write_file(
        @github_action_script_output_path,
        File.read!(@github_action_script_path),
        opts
      )
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit],
      switches: [
        force: :boolean,
        quiet: :boolean,
      ]
    )

    opts
  end
end

