defmodule Mix.Tasks.DeployEx.InstallGithubAction do
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
  @shortdoc "Installs a GitHub Action for automated infrastructure and deployment management"
  @moduledoc """
  Installs a GitHub Action workflow that automates infrastructure management and application deployment.

  The workflow performs the following steps automatically on each push:

  1. Validates and updates Terraform infrastructure
     - Checks if infrastructure changes are needed
     - Applies changes if necessary
     - Commits any Terraform state changes back to the repository

  2. Handles application releases
     - Detects changes that require new releases
     - Builds new release versions when needed
     - Uploads built releases to S3 storage

  3. Manages deployments
     - Runs Ansible playbooks to deploy new releases
     - Only deploys to servers affected by infrastructure changes
     - Ensures zero-downtime rolling deployments

  ## Example
  ```bash
  # Install the GitHub Action workflow
  mix deploy_ex.install_github_action

  # Install with custom PEM directory
  mix deploy_ex.install_github_action --pem-directory /path/to/keys
  ```

  ## Options
  - `pem-directory` - Directory containing SSH keys (default: ./deploys/terraform)
  - `force` - Overwrite existing workflow files
  - `quiet` - Suppress output messages
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:pem_directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         {:ok, pem_file_path} <- DeployEx.Terraform.find_pem_file(opts[:pem_directory]) do
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
