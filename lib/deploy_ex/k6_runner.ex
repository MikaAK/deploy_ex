defmodule DeployEx.K6Runner do
  @type t :: %__MODULE__{
    instance_id: String.t() | nil,
    public_ip: String.t() | nil,
    ipv6_address: String.t() | nil,
    private_ip: String.t() | nil,
    instance_name: String.t() | nil,
    state: String.t() | nil,
    created_at: String.t() | nil
  }

  defstruct [
    :instance_id,
    :public_ip,
    :ipv6_address,
    :private_ip,
    :instance_name,
    :state,
    :created_at
  ]

  @state_prefix "k6-runners"
  @default_instance_type "t3.small"

  def create_instance(params, opts \\ []) do
    environment = opts[:environment] || DeployEx.Config.env()

    with {:ok, resource_group} <- resolve_resource_group(opts) do
      instance_name = build_instance_name(environment)
      instance_type = params[:instance_type] || @default_instance_type

      tags = [
        {:Name, instance_name},
        {:Group, resource_group},
        {:Environment, environment},
        {:ManagedBy, "DeployEx"},
        {:K6Runner, "true"},
        {:Type, "Load Testing"}
      ]

      spec = %{
        name: instance_name,
        instance_type: instance_type,
        user_data: build_user_data(opts),
        tags: tags,
        network: %{
          key_name: params[:key_name],
          subnet_id: params[:subnet_id],
          security_group_id: params[:security_group_id],
          ami_id: params[:ami_id],
          iam_instance_profile: params[:iam_instance_profile]
        }
      }

      with {:ok, machine} <- DeployEx.Cloud.capability(:machine, opts),
           {:ok, instance} <- machine.run_instance(spec, opts) do
        {:ok,
         %__MODULE__{
           instance_id: instance.id,
           instance_name: instance_name,
           created_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}
      end
    end
  end

  def terminate_instance(instance_id, opts \\ []) do
    with {:ok, machine} <- DeployEx.Cloud.capability(:machine, opts) do
      machine.terminate_instance(instance_id, opts)
    end
  end

  # An explicit opts override always wins and skips the Cloud lookup entirely — a caller who
  # already knows the bucket/resource-group should never trip an "unset config" error for a
  # provider that has not configured the key.
  defp resolve_resource_group(opts) do
    case opts[:resource_group] do
      nil -> DeployEx.Cloud.resource_group(opts)
      resource_group -> {:ok, resource_group}
    end
  end

  defp resolve_bucket(opts) do
    case opts[:bucket] do
      nil -> DeployEx.Cloud.release_bucket(opts)
      bucket -> {:ok, bucket}
    end
  end

  def terminate_runner(%__MODULE__{} = runner, opts \\ []) do
    with :ok <- terminate_instance(runner.instance_id, opts),
         :ok <- delete_state(runner, opts) do
      :ok
    end
  end

  def find_or_create_runner(params, opts \\ []) do
    case fetch_all_runners(opts) do
      {:ok, [runner | _]} ->
        case verify_instance_exists(runner) do
          {:ok, verified} when not is_nil(verified) -> {:ok, verified}
          _ -> do_create_runner(params, opts)
        end

      {:ok, []} ->
        do_create_runner(params, opts)

      {:error, _} ->
        do_create_runner(params, opts)
    end
  end

  defp do_create_runner(params, opts) do
    with {:ok, runner} <- create_instance(params, opts),
         {:ok, :saved} <- save_state(runner, opts) do
      {:ok, runner}
    end
  end

  @doc """
  Every K6Runner-tagged instance in the region, following pagination to completion.

  DescribeInstances caps a response and signals more via `nextToken`. A single request
  therefore truncates silently on a large fleet — it returns `{:ok, partial}`, not an error —
  which would make `load_test.destroy_instance` miss instances and leave them running (and
  billing).
  """
  def find_runners_from_ec2(opts \\ []) do
    case DeployEx.Cloud.active_provider(opts) do
      :aws ->
        region = opts[:region] || DeployEx.Config.aws_region()
        resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

        find_runners_from_ec2_page(region, resource_group, opts, nil, [])

      provider ->
        # AWS-only EC2 DescribeInstances fallback path (see the moduledoc above and the
        # module doc note at the top of this section) — deliberately NOT routed through
        # Cloud.capability(:machine) this sprint (docs/superpowers/plans/lt-oci/spec.md § S2
        # adds the OCI-native runner-listing path). Erroring here instead of running the EC2
        # query under a non-AWS provider stops list/destroy_instance from printing another
        # provider's leftover AWS runners as if they belonged to the active one.
        {:error,
         ErrorMessage.not_implemented(
           "find_runners_from_ec2 is AWS-only (EC2 DescribeInstances) — not available for #{inspect(provider)}",
           %{provider: provider}
         )}
    end
  end

  defp find_runners_from_ec2_page(region, resource_group, opts, next_token, acc) do
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    filters = [
      "tag:K6Runner": ["true"],
      "tag:Group": [resource_group],
      "instance-state-name": ["running", "pending", "stopping", "stopped"]
    ]

    describe_opts = if next_token, do: [filters: filters, next_token: next_token], else: [filters: filters]

    response =
      describe_opts
      |> ExAws.EC2.describe_instances()
      |> request_fn.(region: region)

    with {:ok, runners} <- handle_describe_instances(response) do
      accumulated = acc ++ runners

      case describe_instances_next_token(response) do
        nil -> {:ok, accumulated}
        token -> find_runners_from_ec2_page(region, resource_group, opts, token, accumulated)
      end
    end
  end

  defp describe_instances_next_token({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeInstancesResponse" => %{"nextToken" => token}} when is_binary(token) and token !== "" -> token
      _no_more_pages -> nil
    end
  end

  defp describe_instances_next_token(_response), do: nil

  def verify_instance_exists(runner, opts \\ [])

  def verify_instance_exists(nil, _opts), do: {:ok, nil}

  def verify_instance_exists(%__MODULE__{instance_id: instance_id} = runner, opts) do
    with {:ok, machine} <- DeployEx.Cloud.capability(:machine, opts) do
      case machine.describe_instance(instance_id, opts) do
        {:ok, instance} ->
          updated = %{runner |
            public_ip: instance.public_ip,
            ipv6_address: instance.ipv6,
            private_ip: instance.private_ip,
            state: instance.state
          }

          {:ok, updated}

        {:error, %ErrorMessage{code: :not_found}} ->
          with :ok <- delete_state(runner, opts) do
            {:ok, nil}
          end

        error ->
          error
      end
    end
  end

  # Runner Resolution (shared by upload/exec/create_instance — extracted so
  # nil-runner handling has one implementation instead of drifting copies)

  @doc false
  def resolve_runner(opts, k6_runner_impl \\ __MODULE__) do
    case opts[:instance_id] do
      nil -> resolve_default_runner(opts, k6_runner_impl)
      instance_id -> resolve_runner_by_instance_id(instance_id, opts, k6_runner_impl)
    end
  end

  defp resolve_default_runner(opts, k6_runner_impl) do
    case k6_runner_impl.fetch_all_runners(opts) do
      {:ok, [runner | _]} -> verify_resolved_runner(runner, k6_runner_impl)
      {:ok, empty} when empty in [nil, []] -> {:error, no_runner_error()}
      error -> error
    end
  end

  defp resolve_runner_by_instance_id(instance_id, opts, k6_runner_impl) do
    case k6_runner_impl.fetch_state(instance_id, opts) do
      {:ok, nil} -> {:error, no_runner_error()}
      {:ok, runner} -> verify_resolved_runner(runner, k6_runner_impl)
      error -> error
    end
  end

  defp verify_resolved_runner(runner, k6_runner_impl) do
    case k6_runner_impl.verify_instance_exists(runner) do
      {:ok, nil} -> {:error, no_runner_error()}
      {:ok, verified} -> {:ok, verified}
      error -> error
    end
  end

  defp no_runner_error do
    ErrorMessage.not_found(
      "no active k6 runner found (missing or terminated) — create one with: mix deploy_ex.load_test.create_instance"
    )
  end

  # S3 State Management

  def state_key(instance_id) do
    "#{@state_prefix}/#{instance_id}.json"
  end

  def save_state(%__MODULE__{instance_id: instance_id} = runner, opts \\ []) do
    with {:ok, bucket} <- resolve_bucket(opts),
         {:ok, object_store} <- DeployEx.Cloud.capability(:object_store, opts),
         :ok <- object_store.put_object(bucket, state_key(instance_id), to_json(runner), opts) do
      {:ok, :saved}
    end
  end

  def fetch_state(instance_id, opts \\ []) do
    with {:ok, bucket} <- resolve_bucket(opts),
         {:ok, object_store} <- DeployEx.Cloud.capability(:object_store, opts) do
      case object_store.get_object(bucket, state_key(instance_id), opts) do
        {:ok, json} -> {:ok, from_json(json)}
        {:error, %ErrorMessage{code: :not_found}} -> {:ok, nil}
        error -> error
      end
    end
  end

  @doc """
  Every stored runner state under `#{@state_prefix}/`, following pagination to completion.

  S3 caps a ListObjects response at 1000 keys and signals more via `is_truncated`. A single
  request therefore truncates silently — `{:ok, partial}`, not an error — which would make
  every caller here (list/exec/destroy_instance/upload/create_instance) see a partial runner
  list.
  """
  def fetch_all_runners(opts \\ []) do
    list_opts = Keyword.put(opts, :prefix, "#{@state_prefix}/")

    with {:ok, bucket} <- resolve_bucket(opts),
         {:ok, object_store} <- DeployEx.Cloud.capability(:object_store, opts),
         {:ok, keys} <- object_store.list_objects(bucket, list_opts) do
      runners =
        keys
        |> Enum.map(&fetch_runner_state(object_store, bucket, &1, opts))
        |> Enum.reject(&is_nil/1)

      {:ok, runners}
    end
  end

  defp fetch_runner_state(object_store, bucket, key, opts) do
    case object_store.get_object(bucket, key, opts) do
      {:ok, body} -> from_json(body)
      _error -> nil
    end
  end

  def delete_state(%__MODULE__{instance_id: instance_id}, opts) do
    delete_state(instance_id, opts)
  end

  def delete_state(instance_id, opts) when is_binary(instance_id) do
    with {:ok, bucket} <- resolve_bucket(opts),
         {:ok, object_store} <- DeployEx.Cloud.capability(:object_store, opts) do
      case object_store.delete_object(bucket, state_key(instance_id), opts) do
        :ok -> :ok
        {:error, %ErrorMessage{code: :not_found}} -> :ok
        error -> error
      end
    end
  end

  # Serialization

  def to_json(%__MODULE__{} = runner) do
    %{
      "version" => 1,
      "instance_id" => runner.instance_id,
      "public_ip" => runner.public_ip,
      "ipv6_address" => runner.ipv6_address,
      "private_ip" => runner.private_ip,
      "instance_name" => runner.instance_name,
      "state" => runner.state,
      "created_at" => runner.created_at
    }
    |> Jason.encode!()
  end

  def from_json(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> from_json()
  end

  def from_json(%{} = map) do
    %__MODULE__{
      instance_id: map["instance_id"],
      public_ip: map["public_ip"],
      ipv6_address: map["ipv6_address"],
      private_ip: map["private_ip"],
      instance_name: map["instance_name"],
      state: map["state"],
      created_at: map["created_at"]
    }
  end

  # User Data

  @doc false
  def build_user_data(opts \\ []) do
    ssh_user = DeployEx.Cloud.ssh_user(opts)

    """
    #!/bin/bash
    set -euo pipefail

    exec > >(tee /var/log/k6-setup.log) 2>&1

    echo "k6 Runner setup starting..."

    apt-get update -y -o DPkg::Lock::Timeout=300
    apt-get install -y -o DPkg::Lock::Timeout=300 curl gnupg ca-certificates

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /etc/apt/keyrings/k6.gpg
    echo "deb [signed-by=/etc/apt/keyrings/k6.gpg] https://dl.k6.io/deb stable main" | tee /etc/apt/sources.list.d/k6.list

    apt-get update -y -o DPkg::Lock::Timeout=300
    apt-get install -y -o DPkg::Lock::Timeout=300 k6

    mkdir -p /srv/k6/scripts
    chown -R #{ssh_user}:#{ssh_user} /srv/k6

    echo "k6 Runner setup complete!"
    k6 version
    """
  end

  defp build_instance_name(environment) do
    timestamp = System.system_time(:second)
    "K6-Runner-#{environment}-#{timestamp}"
  end

  # AWS Response Handlers (find_runners_from_ec2 stays a direct AWS EC2 pagination path —
  # LT-OCI S1 keeps this pagination intact rather than routing it through Cloud.capability)

  defp handle_describe_instances({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeInstancesResponse" => %{"reservationSet" => %{"item" => reservations}}} ->
        {:ok, extract_runners(reservations)}

      %{"DescribeInstancesResponse" => %{"reservationSet" => nil}} ->
        {:ok, []}

      _ ->
        {:ok, []}
    end
  end

  defp handle_describe_instances({:error, {:http_error, status, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), [
      "error fetching k6 runner instances",
      %{body: body}
    ])}
  end

  defp extract_runners(reservations) when is_list(reservations) do
    Enum.flat_map(reservations, fn reservation ->
      case reservation["instancesSet"]["item"] do
        items when is_list(items) -> Enum.map(items, &build_runner_from_instance/1)
        item when is_map(item) -> [build_runner_from_instance(item)]
        _ -> []
      end
    end)
  end

  defp extract_runners(reservation) when is_map(reservation) do
    extract_runners([reservation])
  end

  defp extract_runners(_), do: []

  defp build_runner_from_instance(instance) do
    tags = parse_instance_tags(instance["tagSet"])

    %__MODULE__{
      instance_id: instance["instanceId"],
      public_ip: instance["ipAddress"],
      ipv6_address: instance["ipv6Address"],
      private_ip: instance["privateIpAddress"],
      instance_name: tags["Name"],
      state: get_in(instance, ["instanceState", "name"]),
      created_at: instance["launchTime"]
    }
  end

  defp parse_instance_tags(%{"item" => items}) when is_list(items) do
    Map.new(items, fn %{"key" => key, "value" => value} -> {key, value} end)
  end

  defp parse_instance_tags(%{"item" => item}) when is_map(item) do
    %{item["key"] => item["value"]}
  end

  defp parse_instance_tags(_), do: %{}
end
