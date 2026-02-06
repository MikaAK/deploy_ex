defmodule Mix.Tasks.DeployEx.SelectNode do
  use Mix.Task

  @shortdoc "Select an EC2 instance and output its instance id"

  @moduledoc """
  Lists EC2 instances managed by DeployEx and lets you select a single node.

  By default QA nodes are excluded; pass --qa to include only QA nodes.

  ## Examples

      mix deploy_ex.select_node
      mix deploy_ex.select_node my_app
      mix deploy_ex.select_node my_app --short
      mix deploy_ex.select_node --qa

  ## Options

    * `--short`, `-s` - Output only the selected instance id
    * `--qa` - Include only QA nodes (optionally filter by app_name)
    * `--region` - AWS region
    * `--resource_group` - AWS resource group
  """

  alias DeployEx.AwsMachine

  def run(args) do
    Enum.each([:hackney, :ex_aws], &Application.ensure_all_started/1)

    {opts, app_params} = parse_args(args)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, instance_infos} <- fetch_instances(app_params, opts),
         {:ok, selected_instance} <- select_instance(instance_infos) do
      output_selected(selected_instance, opts)
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :short, r: :region],
      switches: [
        short: :boolean,
        qa: :boolean,
        region: :string,
        resource_group: :string
      ]
    )
  end

  defp fetch_instances(app_params, opts) do
    tag_filters = [{"ManagedBy", "DeployEx"}]

    with {:ok, instances} <- AwsMachine.find_instances_by_tags(tag_filters, region: opts[:region], resource_group: opts[:resource_group]) do
      parsed =
        instances
        |> Enum.map(&AwsMachine.parse_instance_info/1)
        |> maybe_filter_by_app_name(app_params)
        |> filter_by_qa(opts)

      {:ok, parsed}
    end
  end

  defp maybe_filter_by_app_name(instances, []), do: instances

  defp maybe_filter_by_app_name(instances, [app_name | _]) do
    Enum.filter(instances, fn instance ->
      instance_app_name = instance.app_name
      is_binary(instance_app_name) and instance_app_name =~ app_name
    end)
  end

  defp filter_by_qa(instances, opts) do
    if opts[:qa] === true do
      Enum.filter(instances, fn instance -> instance.tags["QaNode"] === "true" end)
    else
      Enum.reject(instances, fn instance -> instance.tags["QaNode"] === "true" end)
    end
  end

  defp select_instance([]) do
    {:error, ErrorMessage.not_found("no instances found")}
  end

  defp select_instance([instance]) do
    {:ok, instance}
  end

  defp select_instance(instances) do
    choices =
      instances
      |> Enum.map(fn instance ->
        public_ip = instance.public_ip || instance.ipv6 || "N/A"
        app_name = instance.app_name || "N/A"
        environment = instance.environment || "N/A"
        "#{instance.instance_id} #{app_name} #{environment} #{public_ip}"
      end)

    [choice] = DeployExHelpers.prompt_for_choice(choices, false)

    selected_instance =
      Enum.find(instances, fn instance ->
        public_ip = instance.public_ip || instance.ipv6 || "N/A"
        app_name = instance.app_name || "N/A"
        environment = instance.environment || "N/A"
        "#{instance.instance_id} #{app_name} #{environment} #{public_ip}" === choice
      end)

    {:ok, selected_instance}
  end

  defp output_selected(instance, opts) do
    if opts[:short] do
      Mix.shell().info(instance.instance_id)
    else
      Mix.shell().info([
        :green,
        "Selected instance: ",
        :reset,
        instance.instance_id
      ])
    end

    {:ok, instance.instance_id}
  end
end
