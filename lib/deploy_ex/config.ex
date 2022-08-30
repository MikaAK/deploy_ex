defmodule DeployEx.Config do
  @app :deploy_ex

  def aws_region, do: Application.get_env(@app, :aws_region) || "us-west-2"
  def aws_release_bucket, do: Application.get_env(@app, :aws_release_bucket) || "elixir-deploys"
  def aws_release_region, do: Application.get_env(@app, :aws_release_region) || "us-west-2"
  def deploy_folder, do: Application.get_env(@app, :deploy_folder) || "./deploys"

  def terraform_folder_path, do: Path.join(deploy_folder(), "terraform")
  def ansible_folder_path, do: Path.join(deploy_folder(), "ansible")
end
