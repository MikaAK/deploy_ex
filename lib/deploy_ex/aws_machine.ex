defmodule DeployEx.AwsMachine do
  @moduledoc """
  EC2 instance discovery and lifecycle, and the AWS implementation of `DeployEx.Cloud.Machine`.

  The behaviour callbacks return `%DeployEx.Cloud.Instance{}`. The older functions below return
  provider-shaped maps and keep doing so — seven Mix-task call sites depend on their shape, and
  `mix deploy_ex.find_nodes --format json` publishes it as a user-visible contract. The caller
  sweep moves those onto the callbacks; until then both live here side by side.
  """

  @behaviour DeployEx.Cloud.Machine

  @impl DeployEx.Cloud.Machine
  def list_instances(tag_filters, opts \\ []) when is_list(tag_filters) do
    with {:ok, instances} <- find_instances_by_tags(tag_filters, opts) do
      {:ok, Enum.map(instances, &to_instance/1)}
    end
  end

  @impl DeployEx.Cloud.Machine
  def find_app_instances(project_name, app_name, opts \\ []) do
    with {:ok, instances} <- scoped_running_instances(opts) do
      case Enum.filter(instances, &instance_in_app?(&1, app_name)) do
        [] ->
          {:error,
           ErrorMessage.not_found("no instances found for #{app_name}", %{
             app_name: app_name,
             project_name: project_name
           })}

        matching ->
          {:ok, Enum.map(matching, &to_instance/1)}
      end
    end
  end

  @impl DeployEx.Cloud.Machine
  def describe_instance(instance_id, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    # Whitelisted, not forwarded whole: opts reaching this callback often carries a caller's
    # full task opts (--pem path, :provider, :quiet, ...), and find_instances_by_id/3 passes
    # anything beyond :request_fn straight into ExAws.EC2.describe_instances/1 as real API
    # query params — an unfiltered forward would leak a pem file PATH to AWS and CloudTrail as
    # "Pem" => "/secret/path/key.pem", and camelize every other stray key into a bogus filter.
    ec2_opts = Keyword.take(opts, [:request_fn])

    with {:ok, [instance | _rest]} <- find_instances_by_id(region, [instance_id], ec2_opts) do
      {:ok, to_instance(instance)}
    end
  end

  @impl DeployEx.Cloud.Machine
  def start_instance(instance_id, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    with {:ok, _response} <- start(region, [instance_id]), do: :ok
  end

  @impl DeployEx.Cloud.Machine
  def stop_instance(instance_id, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    with {:ok, _response} <- stop(region, [instance_id]), do: :ok
  end

  @impl DeployEx.Cloud.Machine
  def fetch_tags(instance_id, opts \\ []) do
    with {:ok, instance} <- describe_instance(instance_id, opts) do
      {:ok, instance.tags}
    end
  end

  @doc """
  Preferred reachable address, IPv6 first.

  IPv6 wins because `find_instance_ips/3` has made that choice since before this behaviour
  existed, and the deploy path depends on it.
  """
  @impl DeployEx.Cloud.Machine
  def instance_address(%DeployEx.Cloud.Instance{} = instance) do
    case instance.ipv6 || instance.public_ip do
      nil -> {:error, ErrorMessage.not_found("instance has no reachable address", %{id: instance.id})}
      address -> {:ok, address}
    end
  end

  @doc """
  Translates a provider-neutral run-instance spec into EC2 `RunInstances` params.

  Implements the optional `DeployEx.Cloud.Machine.run_instance/2` callback so
  `DeployEx.K6Runner.create_instance/2` can build one spec and let each provider's adapter
  translate it, instead of assembling EC2-shaped params itself.
  """
  @impl DeployEx.Cloud.Machine
  def run_instance(spec, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    spec.network[:ami_id]
    |> ExAws.EC2.run_instances(1, 1, run_instance_params(spec))
    |> request_fn.(region: region)
    |> handle_run_instance_response()
  end

  @default_instance_type "t3.small"

  defp run_instance_params(spec) do
    [
      {"InstanceType", spec.instance_type || @default_instance_type},
      {"KeyName", spec.network[:key_name]},
      {"NetworkInterface.1.DeviceIndex", "0"},
      {"NetworkInterface.1.SubnetId", spec.network[:subnet_id]},
      {"NetworkInterface.1.SecurityGroupId.1", spec.network[:security_group_id]},
      {"NetworkInterface.1.AssociatePublicIpAddress", "true"},
      {"UserData", Base.encode64(spec.user_data)},
      iam_instance_profile: [name: spec.network[:iam_instance_profile]],
      tag_specifications: [{:instance, spec.tags}]
    ]
  end

  defp handle_run_instance_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"RunInstancesResponse" => %{"instancesSet" => %{"item" => %{"instanceId" => instance_id}}}} ->
        {:ok, %DeployEx.Cloud.Instance{id: instance_id}}

      %{"RunInstancesResponse" => %{"instancesSet" => %{"item" => [%{"instanceId" => instance_id} | _]}}} ->
        {:ok, %DeployEx.Cloud.Instance{id: instance_id}}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse run instances response from aws",
          %{structure: structure}
        )}
    end
  end

  defp handle_run_instance_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error creating instance",
      %{error_body: body}
    ])}
  end

  @doc "Implements the optional `DeployEx.Cloud.Machine.terminate_instance/2` callback."
  @impl DeployEx.Cloud.Machine
  def terminate_instance(instance_id, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    [instance_id]
    |> ExAws.EC2.terminate_instances()
    |> request_fn.(region: region)
    |> handle_terminate_instance_response()
  end

  defp handle_terminate_instance_response({:ok, _}), do: :ok

  defp handle_terminate_instance_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error terminating instance",
      %{error_body: body}
    ])}
  end

  @doc """
  Blocks until every instance id reports running. Implements the optional
  `DeployEx.Cloud.Machine.await_running/2` callback by wrapping `wait_for_started/3` rather
  than reimplementing its poll loop — `:wait_for_started_fn` is the injection seam that makes
  the wrapping relationship (not the poll loop itself) testable.
  """
  @impl DeployEx.Cloud.Machine
  def await_running(instance_ids, opts \\ [])

  def await_running([], _opts) do
    {:error, ErrorMessage.bad_request("await_running requires at least one instance id")}
  end

  def await_running(instance_ids, opts) do
    region = opts[:region] || DeployEx.Config.aws_region()
    retries = opts[:retries] || 10
    wait_fn = opts[:wait_for_started_fn] || (&wait_for_started/3)

    wait_fn.(region, instance_ids, retries)
  end

  defp scoped_running_instances(opts) do
    region = opts[:region] || DeployEx.Config.aws_region()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    with {:ok, instances} <- fetch_instances_by_tag(region, "Group", resource_group) do
      {:ok,
       instances
       |> Enum.filter(&running_with_instance_group?/1)
       |> maybe_reject_qa_nodes(opts)}
    end
  end

  defp running_with_instance_group?(instance) do
    instance["instanceState"]["name"] === "running" and
      not is_nil(get_instance_tags(instance)["InstanceGroup"])
  end

  defp maybe_reject_qa_nodes(instances, opts) do
    if opts[:exclude_qa_nodes] === true do
      Enum.reject(instances, &(get_instance_tags(&1)["QaNode"] === "true"))
    else
      instances
    end
  end

  defp instance_in_app?(instance, app_name) do
    instance |> get_instance_tags() |> Map.get("InstanceGroup", "") =~ app_name
  end

  def start(region \\ DeployEx.Config.aws_region(), instance_ids) do
    instance_ids
      |> ExAws.EC2.start_instances()
      |> ex_aws_request(region)
      |> handle_describe_response
  end

  def stop(region \\ DeployEx.Config.aws_region(), instance_ids) do
    instance_ids
      |> ExAws.EC2.stop_instances()
      |> ex_aws_request(region)
      |> handle_describe_response
  end

  def wait_for_started(region \\ DeployEx.Config.aws_region(), instance_ids, retries \\ 10) do
    case find_instances_by_id(region, instance_ids) do
      {:ok, instances} ->
        cond do
          Enum.all?(instances, &instance_started?/1) ->
            :ok

          Enum.any?(instances, &(instance_pending?(&1) or instance_stopped?(&1))) ->
            Process.sleep(500)

            wait_for_started(region, instance_ids, retries)

          true ->
            {:error, ErrorMessage.failed_dependency(
              "instance not started but not pending either",
              %{instance_ids: instance_ids}
            )}
        end

      {:error, %ErrorMessage{code: :not_found}} when retries > 0 ->
        Process.sleep(1000)
        wait_for_started(region, instance_ids, retries - 1)

      error ->
        error
    end
  end

  def wait_for_stopped(region \\ DeployEx.Config.aws_region(), instance_ids) do
    with {:ok, instances} <- find_instances_by_id(region, instance_ids) do
      cond do
        Enum.all?(instances, &instance_stopped?/1) ->
          :ok

        Enum.any?(instances, &(instance_pending?(&1) or instance_started?(&1))) ->
          Process.sleep(500)

          wait_for_stopped(region, instance_ids)

        true ->
          {:error, ErrorMessage.failed_dependency(
            "instance not stopped but not pending either",
            %{instance_ids: instance_ids}
          )}
      end
    end
  end

  defp instance_pending?(instance) do
    instance["instanceState"]["name"] in ["pending", "stopping", "starting"]
  end

  defp instance_started?(instance) do
    instance["instanceState"]["name"] in ["started", "running"]
  end

  defp instance_stopped?(instance) do
    instance["instanceState"]["name"] === "stopped"
  end

  defp instance_terminated?(instance) do
    instance["instanceState"]["name"] in ["terminated", "shutting-down"]
  end

  defp instance_running_or_pending?(instance) do
    instance["instanceState"]["name"] in ["pending", "running", "starting"]
  end

  def find_instances_by_id(region \\ DeployEx.Config.aws_region(), instance_ids, opts \\ []) do
    with {:ok, instances} <- fetch_instances(region, opts) do
      case filter_by_instance_id(instances, instance_ids) do
        [] -> {:error, ErrorMessage.not_found("no aws instances found with those instance ids")}
        instances -> {:ok, instances}
      end
    end
  end

  def fetch_instance_ids_by_tag(region \\ DeployEx.Config.aws_region(), tag_name, tag) do
    with {:ok, instances} <- fetch_instances_by_tag(region, tag_name, tag) do
      {:ok, instances_to_id_map(instances)}
    end
  end

  def fetch_instance_ids_by_tags(tag_filters, opts \\ []) when is_list(tag_filters) do
    region = opts[:region] || DeployEx.Config.aws_region()
    all_filters = tag_filters ++ resource_group_filter(opts)

    with {:ok, instances} <- fetch_instances(region) do
      {:ok, instances |> filter_instances_by_tags(all_filters) |> instances_to_id_map}
    end
  end

  def find_instance_ids_by_app_name(app_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    with {:ok, instances} <- fetch_instances_by_tag(region, "Group", resource_group) do
      matching = Enum.filter(instances, fn instance ->
        instance_group = instance |> get_instance_tags() |> Map.get("InstanceGroup")
        instance_group && instance_group =~ app_name
      end)

      case matching do
        [] -> {:error, ErrorMessage.not_found("no instances found matching #{app_name}")}
        found -> {:ok, instances_to_id_map(found)}
      end
    end
  end

  defp instances_to_id_map(instances) do
    Map.new(instances, &{find_instance_name(&1), &1["instanceId"]})
  end

  defp find_instance_name(%{"tagSet" => %{"item" => items}}) do
    Enum.find_value(items, fn %{"key" => key, "value" => value} ->
      if key === "Name" do
        value
      end
    end)
  end

  def fetch_instances_by_tag(region \\ DeployEx.Config.aws_region(), tag_name, tag) do
    with {:ok, instances} <- fetch_instances(region) do
      case filter_by_tag(instances, tag_name, tag) do
        [] -> {:error, ErrorMessage.not_found("no aws instances found with the tag #{tag_name} of #{tag}")}

        tags -> {:ok, tags}
      end
    end
  end

  @doc """
  Every instance in the region, following pagination to completion.

  DescribeInstances caps a response and signals more via `nextToken`. A single request therefore
  truncates silently on a large account — it returns `{:ok, partial}`, not an error — which would
  make every caller here (tag filters, setup-state queries, `mix deploy_ex.find_nodes`) quietly
  miss instances. `AwsAutoscaling.fetch_all_asgs/5` already paginates for the same reason.
  """
  def fetch_instances(region, opts \\ []) do
    fetch_instances_page(region, opts, nil, [])
  end

  defp fetch_instances_page(region, opts, next_token, acc) do
    # :request_fn is the injection seam for page-boundary tests. It is split out of opts before
    # they become EC2 request params, since anything left in opts is sent to the API.
    {request_fn, describe_opts} = Keyword.pop(opts, :request_fn, &ExAws.request/2)

    request_opts =
      if next_token, do: Keyword.put(describe_opts, :next_token, next_token), else: describe_opts

    response =
      request_opts
      |> ExAws.EC2.describe_instances()
      |> request_fn.(region: region || DeployEx.Config.aws_region())

    with {:ok, instances} <- handle_describe_response(response) do
      accumulated = acc ++ instances

      case describe_next_token(response) do
        nil -> {:ok, accumulated}
        token -> fetch_instances_page(region, opts, token, accumulated)
      end
    end
  end

  defp describe_next_token({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeInstancesResponse" => %{"nextToken" => token}}
      when is_binary(token) and token !== "" ->
        token

      _no_more_pages ->
        nil
    end
  end

  defp describe_next_token(_response), do: nil

  defp ex_aws_request(request_struct, nil) do
    ExAws.request(request_struct)
  end

  defp ex_aws_request(request_struct, region) do
    ExAws.request(request_struct, region: region)
  end

  defp handle_describe_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error with fetching from aws",
      %{error_body: body}
    ])}
  end

  defp handle_describe_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"StopInstancesResponse" => %{"instancesSet" => %{"item" => item}}} ->
        {:ok, item}

      %{"StartInstancesResponse" => %{"instancesSet" => %{"item" => item}}} ->
        {:ok, item}

      %{"DescribeInstancesResponse" => %{"reservationSet" => %{"item" => items}}} when is_list(items) ->
        {:ok, Enum.flat_map(items, &extract_instances_from_reservation/1)}

      %{"DescribeInstancesResponse" => %{"reservationSet" => %{"item" => item}}} ->
        {:ok, extract_instances_from_reservation(item)}

      %{"DescribeInstancesResponse" => %{"reservationSet" => nil}} ->
        {:ok, []}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse the structure from aws correctly",
          %{structure: structure}
        )}
    end
  end

  defp extract_instances_from_reservation(%{"instancesSet" => %{"item" => items}}) when is_list(items), do: items
  defp extract_instances_from_reservation(%{"instancesSet" => %{"item" => item}}), do: [item]

  defp filter_by_tag(instances, tag_name, tag_value) do
    Enum.filter(instances, fn instance ->
      has_tag?(instance, tag_name, tag_value)
    end)
  end

  defp filter_by_instance_id(instances, instance_ids) do
    Enum.filter(instances, &(&1["instanceId"] in instance_ids))
  end

  @doc """
  Finds a suitable jump server from available EC2 instances.
  Returns {:ok, ip} or {:error, reason}
  """
  def find_jump_server(project_name, opts \\ []) do
    with {:ok, instances} <- DeployEx.AwsMachine.fetch_instance_groups(project_name, opts) do
      server_ips = Enum.flat_map(instances, fn {name, instances} ->
        Enum.map(instances, fn %{ip: ip, ipv6: ipv6, name: server_name} -> {ip, ipv6, "#{name} (#{server_name})"} end)
      end)

      case server_ips do
        [{ip, ipv6, _}] -> {:ok, {ip, ipv6}}  # Single server case
        servers when servers !== [] ->
          [choice] = DeployExHelpers.prompt_for_choice(Enum.map(servers, fn {_, _, name} -> name end))
          {ip, ipv6, _} = Enum.find(servers, fn {_, _, name} -> name === choice end)
          {:ok, {ip, ipv6}}
        _ -> {:error, ErrorMessage.not_found("No jump servers found")}
      end
    end
  end

  def fetch_instance_groups(_project_name, opts \\ []) do
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    with {:ok, instances} <- fetch_instances_by_tag("Group", resource_group) do
      {:ok, instances
        |> Stream.map(fn instance_data ->
          tags = get_instance_tags(instance_data)

          instance_data
            |> Map.put("InstanceGroupTag", tags["InstanceGroup"])
            |> Map.put("NameTag", tags["Name"])
            |> Map.put("QaNodeTag", tags["QaNode"])
        end)
        |> Stream.reject(&is_nil(&1["InstanceGroupTag"]))
        |> Stream.filter(&(&1["instanceState"]["name"] === "running"))
        |> Enum.group_by(&(&1["InstanceGroupTag"]), &%{
          name: &1["NameTag"],
          ip: &1["ipAddress"],
          ipv6: &1["ipv6Address"],
          qa_node?: &1["QaNodeTag"] === "true"
        })}
    end
  end

  def find_instance_details(project_name, app_name, opts \\ []) do
    with {:ok, instance_groups} <- fetch_instance_groups(project_name, opts) do
      case Enum.find_value(instance_groups, fn {group, values} -> if group =~ app_name, do: values end) do
        nil ->
          {:error, ErrorMessage.not_found(
            "no app names found with #{app_name}",
            %{app_names: Map.keys(instance_groups)}
          )}

        instances ->
          instances =
            if opts[:exclude_qa_nodes] === true do
              Enum.reject(instances, & &1.qa_node?)
            else
              instances
            end

          {:ok, instances}
      end
    end
  end

  def find_instance_ips(project_name, app_name, opts \\ []) do
    case find_instance_details(project_name, app_name, opts) do
      {:ok, [%{ip: ip, ipv6: ipv6}]} -> {:ok, [ipv6 || ip]}

      {:ok, instances} -> {:ok, Enum.map(instances, &(&1[:ipv6] || &1[:ip]))}

      e -> e
    end
  end

  def find_qa_instance_ips(app_name \\ nil, opts \\ []) do
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    with {:ok, instances} <- fetch_instances_by_tag("Group", resource_group) do
      qa_ips = instances
      |> Enum.filter(&instance_running_or_pending?/1)
      |> Enum.filter(&qa_node?/1)
      |> maybe_filter_by_app_name(app_name)
      |> Enum.map(fn instance ->
        tags = get_instance_tags(instance)
        name = tags["Name"]
        ip = instance["ipv6Address"] || instance["ipAddress"]
        {name, ip}
      end)
      |> Enum.reject(fn {_, ip} -> is_nil(ip) end)

      {:ok, qa_ips}
    end
  end

  defp maybe_filter_by_app_name(instances, nil), do: instances
  defp maybe_filter_by_app_name(instances, app_name) do
    Enum.filter(instances, fn instance ->
      tags = get_instance_tags(instance)
      instance_group = tags["InstanceGroup"]
      instance_group && instance_group =~ app_name
    end)
  end

  defp qa_node?(instance) do
    tags = get_instance_tags(instance)
    tags["QaNode"] === "true"
  end

  def find_instances_by_tags(tag_filters, opts \\ []) when is_list(tag_filters) do
    region = opts[:region] || DeployEx.Config.aws_region()
    all_filters = tag_filters ++ resource_group_filter(opts)

    # Same G1 leak class as describe_instance/2: opts reaching here is often a caller's whole
    # task opts (--pem path, :provider, :quiet, ...), and fetch_instances/2 forwards anything
    # beyond :request_fn straight into ExAws.EC2.describe_instances/1 as real API query params.
    ec2_opts = Keyword.take(opts, [:request_fn])

    with {:ok, instances} <- fetch_instances(region, ec2_opts) do
      {:ok, filter_instances_by_tags(instances, all_filters)}
    end
  end

  def find_instances_needing_setup(tag_filters \\ [], opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    all_filters = tag_filters ++ resource_group_filter(opts)

    with {:ok, instances} <- fetch_instances_by_tag(region, "ManagedBy", "DeployEx") do
      incomplete = instances
      |> filter_instances_by_tags(all_filters)
      |> Enum.filter(&instance_running_or_pending?/1)
      |> Enum.reject(&setup_complete?/1)

      {:ok, incomplete}
    end
  end

  def find_instances_setup_complete(tag_filters \\ [], opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    all_filters = tag_filters ++ resource_group_filter(opts)

    with {:ok, instances} <- fetch_instances_by_tag(region, "ManagedBy", "DeployEx") do
      complete = instances
      |> filter_instances_by_tags(all_filters)
      |> Enum.filter(&instance_running_or_pending?/1)
      |> Enum.filter(&setup_complete?/1)

      {:ok, complete}
    end
  end

  @doc """
  Normalizes a raw AWS instance map into the provider-neutral struct.

  Distinct from `parse_instance_info/1` below, which produces the AWS-shaped map behind the
  frozen `mix deploy_ex.find_nodes --format json` key set. That one is a display projection
  whose keys are a user-visible contract; this one is the neutral behaviour type.
  """
  def to_instance(instance) do
    tags = get_instance_tags(instance)

    %DeployEx.Cloud.Instance{
      id: instance["instanceId"],
      type: instance["instanceType"],
      state: instance["instanceState"]["name"],
      private_ip: instance["privateIpAddress"],
      public_ip: instance["ipAddress"],
      ipv6: instance["ipv6Address"],
      launched_at: instance["launchTime"],
      name: tags["Name"],
      qa_node?: tags["QaNode"] === "true",
      tags: tags
    }
  end

  def parse_instance_info(instance) do
    tags = get_instance_tags(instance)

    %{
      instance_id: instance["instanceId"],
      instance_type: instance["instanceType"],
      state: instance["instanceState"]["name"],
      private_ip: instance["privateIpAddress"],
      public_ip: instance["ipAddress"],
      ipv6: instance["ipv6Address"],
      launch_time: instance["launchTime"],
      tags: tags,
      app_name: tags["InstanceGroup"],
      environment: tags["Environment"],
      setup_complete: tags["SetupComplete"] === "true"
    }
  end

  defp has_tag?(instance, tag_name, tag_value) do
    tags = get_instance_tags(instance)

    case tag_value do
      values when is_list(values) -> tags[tag_name] in values
      %Regex{} = regex -> tags[tag_name] && Regex.match?(regex, tags[tag_name])
      value -> tags[tag_name] === value
    end
  end

  defp setup_complete?(instance) do
    tags = get_instance_tags(instance)
    tags["SetupComplete"] === "true"
  end

  defp get_instance_tags(instance) do
    case instance["tagSet"] || instance[:tag_set] do
      %{"item" => items} when is_list(items) ->
        Map.new(items, fn %{"key" => k, "value" => v} -> {k, v} end)

      %{"item" => %{"key" => k, "value" => v}} ->
        %{k => v}

      tags when is_list(tags) ->
        Map.new(tags, fn tag ->
          {tag[:key] || tag["key"], tag[:value] || tag["value"]}
        end)

      _ ->
        %{}
    end
  end

  defp filter_instances_by_tags(instances, []), do: instances
  defp filter_instances_by_tags(instances, tag_filters) do
    Enum.filter(instances, fn instance ->
      Enum.all?(tag_filters, fn {tag_name, tag_value} ->
        has_tag?(instance, tag_name, tag_value)
      end)
    end)
  end

  defp resource_group_filter(opts) do
    if opts[:resource_group], do: [{"Group", opts[:resource_group]}], else: []
  end

  def fetch_instance_node_numbers(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    with {:ok, instances} <- fetch_instances_by_tag(region, "ManagedBy", "DeployEx") do
      filtered = filter_instances_by_tags(instances, resource_group_filter(opts))

      instance_nodes = filtered
      |> Enum.reject(&instance_terminated?/1)
      |> Enum.map(fn instance ->
        tags = get_instance_tags(instance)
        instance_group = tags["InstanceGroup"]
        name = tags["Name"]
        node_num = parse_node_number_from_name(name)
        {instance_group, node_num}
      end)
      |> Enum.reject(fn {group, _} -> is_nil(group) end)

      {:ok, instance_nodes}
    end
  end

  defp parse_node_number_from_name(nil), do: nil
  defp parse_node_number_from_name(name) do
    case Regex.run(~r/-(\d+)$/, name) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end
end
