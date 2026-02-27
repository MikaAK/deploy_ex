defmodule Mix.Tasks.DeployEx.Remake do
  use Mix.Task

  alias Mix.Tasks.{Ansible, Terraform}

  @shortdoc "Replaces and redeploys a specific application node"
  @moduledoc """
  Replaces a specific application node using Terraform, sets it up with Ansible, and redeploys the application.

  This task performs the following steps:
  1. Destroys and recreates the specified node's infrastructure using Terraform
  2. Waits for the new node to initialize
  3. Configures the node using Ansible setup
  4. Deploys the latest application version (unless --no-deploy is specified)

  ## Example
  ```bash
  # Replace and redeploy the my_app node
  mix deploy_ex.remake my_app

  # Replace node but skip redeployment
  mix deploy_ex.remake my_app --no-deploy
  ```

  ## Options
  - `--no-deploy` - Skip redeploying the application after node replacement
  """

  def run(args) do
    {opts, node_name, _} = OptionParser.parse(args, switches: [no_deploy: :boolean, no_tui: :boolean])

    DeployEx.TUI.setup_no_tui(opts)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, node_name} <- check_for_node_name(node_name) do
      args_without_name = node_name_as_only_arg(node_name, args)

      steps = [
        {"Replacing #{node_name} via Terraform", fn ->
          run_command(Terraform.Replace, args)
        end},
        {"Waiting for new node to initialize", fn ->
          Process.sleep(:timer.seconds(5))
          :ok
        end},
        {"Running Ansible setup for #{node_name}", fn ->
          run_command(Ansible.Setup, args_without_name)
        end}
      ]

      steps = if opts[:no_deploy] do
        steps
      else
        steps ++ [{"Deploying #{node_name} via Ansible", fn ->
          run_command(Ansible.Deploy, args_without_name)
        end}]
      end

      case DeployEx.TUI.Progress.run_steps(steps, title: "Remake #{node_name}") do
        :ok -> :ok
        {:error, error} -> Mix.raise(to_string(error))
      end
    else
      {:error, e} -> Mix.raise(e)
    end
  end

  defp node_name_as_only_arg(node_name, args) do
    args
      |> Enum.join(" ")
      |> String.replace(node_name, "--only #{node_name}")
      |> String.split(" ")
  end

  defp run_command(command, args) do
    result = command.run(args)

    if is_nil(result) do
      :ok
    else
      case result do
        :ok -> :ok
        [:ok] -> :ok
        {:error, _} = res -> res
        e -> {:error, e}
      end
    end
  end

  defp check_for_node_name([node_name]) do
    DeployExHelpers.find_project_name([node_name])
  end

  defp check_for_node_name(_) do
    {:error, "Must supply a node name to remake"}
  end
end
