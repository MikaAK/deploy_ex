defmodule Mix.Tasks.DeployEx.Qa.AttachLb do
  use Mix.Task

  @shortdoc "Attaches a QA node to the app's load balancer"
  @moduledoc """
  Attaches a QA node to the app's load balancer target groups.

  ## Example
  ```bash
  mix deploy_ex.qa.attach_lb my_app
  mix deploy_ex.qa.attach_lb my_app --port 4000
  mix deploy_ex.qa.attach_lb my_app --target-group arn:aws:...
  mix deploy_ex.qa.attach_lb --instance-id i-abc123 --target-group arn:aws:...
  mix deploy_ex.qa.attach_lb my_app --instance-id i-abc123
  ```

  ## Options
  - `--instance-id` - EC2 instance ID to attach directly (skips QA state lookup)
  - `--target-group` - Specific target group ARN (default: auto-discover by app name)
  - `--port` - Port to register (default: 4000)
  - `--wait` - Wait for health check to pass
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, extra_args} = parse_args(args)
      app_name = List.first(extra_args)

      with {:ok, qa_node} <- resolve_qa_node(app_name, opts),
           {:ok, target_groups} <- find_target_groups(qa_node, app_name, opts),
           {:ok, updated_qa_node} <- attach_to_target_groups(qa_node, target_groups, opts),
           :ok <- maybe_wait_for_healthy(updated_qa_node, target_groups, opts) do
        if !opts[:quiet] do
          Mix.shell().info([
            :green, "\n✓ Attached ", :cyan, qa_node.instance_id,
            :green, " to ", :cyan, "#{length(target_groups)}",
            :green, " target group(s)", :reset
          ])
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
        port: :integer,
        wait: :boolean,
        quiet: :boolean
      ]
    )
  end

  defp resolve_qa_node(app_name, opts) do
    cond do
      is_binary(opts[:instance_id]) ->
        {:ok, %DeployEx.QaNode{instance_id: opts[:instance_id], app_name: app_name}}

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
        Mix.raise("App name or --instance-id is required. Usage: mix deploy_ex.qa.attach_lb <app_name> or mix deploy_ex.qa.attach_lb --instance-id <id> --target-group <arn>")
    end
  end

  defp find_target_groups(_qa_node, app_name, opts) do
    if is_binary(opts[:target_group]) do
      {:ok, [%{arn: opts[:target_group]}]}
    else
      if is_nil(app_name) do
        Mix.raise("--target-group is required when using --instance-id without an app name")
      end

      case DeployEx.AwsLoadBalancer.find_target_groups_by_app(app_name, opts) do
        {:ok, []} ->
          {:error, ErrorMessage.not_found("no target groups found for app '#{app_name}'")}

        {:ok, target_groups} ->
          {:ok, target_groups}

        error ->
          error
      end
    end
  end

  defp attach_to_target_groups(qa_node, target_groups, opts) do
    arns = Enum.map(target_groups, & &1.arn)

    if !opts[:quiet] do
      Mix.shell().info("Attaching #{qa_node.instance_id} to #{length(arns)} target group(s)...")
    end

    DeployEx.QaNode.attach_to_load_balancer(qa_node, arns, opts)
  end

  defp maybe_wait_for_healthy(qa_node, target_groups, opts) do
    if opts[:wait] !== true do
      :ok
    else
      maybe_do_wait_for_healthy(qa_node, target_groups, opts)
    end
  end

  defp maybe_do_wait_for_healthy(qa_node, target_groups, opts) do
    if !opts[:quiet] do
      Mix.shell().info("Waiting for health checks to pass...")
    end

    results = Enum.map(target_groups, fn tg ->
      DeployEx.AwsLoadBalancer.wait_for_healthy(tg.arn, qa_node.instance_id, 300_000, opts)
    end)

    Enum.find(results, :ok, &match?({:error, _}, &1))
  end
end
