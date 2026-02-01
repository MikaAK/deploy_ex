defmodule DeployEx.Config do
  @app :deploy_ex

  def iac_tool, do: Application.get_env(@app, :iac_tool) || "terraform"

  @default_env to_string(Mix.env())
  def env, do: Application.get_env(@app, :env) || @default_env
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

  def aws_resource_group do
    Application.get_env(@app, :aws_resource_group) ||
      "#{DeployEx.Utils.upper_title_case(DeployExHelpers.project_name())} Backend"
  end

  def aws_project_name do
    Application.get_env(@app, :aws_project_name) ||
      DeployExHelpers.kebab_project_name()
  end

  def terraform_folder_path, do: Path.join(deploy_folder(), "terraform")
  def ansible_folder_path, do: Path.join(deploy_folder(), "ansible")

  def terraform_default_args(command) do
    result = @app
      |> Application.get_env(:terraform_default_args, [])
      |> Keyword.filter(fn {key, _} ->
        to_string(command) =~ Regex.compile!(to_string(key))
      end)

    case result do
      [] -> []
      [{_, _} | _] = args_map ->
        args_map
          |> Enum.reduce([], fn {_, args}, acc -> Keyword.merge(acc, args) end)
          |> Enum.reduce([], fn {key, value}, acc ->
            ["--#{String.replace(to_string(key), "_", "-")}", to_string(value) | acc]
          end)
    end
  end
end
