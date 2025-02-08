defmodule Mix.Tasks.DeployEx.InstallMigrationScript do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @github_action_path "./.github/workflows/deploy-ex-release.yml"
  @github_action_template_path DeployExHelpers.priv_file("github-action.yml.eex")

  @github_action_scripts_paths [{
    DeployExHelpers.priv_file("github-action-maybe-commit-terraform-changes.sh"),
    "./.github/github-action-maybe-commit-terraform-changes.sh"
  }, {
    DeployExHelpers.priv_file("github-action-secrets-to-env.sh"),
    "./.github/github-action-secrets-to-env.sh"
  }]

  @shortdoc "Installs a migration script for managing database migrations during deployment"
  @moduledoc """
  Installs a script that helps manage database migrations during the deployment process.
  This script ensures migrations are run safely and consistently across all database nodes.

  The migration script handles:
  - Checking if migrations are needed
  - Running migrations in the correct order
  - Handling rollbacks if migrations fail
  - Coordinating migrations across multiple database nodes
  - Logging migration results

  ## Example
  ```bash
  mix deploy_ex.install_migration_script
  ```

  ## Options
  - `force` - Overwrite existing migration script if present (alias: `f`)
  - `quiet` - Suppress output messages (alias: `q`)
  - `pem_directory` - Custom directory containing SSH keys (alias: `d`)
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
    else
      {:error, e} -> Mix.raise(to_string(e))
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
