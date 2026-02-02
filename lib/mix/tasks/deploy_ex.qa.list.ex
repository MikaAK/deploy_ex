defmodule Mix.Tasks.DeployEx.Qa.List do
  use Mix.Task

  @shortdoc "Lists all active QA nodes"
  @moduledoc """
  Lists all active QA nodes with their status.

  ## Example
  ```bash
  mix deploy_ex.qa.list
  mix deploy_ex.qa.list --app my_app
  mix deploy_ex.qa.list --json
  ```

  ## Options
  - `--app, -a` - Filter by app name
  - `--json` - Output as JSON
  - `--quiet, -q` - Minimal output
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      opts = parse_args(args)

      case list_qa_nodes(opts) do
        {:ok, []} ->
          unless opts[:quiet] do
            Mix.shell().info([:yellow, "No QA nodes found"])
          end

        {:ok, qa_nodes} ->
          output_qa_nodes(qa_nodes, opts)

        {:error, error} ->
          Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [a: :app, q: :quiet],
      switches: [
        app: :string,
        json: :boolean,
        quiet: :boolean
      ]
    )

    opts
  end

  defp list_qa_nodes(opts) do
    with {:ok, app_names} <- DeployEx.QaNode.list_all_qa_states(opts) do
      qa_nodes = app_names
      |> maybe_filter_by_app(opts[:app])
      |> Enum.flat_map(fn app_name ->
        case DeployEx.QaNode.fetch_all_qa_states_for_app(app_name, opts) do
          {:ok, states} ->
            Enum.map(states, fn qa_node ->
              case DeployEx.QaNode.verify_instance_exists(qa_node) do
                {:ok, verified} when not is_nil(verified) -> verified
                _ -> nil
              end
            end)

          _ ->
            []
        end
      end)
      |> Enum.reject(&is_nil/1)

      {:ok, qa_nodes}
    end
  end

  defp maybe_filter_by_app(app_names, nil), do: app_names
  defp maybe_filter_by_app(app_names, app_filter) do
    Enum.filter(app_names, &(&1 === app_filter or String.contains?(&1, app_filter)))
  end

  defp output_qa_nodes(qa_nodes, %{json: true}) do
    json = qa_nodes
    |> Enum.map(&qa_node_to_map/1)
    |> Jason.encode!(pretty: true)

    Mix.shell().info(json)
  end

  defp output_qa_nodes(qa_nodes, opts) do
    unless opts[:quiet] do
      Mix.shell().info("\nQA Nodes:")
      Mix.shell().info(String.duplicate("-", 80))
    end

    Enum.each(qa_nodes, fn qa_node ->
      state_color = case qa_node.state do
        "running" -> :green
        "stopped" -> :yellow
        "terminated" -> :red
        _ -> :reset
      end

      lb_status = if qa_node.load_balancer_attached?, do: "yes", else: "no"

      Mix.shell().info([
        :cyan, qa_node.app_name, :reset, "\n",
        "  Instance ID: ", qa_node.instance_id || "unknown", "\n",
        "  SHA: ", String.slice(qa_node.target_sha || "", 0, 7), "\n",
        "  State: ", state_color, qa_node.state || "unknown", :reset, "\n",
        "  Public IP: ", qa_node.public_ip || "N/A", "\n",
        "  IPv6: ", qa_node.ipv6_address || "N/A", "\n",
        "  LB Attached: ", lb_status, "\n",
        "  Created: ", qa_node.created_at || "unknown", "\n"
      ])
    end)

    unless opts[:quiet] do
      Mix.shell().info(String.duplicate("-", 80))
      Mix.shell().info("Total: #{length(qa_nodes)} QA node(s)")
    end
  end

  defp qa_node_to_map(qa_node) do
    %{
      app_name: qa_node.app_name,
      instance_id: qa_node.instance_id,
      target_sha: qa_node.target_sha,
      state: qa_node.state,
      public_ip: qa_node.public_ip,
      ipv6_address: qa_node.ipv6_address,
      private_ip: qa_node.private_ip,
      load_balancer_attached: qa_node.load_balancer_attached?,
      target_group_arns: qa_node.target_group_arns,
      created_at: qa_node.created_at
    }
  end
end
