defmodule Mix.Tasks.DeployEx.FindNodes do
  use Mix.Task

  @shortdoc "Find EC2 instances by tags"
  @moduledoc """
  Finds EC2 instances managed by DeployEx with specific tag filters.

  ## Examples

      mix deploy_ex.find_nodes
      mix deploy_ex.find_nodes --setup-incomplete
      mix deploy_ex.find_nodes --setup-complete
      mix deploy_ex.find_nodes --tag Environment=production
      mix deploy_ex.find_nodes --format json
      mix deploy_ex.find_nodes --format ids

  ## Options

    * `--tag KEY=VALUE` - Filter by tag (multiple allowed)
    * `--setup-complete` - Find instances with SetupComplete=true
    * `--setup-incomplete` - Find instances needing setup
    * `--format FORMAT` - Output: table (default), json, ids
    * `--region REGION` - AWS region
    * `--resource-group GROUP` - Filter by resource group name
    * `--quiet` - Suppress messages (alias: `q`)
  """

  alias DeployEx.AwsMachine

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    opts = parse_args(args)

    unless opts[:quiet] do
      region = opts[:region] || DeployEx.Config.aws_region()
      Mix.shell().info("Searching for instances in #{region}...")
    end

    instances =
      case {opts[:setup_complete], opts[:setup_incomplete]} do
        {true, _} ->
          {:ok, instances} = AwsMachine.find_instances_setup_complete([], region: opts[:region], resource_group: opts[:resource_group])
          instances

        {_, true} ->
          {:ok, instances} = AwsMachine.find_instances_needing_setup([], region: opts[:region], resource_group: opts[:resource_group])
          instances

        _ ->
          tag_filters = build_tag_filters(opts)
          {:ok, instances} = AwsMachine.find_instances_by_tags(tag_filters, region: opts[:region], resource_group: opts[:resource_group])
          instances
      end

    parsed_instances = Enum.map(instances, &AwsMachine.parse_instance_info/1)

    case opts[:format] do
      "json" -> output_json(parsed_instances)
      "ids" -> output_ids(parsed_instances)
      _ -> output_table(parsed_instances, opts)
    end

    {:ok, parsed_instances}
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(
      args,
      aliases: [t: :tag, f: :format, r: :region, q: :quiet],
      switches: [
        tag: :keep,
        setup_complete: :boolean,
        setup_incomplete: :boolean,
        format: :string,
        region: :string,
        resource_group: :string,
        quiet: :boolean
      ]
    )

    opts
  end

  defp build_tag_filters(opts) do
    base_filters = [{"ManagedBy", "DeployEx"}]

    custom_filters =
      opts
      |> Keyword.get_values(:tag)
      |> Enum.map(&parse_tag_filter/1)

    base_filters ++ custom_filters
  end

  defp parse_tag_filter(tag_string) do
    case String.split(tag_string, "=", parts: 2) do
      [key, value] -> {key, value}
      _ -> Mix.raise("Invalid tag format. Use KEY=VALUE. Got: #{tag_string}")
    end
  end

  defp output_table([], opts) do
    unless opts[:quiet] do
      Mix.shell().info([:yellow, "\nNo instances found"])
    end
  end

  defp output_table(instances, opts) do
    unless opts[:quiet] do
      Mix.shell().info("\nFound #{length(instances)} instance(s):\n")
    end

    Mix.shell().info(
      String.pad_trailing("Instance ID", 20) <>
      String.pad_trailing("App", 20) <>
      String.pad_trailing("Environment", 15) <>
      String.pad_trailing("Setup", 8) <>
      String.pad_trailing("State", 12) <>
      "Public IP"
    )

    Mix.shell().info(String.duplicate("-", 100))

    Enum.each(instances, fn instance ->
      setup_status = if instance.setup_complete, do: "✓", else: "✗"
      app_name = instance.app_name || "N/A"
      env = instance.environment || "N/A"
      public_ip = instance.public_ip || instance.ipv6 || "N/A"

      Mix.shell().info(
        String.pad_trailing(instance.instance_id, 20) <>
        String.pad_trailing(app_name, 20) <>
        String.pad_trailing(env, 15) <>
        String.pad_trailing(setup_status, 8) <>
        String.pad_trailing(instance.state, 12) <>
        public_ip
      )
    end)

    unless opts[:quiet] do
      Mix.shell().info("")
    end
  end

  defp output_json(instances) do
    instances
    |> Jason.encode!(pretty: true)
    |> Mix.shell().info()
  end

  defp output_ids(instances) do
    instances
    |> Enum.map(& &1.instance_id)
    |> Enum.join(" ")
    |> Mix.shell().info()
  end
end
