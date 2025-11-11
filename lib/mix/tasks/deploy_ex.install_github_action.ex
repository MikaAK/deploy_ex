defmodule Mix.Tasks.DeployEx.InstallGithubAction do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @github_action_path "./.github/workflows/deploy-ex-release.yml"
  @github_action_template_path DeployExHelpers.priv_file("github-action.yml.eex")

  @github_action_setup_nodes_path "./.github/workflows/setup-new-nodes.yml"
  @github_action_setup_nodes_template_path DeployExHelpers.priv_file("github-action-setup-nodes.yml.eex")

  @github_action_scripts_paths [{
    DeployExHelpers.priv_file("github-action-maybe-commit-terraform-changes.sh"),
    "./.github/github-action-maybe-commit-terraform-changes.sh"
  }, {
    DeployExHelpers.priv_file("github-action-secrets-to-env.sh"),
    "./.github/github-action-secrets-to-env.sh"
  }]
  @shortdoc "Installs GitHub Actions for automated infrastructure and deployment management"
  @moduledoc """
  Installs GitHub Action workflows that automate infrastructure management and application deployment.

  This installs two workflows:

  1. **deploy-ex-release.yml** - Main deployment workflow
     - Validates and updates Terraform infrastructure
     - Builds and uploads releases to S3
     - Deploys applications via Ansible

  2. **setup-new-nodes.yml** - Automated node setup
     - Detects new EC2 instances that need configuration
     - Runs ansible.setup automatically
     - Tags instances as configured
     - Triggered on schedule and on-demand

  ## Example
  ```bash
  # Install the GitHub Action workflows
  mix deploy_ex.install_github_action

  # Install with custom PEM directory
  mix deploy_ex.install_github_action --pem-directory /path/to/keys
  ```

  ## Options
  - `pem-directory` - Directory containing SSH keys (default: ./deploys/terraform)
  - `force` - Overwrite existing workflow files
  - `quiet` - Suppress output messages
  - `pem` - SSH key file
  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:pem_directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         {:ok, pem_file_path} <- DeployEx.Terraform.find_pem_file(opts[:pem_directory], opts[:pem]) do
      @github_action_path |> Path.dirname |> File.mkdir_p!

      app_names = releases |> Keyword.keys |> Enum.map(&to_string/1)

      DeployExHelpers.write_template(
        @github_action_template_path,
        @github_action_path,
        %{
          app_names: app_names,
          pem_file_path: pem_file_path
        },
        opts
      )

      DeployExHelpers.write_template(
        @github_action_setup_nodes_template_path,
        @github_action_setup_nodes_path,
        %{
          app_names: app_names
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
      aliases: [f: :force, q: :quit, d: :pem_directory, p: :pem],
      switches: [
        force: :boolean,
        quiet: :boolean,
        pem_directory: :boolean,
        pem: :string
      ]
    )

    opts
  end
end
