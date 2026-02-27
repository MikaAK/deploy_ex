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
    region = opts[:region] || DeployEx.Config.aws_region()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()
    environment = opts[:environment] || DeployEx.Config.env()

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

    user_data = build_user_data()

    run_opts = [
      {"InstanceType", instance_type},
      {"KeyName", params[:key_name]},
      {"NetworkInterface.1.DeviceIndex", "0"},
      {"NetworkInterface.1.SubnetId", params[:subnet_id]},
      {"NetworkInterface.1.SecurityGroupId.1", params[:security_group_id]},
      {"NetworkInterface.1.AssociatePublicIpAddress", "true"},
      {"UserData", Base.encode64(user_data)},
      iam_instance_profile: [name: params[:iam_instance_profile]],
      tag_specifications: [{:instance, tags}]
    ]

    params[:ami_id]
    |> ExAws.EC2.run_instances(1, 1, run_opts)
    |> ExAws.request(region: region)
    |> handle_run_instances_response()
    |> case do
      {:ok, instance_id} ->
        runner = %__MODULE__{
          instance_id: instance_id,
          instance_name: instance_name,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {:ok, runner}

      error ->
        error
    end
  end

  def terminate_instance(instance_id, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    [instance_id]
    |> ExAws.EC2.terminate_instances()
    |> ExAws.request(region: region)
    |> handle_terminate_response()
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

  def find_runners_from_ec2(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    ExAws.EC2.describe_instances(filters: [
      "tag:K6Runner": ["true"],
      "tag:Group": [resource_group],
      "instance-state-name": ["running", "pending", "stopping", "stopped"]
    ])
    |> ExAws.request(region: region)
    |> handle_describe_instances()
  end

  def verify_instance_exists(nil), do: {:ok, nil}

  def verify_instance_exists(%__MODULE__{instance_id: instance_id} = runner) do
    case DeployEx.AwsMachine.find_instances_by_id([instance_id]) do
      {:ok, [instance]} ->
        updated = %{runner |
          public_ip: instance["ipAddress"],
          ipv6_address: instance["ipv6Address"],
          private_ip: instance["privateIpAddress"],
          state: instance["instanceState"]["name"]
        }

        {:ok, updated}

      {:error, %ErrorMessage{code: :not_found}} ->
        :ok = delete_state(runner, [])
        {:ok, nil}

      error ->
        error
    end
  end

  # S3 State Management

  def state_key(instance_id) do
    "#{@state_prefix}/#{instance_id}.json"
  end

  def save_state(%__MODULE__{instance_id: instance_id} = runner, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.put_object(state_key(instance_id), to_json(runner))
    |> ExAws.request(region: region)
    |> handle_put_response()
  end

  def fetch_state(instance_id, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.get_object(state_key(instance_id))
    |> ExAws.request(region: region)
    |> handle_get_response()
    |> case do
      {:ok, json} -> {:ok, from_json(json)}
      {:error, %ErrorMessage{code: :not_found}} -> {:ok, nil}
      error -> error
    end
  end

  def fetch_all_runners(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.list_objects(prefix: "#{@state_prefix}/")
    |> ExAws.request(region: region)
    |> case do
      {:ok, %{body: %{contents: contents}}} when is_list(contents) ->
        runners = Enum.map(contents, fn content ->
          case ExAws.S3.get_object(bucket, content.key) |> ExAws.request(region: region) do
            {:ok, %{body: body}} -> from_json(body)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

        {:ok, runners}

      {:ok, _} ->
        {:ok, []}

      {:error, error} ->
        {:error, ErrorMessage.failed_dependency("failed to list k6 runner states", %{error: error})}
    end
  end

  def delete_state(%__MODULE__{instance_id: instance_id}, opts) do
    delete_state(instance_id, opts)
  end

  def delete_state(instance_id, opts) when is_binary(instance_id) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.delete_object(state_key(instance_id))
    |> ExAws.request(region: region)
    |> handle_delete_response()
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

  defp build_user_data do
    """
    #!/bin/bash
    set -euo pipefail

    exec > >(tee /var/log/k6-setup.log | logger -t k6-setup -s 2>/dev/console) 2>&1

    echo "k6 Runner setup starting..."

    INSTANCE_ID=$(ec2-metadata --instance-id | cut -d " " -f 2)
    REGION=$(ec2-metadata --availability-zone | cut -d " " -f 2 | sed 's/[a-z]$//')

    hostnamectl set-hostname "$INSTANCE_ID"

    apt-get update -y
    apt-get install -y gnupg software-properties-common

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /etc/apt/keyrings/k6.gpg
    echo "deb [signed-by=/etc/apt/keyrings/k6.gpg] https://dl.k6.io/deb stable main" | tee /etc/apt/sources.list.d/k6.list

    apt-get update -y
    apt-get install -y k6

    mkdir -p /srv/k6/scripts

    aws ec2 create-tags --region "$REGION" --resources "$INSTANCE_ID" --tags Key=SetupComplete,Value=true

    echo "k6 Runner setup complete!"
    k6 version
    """
  end

  defp build_instance_name(environment) do
    timestamp = System.system_time(:second)
    "K6-Runner-#{environment}-#{timestamp}"
  end

  # AWS Response Handlers

  defp handle_run_instances_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"RunInstancesResponse" => %{"instancesSet" => %{"item" => %{"instanceId" => instance_id}}}} ->
        {:ok, instance_id}

      %{"RunInstancesResponse" => %{"instancesSet" => %{"item" => [%{"instanceId" => instance_id} | _]}}} ->
        {:ok, instance_id}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse run instances response from aws",
          %{structure: structure}
        )}
    end
  end

  defp handle_run_instances_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error creating k6 runner instance",
      %{error_body: body}
    ])}
  end

  defp handle_terminate_response({:ok, _}), do: :ok

  defp handle_terminate_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error terminating k6 runner instance",
      %{error_body: body}
    ])}
  end

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

  defp handle_get_response({:ok, %{body: body}}), do: {:ok, body}

  defp handle_get_response({:error, {:http_error, 404, _}}) do
    {:error, ErrorMessage.not_found("k6 runner state not found")}
  end

  defp handle_get_response({:error, {:http_error, status, reason}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["aws failure", %{reason: reason}])}
  end

  defp handle_get_response({:error, error}) when is_binary(error) do
    {:error, ErrorMessage.failed_dependency("aws failure: #{error}")}
  end

  defp handle_put_response({:ok, _}), do: {:ok, :saved}

  defp handle_put_response({:error, {:http_error, status, reason}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["aws failure", %{reason: reason}])}
  end

  defp handle_put_response({:error, error}) when is_binary(error) do
    {:error, ErrorMessage.failed_dependency("aws failure: #{error}")}
  end

  defp handle_put_response({:error, error}) do
    {:error, ErrorMessage.failed_dependency("aws failure", %{error: error})}
  end

  defp handle_delete_response({:ok, _}), do: :ok
  defp handle_delete_response({:error, {:http_error, 404, _}}), do: :ok

  defp handle_delete_response({:error, {:http_error, status, reason}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["aws failure", %{reason: reason}])}
  end

  defp handle_delete_response({:error, error}) when is_binary(error) do
    {:error, ErrorMessage.failed_dependency("aws failure: #{error}")}
  end
end
