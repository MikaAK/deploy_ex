defmodule Mix.Tasks.DeployEx.Qa.DetachLb do
  use Mix.Task

  @shortdoc "Detaches a QA node from the load balancer"
  @moduledoc """
  Detaches a QA node from the load balancer target groups.

  ## Example
  ```bash
  mix deploy_ex.qa.detach_lb my_app
  mix deploy_ex.qa.detach_lb my_app --target-group arn:aws:...
  ```

  ## Options
  - `--target-group` - Specific target group ARN (default: all attached)
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required. Usage: mix deploy_ex.qa.detach_lb <app_name>")
      end

      with {:ok, qa_node} <- fetch_and_verify_qa_node(app_name, opts),
           :ok <- verify_attached(qa_node),
           {:ok, _updated} <- detach_from_target_groups(qa_node, opts) do
        unless opts[:quiet] do
          Mix.shell().info([:green, "\n✓ Detached QA node from load balancer", :reset])
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

  defp verify_attached(%{load_balancer_attached?: false}) do
    {:error, ErrorMessage.bad_request("QA node is not attached to any load balancer")}
  end
  defp verify_attached(_), do: :ok

  defp detach_from_target_groups(qa_node, opts) do
    unless opts[:quiet] do
      Mix.shell().info("Detaching #{qa_node.instance_id} from target groups...")
    end

    DeployEx.QaNode.detach_from_load_balancer(qa_node, opts)
  end
end
