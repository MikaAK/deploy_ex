defmodule DeployEx.Config do
  @app :deploy_ex

  def iac_tool, do: Application.get_env(@app, :iac_tool) || "terraform"

  def env, do: Application.get_env(@app, :env) || "dev"
  def aws_region, do: Application.get_env(@app, :aws_region) || "us-west-2"

  def aws_log_region, do: Application.get_env(@app, :aws_log_region) || "us-west-2"

  def aws_log_bucket do
    Application.get_env(@app, :aws_log_bucket) ||
      "#{DeployExHelpers.kebab_project_name()}-backend-logs-#{env()}"
  end

  def aws_release_bucket do
    Application.get_env(@app, :aws_release_bucket) ||
      "#{DeployExHelpers.kebab_project_name()}-elixir-deploys-#{env()}"
  end

  def aws_release_state_bucket do
    Application.get_env(@app, :aws_release_state_bucket) ||
    "#{DeployExHelpers.kebab_project_name()}-elixir-release-state-#{env()}"
  end

  def aws_release_state_lock_table do
    Application.get_env(@app, :aws_terraform_state_lock_table) ||
      "#{DeployExHelpers.kebab_project_name()}-terraform-state-lock-#{env()}"
  end

  def deploy_folder, do: Application.get_env(@app, :deploy_folder) || "./deploys"

  def terraform_folder_path, do: Path.join(deploy_folder(), "terraform")
  def ansible_folder_path, do: Path.join(deploy_folder(), "ansible")

  def terraform_default_args(command) do
    @app
      |> Application.get_env(:terraform_default_args, %{})
      |> Map.get(command, [])
  end
end
