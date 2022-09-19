defmodule DeployEx.Config do
  @app :deploy_ex

  def aws_region, do: Application.get_env(@app, :aws_region) || "us-west-2"

  def aws_log_bucket, do: Application.get_env(@app, :aws_log_bucket) || "#{String.replace(DeployExHelpers.underscored_app_name(), "_", "-")}-backend-logs"
  def aws_log_region, do: Application.get_env(@app, :aws_log_bucket) || "us-west-2"

  def aws_release_bucket, do: Application.get_env(@app, :aws_release_bucket) || "elixir-deploys"

  def deploy_folder, do: Application.get_env(@app, :deploy_folder) || "./deploys"

  def terraform_folder_path, do: Path.join(deploy_folder(), "terraform")
  def ansible_folder_path, do: Path.join(deploy_folder(), "ansible")
end
