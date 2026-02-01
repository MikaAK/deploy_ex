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

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      qa_nodes = find_qa_nodes_to_destroy(extra_args, opts)

      case qa_nodes do
        [] ->
          Mix.shell().info([:yellow, "No QA nodes found to destroy"])

        nodes ->
          unless opts[:force] do
            prompt_confirmation(nodes)
          end

          Enum.each(nodes, fn qa_node ->
            destroy_qa_node(qa_node, opts)
          end)

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

  defp find_qa_nodes_to_destroy(_extra_args, %{all: true} = opts) do
    case DeployEx.QaNode.list_all_qa_states(opts) do
      {:ok, app_names} ->
        app_names
        |> Enum.map(fn app_name ->
          case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
            {:ok, qa_node} when not is_nil(qa_node) -> qa_node
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp find_qa_nodes_to_destroy(_extra_args, %{instance_id: instance_id} = opts) when not is_nil(instance_id) do
    case DeployEx.QaNode.list_all_qa_states(opts) do
      {:ok, app_names} ->
        app_names
        |> Enum.map(fn app_name ->
          case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
            {:ok, %{instance_id: ^instance_id} = qa_node} -> qa_node
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp find_qa_nodes_to_destroy(extra_args, opts) do
    case extra_args do
      [app_name | _] ->
        case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
          {:ok, qa_node} when not is_nil(qa_node) -> [qa_node]
          _ -> []
        end

      [] ->
        Mix.raise("App name, --instance-id, or --all is required")
    end
  end

  defp prompt_confirmation(nodes) do
    Mix.shell().info("\nQA nodes to destroy:")

    Enum.each(nodes, fn qa_node ->
      Mix.shell().info([
        "  - ", :cyan, qa_node.app_name, :reset,
        " (", qa_node.instance_id, ", SHA: ", String.slice(qa_node.target_sha || "", 0, 7), ")"
      ])
    end)

    unless Mix.shell().yes?("\nProceed with destruction?") do
      Mix.raise("Aborted")
    end
  end

  defp destroy_qa_node(qa_node, opts) do
    unless opts[:quiet] do
      Mix.shell().info("Destroying #{qa_node.app_name} (#{qa_node.instance_id})...")
    end

    case DeployEx.QaNode.terminate_qa_node(qa_node, opts) do
      :ok ->
        unless opts[:quiet] do
          Mix.shell().info([:green, "  ✓ Destroyed #{qa_node.instance_id}"])
        end

      {:error, error} ->
        Mix.shell().error("  ✗ Failed to destroy #{qa_node.instance_id}: #{ErrorMessage.to_string(error)}")
    end
  end
end
