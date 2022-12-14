defmodule Mix.Tasks.DeployEx.FullDrop do
  use Mix.Task

  @shortdoc "Runs all the commands to drop and remove deploy_ex from the project"
  @moduledoc """
  Runs all the commands to drop and remove deploy_ex from the project
  Removes ./deploys folder as well
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      DeployExHelpers.check_file_exists!("./deploys/terraform")

      with :ok <- Mix.Tasks.Terraform.Drop.run(args) do
        File.rm_rf!("./deploys")

        Mix.shell().info([
          :red, "* removing ", :reset, "./deploys"
        ])
      end

      remove_if_exists(".github/workflows/deploy-ex-release.yml")
      remove_if_exists(".github/github-action-maybe-commit-terraform-changes.sh")
      remove_if_exists(".github/github-actions-secrets-to-json-file.sh")
    end
  end

  defp remove_if_exists(file_path) do
    if File.exists?(file_path) do
      File.rm!(file_path)

      Mix.shell().info([
        :red, "* removing ", :reset, file_path
      ])
    end
  end
end


