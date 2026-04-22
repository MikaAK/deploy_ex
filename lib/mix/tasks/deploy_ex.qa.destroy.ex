defmodule Mix.Tasks.DeployEx.Qa.Destroy do
  use Mix.Task

  @shortdoc "Destroys a QA node"
  @moduledoc """
  Terminates a QA node and cleans up resources.

  ## Example
  ```bash
  mix deploy_ex.qa.destroy my_app
  mix deploy_ex.qa.destroy --instance-id i-0abc123
  mix deploy_ex.qa.destroy --all
  mix deploy_ex.qa.destroy my_app --force
  ```

  ## Options
  - `--instance-id, -i` - Specific instance ID to destroy
  - `--all` - Destroy all QA nodes
  - `--force, -f` - Skip confirmation prompt
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, extra_args} = parse_args(args)

      case select_nodes(extra_args, opts) do
        [] ->
          Mix.shell().info([:yellow, "No QA nodes to destroy"])

        nodes ->
          unless opts[:force] do
            prompt_confirmation(nodes)
          end

          Enum.each(nodes, &destroy_qa_node(&1, opts))

          Mix.shell().info([:green, "\n✓ Destroyed #{length(nodes)} QA node(s)"])
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [i: :instance_id, f: :force, q: :quiet],
      switches: [
        instance_id: :string,
        all: :boolean,
        force: :boolean,
        quiet: :boolean
      ]
    )
  end

  defp select_nodes(extra_args, opts) do
    cond do
      opts[:all] === true ->
        find_all_qa_nodes(opts)

      is_binary(opts[:instance_id]) ->
        find_node_by_instance_id(opts[:instance_id], opts)

      extra_args !== [] ->
        [app_name | _] = extra_args
        prompt_pick_nodes_for_app(app_name, opts)

      true ->
        Mix.raise("App name, --instance-id, or --all is required")
    end
  end

  defp find_all_qa_nodes(opts) do
    case DeployEx.QaNode.list_all_qa_states(opts) do
      {:ok, app_names} ->
        Enum.flat_map(app_names, fn app_name ->
          case DeployEx.QaNode.find_qa_nodes_for_app(app_name, opts) do
            {:ok, nodes} -> nodes
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp find_node_by_instance_id(instance_id, opts) do
    case DeployEx.QaNode.list_all_qa_states(opts) do
      {:ok, app_names} ->
        Enum.flat_map(app_names, fn app_name ->
          case DeployEx.QaNode.find_qa_nodes_for_app(app_name, opts) do
            {:ok, nodes} -> Enum.filter(nodes, &(&1.instance_id === instance_id))
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp prompt_pick_nodes_for_app(app_name, opts) do
    case DeployEx.QaNode.find_qa_nodes_for_app(app_name, opts) do
      {:ok, nodes} ->
        {:ok, picked} = DeployEx.QaNode.pick_interactive(nodes,
          title: "Select QA node(s) to destroy",
          allow_all: true
        )
        picked

      _ ->
        []
    end
  end

  defp prompt_confirmation(nodes) do
    Mix.shell().info("\nQA nodes to destroy:")

    Enum.each(nodes, fn qa_node ->
      Mix.shell().info([
        "  - ", :cyan, qa_node.instance_name || qa_node.app_name, :reset,
        " (", qa_node.instance_id, ", SHA: ", sha_display(qa_node.target_sha), ")"
      ])
    end)

    unless Mix.shell().yes?("\nProceed with destruction?") do
      Mix.raise("Aborted")
    end
  end

  defp sha_display(nil), do: "N/A"
  defp sha_display(""), do: "N/A"
  defp sha_display(sha), do: String.slice(sha, 0, 7)

  defp destroy_qa_node(qa_node, opts) do
    unless opts[:quiet] do
      Mix.shell().info("Destroying #{qa_node.instance_name || qa_node.app_name} (#{qa_node.instance_id})...")
    end

    case DeployEx.QaNode.terminate_qa_node(qa_node, opts) do
      :ok ->
        unless opts[:quiet] do
          Mix.shell().info([:green, "  ✓ Destroyed #{qa_node.instance_name || qa_node.instance_id}"])
        end

      {:error, error} ->
        Mix.shell().error("  ✗ Failed to destroy #{qa_node.instance_name || qa_node.instance_id}: #{ErrorMessage.to_string(error)}")
    end
  end
end
