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
    {opts, node_name, _} = OptionParser.parse(args, switches: [no_deploy: :boolean])

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, node_name} <- check_for_node_name(node_name),
         :ok <- run_command(Terraform.Replace, args),
         _ <- Process.sleep(:timer.seconds(5)),
         args_without_name = node_name_as_only_arg(node_name, args),
         :ok <- run_command(Ansible.Setup, args_without_name),
         :ok <- maybe_redeploy(args_without_name, opts) do
      :ok
    else
      {:error, e} -> Mix.raise(e)
    end
  end

  defp maybe_redeploy(args_without_name, opts) do
    if opts[:no_deploy] do
      :ok
    else
      run_command(Ansible.Deploy, args_without_name)
    end
  end

  defp node_name_as_only_arg(node_name, args) do
    args
      |> Enum.join(" ")
      |> String.replace(node_name, "--only #{node_name}")
      |> String.split(" ")
  end

  defp run_command(command, args) do
    case command.run(args) do
      nil -> :ok
      :ok -> :ok
      [:ok] -> :ok
      {:error, _} = res -> res
      e -> {:error, e}
    end
  end

  defp check_for_node_name([node_name]) do
    DeployExHelpers.find_app_name([node_name])
  end

  defp check_for_node_name(_) do
    {:error, "Must supply a node name to remake"}
  end
end
