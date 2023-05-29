defmodule Mix.Tasks.DeployEx.Remake do
  use Mix.Task

  alias Mix.Tasks.{Ansible, Terraform}

  @shortdoc "Runs terraform replace with a node, sets it up and deploys the latest copy"
  @moduledoc """
  Runs terraform replace with a node, sets it up and deploys the latest copy

  ## Example
  ```bash
  $ mix deploy_ex.remake my_app
  ```
  """

  def run(args) do
    {_, node_name, _} = OptionParser.parse(args, switches: [])

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, node_name} <- check_for_node_name(node_name),
         :ok <- run_command(Terraform.Replace, args),
         _ <- Process.sleep(:timer.seconds(5)),
         args_without_name = node_name_as_only_arg(node_name, args),
         :ok <- run_command(Ansible.Setup, args_without_name),
         :ok <- run_command(Ansible.Deploy, args_without_name) do
      :ok
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
    case command.run(args) do
      nil -> :ok
      :ok -> :ok
      [:ok] -> :ok
      {:error, _} = res -> res
      e -> {:error, e}
    end
  end

  defp check_for_node_name([node_name]) do
    {:ok, node_name}
  end

  defp check_for_node_name(_) do
    {:error, "Must supply a node name to remake"}
  end
end
