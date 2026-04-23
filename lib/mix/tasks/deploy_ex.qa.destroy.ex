defmodule Mix.Tasks.DeployEx.Qa.Destroy do
  use Mix.Task

  @shortdoc "Destroys a QA node"
  @moduledoc """
  Terminates one or more QA nodes, detaches them from any load balancers, and
  cleans up the S3 state.

  - **No args** — opens an interactive picker across every QA node (every app)
    so you can choose which to destroy (or select all).
  - **App name** — picks from that app's QA nodes; a single node is destroyed
    directly, multiple nodes open a picker.
  - **`--instance-id`** — destroys the exact instance (no picker).
  - **`--all`** — skips the picker and destroys every QA node (still prompts
    for confirmation unless `--force`).

  ## Example
  ```bash
  mix deploy_ex.qa.destroy                          # pick from every QA node
  mix deploy_ex.qa.destroy my_app                   # pick from my_app's QA nodes
  mix deploy_ex.qa.destroy my_app --instance-id i-0abc123
  mix deploy_ex.qa.destroy --all                    # destroy every QA node
  mix deploy_ex.qa.destroy my_app --force           # skip confirmation
  ```

  ## Options
  - `--instance-id, -i` - Destroy a specific instance by ID (skips picker)
  - `--all` - Destroy every QA node across all apps (skips picker)
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
        list_all_qa_nodes(opts)

      is_binary(opts[:instance_id]) ->
        find_node_by_instance_id(opts[:instance_id], opts)

      extra_args !== [] ->
        [app_name | _] = extra_args
        prompt_pick_nodes_for_app(app_name, opts)

      true ->
        prompt_pick_across_all_qa_nodes(opts)
    end
  end

  defp prompt_pick_across_all_qa_nodes(opts) do
    case list_all_qa_nodes(opts) do
      [] ->
        []

      nodes ->
        {:ok, picked} = DeployEx.QaNode.pick_interactive(nodes,
          title: "Select QA node(s) to destroy",
          allow_all: true,
          always_prompt: true
        )
        picked
    end
  end

  defp list_all_qa_nodes(opts) do
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
          allow_all: true,
          always_prompt: true
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
