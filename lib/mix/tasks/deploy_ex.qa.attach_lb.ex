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
  ```

  ## Options
  - `--target-group` - Specific target group ARN (default: auto-discover)
  - `--port` - Port to register (default: 4000)
  - `--wait` - Wait for health check to pass
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required. Usage: mix deploy_ex.qa.attach_lb <app_name>")
      end

      with {:ok, qa_node} <- fetch_and_verify_qa_node(app_name, opts),
           {:ok, target_groups} <- find_target_groups(qa_node, opts),
           {:ok, updated_qa_node} <- attach_to_target_groups(qa_node, target_groups, opts),
           :ok <- maybe_wait_for_healthy(updated_qa_node, target_groups, opts) do
        unless opts[:quiet] do
          Mix.shell().info([
            :green, "\n✓ Attached QA node to ", :cyan, "#{length(target_groups)}",
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
        target_group: :string,
        port: :integer,
        wait: :boolean,
        quiet: :boolean
      ]
    )
  end

  defp fetch_and_verify_qa_node(app_name, opts) do
    case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
      {:ok, nil} ->
        {:error, ErrorMessage.not_found("no QA node found for app '#{app_name}'")}

      {:ok, qa_node} ->
        DeployEx.QaNode.verify_instance_exists(qa_node)

      error ->
        error
    end
  end

  defp find_target_groups(_qa_node, %{target_group: arn}) when not is_nil(arn) do
    {:ok, [%{arn: arn}]}
  end

  defp find_target_groups(qa_node, opts) do
    case DeployEx.AwsLoadBalancer.find_target_groups_by_app(qa_node.app_name, opts) do
      {:ok, []} ->
        {:error, ErrorMessage.not_found("no target groups found for app '#{qa_node.app_name}'")}

      {:ok, target_groups} ->
        {:ok, target_groups}

      error ->
        error
    end
  end

  defp attach_to_target_groups(qa_node, target_groups, opts) do
    arns = Enum.map(target_groups, & &1.arn)

    unless opts[:quiet] do
      Mix.shell().info("Attaching #{qa_node.instance_id} to #{length(arns)} target group(s)...")
    end

    DeployEx.QaNode.attach_to_load_balancer(qa_node, arns, opts)
  end

  defp maybe_wait_for_healthy(_qa_node, _target_groups, %{wait: false}), do: :ok
  defp maybe_wait_for_healthy(_qa_node, _target_groups, %{wait: nil}), do: :ok

  defp maybe_wait_for_healthy(qa_node, target_groups, opts) do
    unless opts[:quiet] do
      Mix.shell().info("Waiting for health checks to pass...")
    end

    results = Enum.map(target_groups, fn tg ->
      DeployEx.AwsLoadBalancer.wait_for_healthy(tg.arn, qa_node.instance_id, 300_000, opts)
    end)

    error = Enum.find(results, &match?({:error, _}, &1))

    if is_nil(error) do
      :ok
    else
      error
    end
  end
end
