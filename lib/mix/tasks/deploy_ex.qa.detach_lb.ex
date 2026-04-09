defmodule Mix.Tasks.DeployEx.Qa.DetachLb do
  use Mix.Task

  @shortdoc "Detaches a QA node from the load balancer"
  @moduledoc """
  Detaches a QA node from the load balancer target groups.

  ## Example
  ```bash
  mix deploy_ex.qa.detach_lb my_app
  mix deploy_ex.qa.detach_lb my_app --target-group arn:aws:...
  mix deploy_ex.qa.detach_lb --instance-id i-abc123 --target-group arn:aws:...
  mix deploy_ex.qa.detach_lb my_app --instance-id i-abc123
  ```

  ## Options
  - `--instance-id` - EC2 instance ID to detach directly (skips QA state lookup)
  - `--target-group` - Specific target group ARN (default: all attached)
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, extra_args} = parse_args(args)
      app_name = List.first(extra_args)

      with {:ok, qa_node} <- resolve_qa_node(app_name, opts),
           {:ok, _updated} <- detach_from_target_groups(qa_node, opts) do
        if !opts[:quiet] do
          Mix.shell().info([:green, "\n✓ Detached ", :cyan, qa_node.instance_id, :green, " from load balancer", :reset])
        end
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [q: :quiet],
      switches: [
        instance_id: :string,
        target_group: :string,
        quiet: :boolean
      ]
    )
  end

  defp resolve_qa_node(app_name, opts) do
    cond do
      is_binary(opts[:instance_id]) ->
        instance_id = opts[:instance_id]

        case fetch_existing_qa_node(app_name, instance_id, opts) do
          {:ok, qa_node} ->
            {:ok, qa_node}

          {:error, _} ->
            {:ok, %DeployEx.QaNode{
              instance_id: instance_id,
              app_name: app_name,
              load_balancer_attached?: true,
              target_group_arns: target_group_arns_from_opts(opts)
            }}
        end

      is_binary(app_name) ->
        case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
          {:ok, nil} ->
            {:error, ErrorMessage.not_found("no QA node found for app '#{app_name}'")}

          {:ok, qa_node} ->
            DeployEx.QaNode.verify_instance_exists(qa_node)

          error ->
            error
        end

      true ->
        Mix.raise("App name or --instance-id is required. Usage: mix deploy_ex.qa.detach_lb <app_name> or mix deploy_ex.qa.detach_lb --instance-id <id> --target-group <arn>")
    end
  end

  defp fetch_existing_qa_node(app_name, instance_id, opts) when is_binary(app_name) do
    case DeployEx.QaNode.fetch_qa_state(app_name, instance_id, opts) do
      {:ok, %DeployEx.QaNode{} = qa_node} -> {:ok, qa_node}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_existing_qa_node(_app_name, _instance_id, _opts), do: {:error, :not_found}

  defp target_group_arns_from_opts(opts) do
    if is_binary(opts[:target_group]) do
      [opts[:target_group]]
    else
      []
    end
  end

  defp detach_from_target_groups(qa_node, opts) do
    if !opts[:quiet] do
      Mix.shell().info("Detaching #{qa_node.instance_id} from target groups...")
    end

    DeployEx.QaNode.detach_from_load_balancer(qa_node, opts)
  end
end
