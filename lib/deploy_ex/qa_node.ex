defmodule DeployEx.QaNode do
  @moduledoc """
  Core module for QA node state management and AWS operations.

  QA nodes are standalone EC2 instances that can be spun up with a specific
  git SHA release for testing purposes, independent of any Auto Scaling Group.

  State is stored in S3 at `qa-nodes/{app_name}/state.json` and is always
  read from S3 before any command executes.
  """

  @type t :: %__MODULE__{
    instance_id: String.t() | nil,
    app_name: String.t(),
    target_sha: String.t(),
    public_ip: String.t() | nil,
    ipv6_address: String.t() | nil,
    private_ip: String.t() | nil,
    instance_name: String.t() | nil,
    state: String.t() | nil,
    created_at: String.t() | nil,
    load_balancer_attached?: boolean(),
    target_group_arns: [String.t()]
  }

  defstruct [
    :instance_id,
    :app_name,
    :target_sha,
    :public_ip,
    :ipv6_address,
    :private_ip,
    :instance_name,
    :state,
    :created_at,
    load_balancer_attached?: false,
    target_group_arns: []
  ]

  @qa_state_prefix "qa-nodes"
  @default_instance_type "t3.small"

  def create_instance(app_name, target_sha, params, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()
    environment = opts[:environment] || DeployEx.Config.env()

    instance_name = build_instance_name(app_name, target_sha)
    instance_type = params[:instance_type] || @default_instance_type

    tags = [
      {:Name, instance_name},
      {:Group, resource_group},
      {:InstanceGroup, app_name},
      {:Environment, environment},
      {:ManagedBy, "DeployEx"},
      {:QaNode, "true"},
      {:TargetSha, target_sha},
      {:SetupComplete, "false"},
      {:Type, "Self Made"}
    ]

    run_opts = [
      instance_type: instance_type,
      key_name: params[:key_name],
      security_group_ids: [params[:security_group_id]],
      subnet_id: params[:subnet_id],
      iam_instance_profile: [name: params[:iam_instance_profile]],
      tag_specifications: [{"instance", tags}],
      ipv6_address_count: 1
    ]

    params[:ami_id]
    |> ExAws.EC2.run_instances(1, 1, run_opts)
    |> ExAws.request(region: region)
    |> handle_run_instances_response()
    |> case do
      {:ok, instance_id} ->
        qa_node = %__MODULE__{
          instance_id: instance_id,
          app_name: app_name,
          target_sha: target_sha,
          instance_name: instance_name,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          load_balancer_attached?: false,
          target_group_arns: []
        }
        {:ok, qa_node}

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

  def terminate_qa_node(%__MODULE__{} = qa_node, opts \\ []) do
    with :ok <- maybe_detach_from_load_balancer(qa_node, opts),
         :ok <- terminate_instance(qa_node.instance_id, opts),
         :ok <- delete_qa_state(qa_node.app_name, opts) do
      :ok
    end
  end

  defp maybe_detach_from_load_balancer(%__MODULE__{load_balancer_attached?: false}, _opts), do: :ok
  defp maybe_detach_from_load_balancer(%__MODULE__{} = qa_node, opts) do
    detach_from_load_balancer(qa_node, opts)
  end

  def attach_to_load_balancer(%__MODULE__{} = qa_node, target_group_arns, opts \\ []) when is_list(target_group_arns) do
    port = opts[:port] || 4000

    results = Enum.map(target_group_arns, fn arn ->
      DeployEx.AwsLoadBalancer.register_target(arn, qa_node.instance_id, port, opts)
    end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        updated_qa_node = %{qa_node |
          load_balancer_attached?: true,
          target_group_arns: target_group_arns
        }
        with {:ok, :saved} <- save_qa_state(qa_node.app_name, updated_qa_node, opts) do
          {:ok, updated_qa_node}
        end

      error ->
        error
    end
  end

  def detach_from_load_balancer(%__MODULE__{target_group_arns: []} = _qa_node, _opts), do: :ok
  def detach_from_load_balancer(%__MODULE__{} = qa_node, opts) do
    results = Enum.map(qa_node.target_group_arns, fn arn ->
      DeployEx.AwsLoadBalancer.deregister_target(arn, qa_node.instance_id, opts)
    end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        updated_qa_node = %{qa_node |
          load_balancer_attached?: false,
          target_group_arns: []
        }
        with {:ok, :saved} <- save_qa_state(qa_node.app_name, updated_qa_node, opts) do
          {:ok, updated_qa_node}
        end

      error ->
        error
    end
  end

  defp build_instance_name(app_name, target_sha) do
    short_sha = String.slice(target_sha, 0, 7)
    timestamp = System.system_time(:second)
    "#{app_name}-qa-#{short_sha}-#{timestamp}"
  end

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
      "error creating instance",
      %{error_body: body}
    ])}
  end

  defp handle_terminate_response({:ok, _}), do: :ok

  defp handle_terminate_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error terminating instance",
      %{error_body: body}
    ])}
  end

  def qa_state_key(app_name) do
    "#{@qa_state_prefix}/#{app_name}/state.json"
  end

  def fetch_qa_state(app_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.get_object(qa_state_key(app_name))
    |> ExAws.request(region: region)
    |> handle_get_response()
    |> case do
      {:ok, json} -> {:ok, from_json(json)}
      {:error, %ErrorMessage{code: :not_found}} -> {:ok, nil}
      error -> error
    end
  end

  def save_qa_state(app_name, %__MODULE__{} = state, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.put_object(qa_state_key(app_name), to_json(state))
    |> ExAws.request(region: region)
    |> handle_put_response()
  end

  def delete_qa_state(app_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.delete_object(qa_state_key(app_name))
    |> ExAws.request(region: region)
    |> handle_delete_response()
  end

  def list_all_qa_states(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.list_objects(prefix: @qa_state_prefix)
    |> ExAws.request(region: region)
    |> case do
      {:ok, %{body: %{contents: contents}}} when is_list(contents) ->
        app_names = contents
        |> Enum.map(&extract_app_name_from_key(&1.key))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

        {:ok, app_names}

      {:ok, %{body: %{contents: _}}} ->
        {:ok, []}

      {:error, error} ->
        {:error, ErrorMessage.failed_dependency("failed to list qa states", %{error: error})}
    end
  end

  defp extract_app_name_from_key(key) do
    case String.split(key, "/") do
      [@qa_state_prefix, app_name, "state.json"] -> app_name
      _ -> nil
    end
  end

  def to_json(%__MODULE__{} = state) do
    %{
      "version" => 1,
      "instance_id" => state.instance_id,
      "app_name" => state.app_name,
      "target_sha" => state.target_sha,
      "public_ip" => state.public_ip,
      "ipv6_address" => state.ipv6_address,
      "private_ip" => state.private_ip,
      "instance_name" => state.instance_name,
      "state" => state.state,
      "created_at" => state.created_at,
      "load_balancer_attached" => state.load_balancer_attached?,
      "target_group_arns" => state.target_group_arns
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
      app_name: map["app_name"],
      target_sha: map["target_sha"],
      public_ip: map["public_ip"],
      ipv6_address: map["ipv6_address"],
      private_ip: map["private_ip"],
      instance_name: map["instance_name"],
      state: map["state"],
      created_at: map["created_at"],
      load_balancer_attached?: map["load_balancer_attached"] || false,
      target_group_arns: map["target_group_arns"] || []
    }
  end

  def verify_instance_exists(nil), do: {:ok, nil}

  def verify_instance_exists(%__MODULE__{instance_id: instance_id, app_name: app_name} = state) do
    case DeployEx.AwsMachine.find_instances_by_id([instance_id]) do
      {:ok, [instance]} ->
        updated_state = %{state |
          public_ip: instance["ipAddress"],
          ipv6_address: instance["ipv6Address"],
          private_ip: instance["privateIpAddress"],
          state: instance["instanceState"]["name"]
        }
        {:ok, updated_state}

      {:error, %ErrorMessage{code: :not_found}} ->
        :ok = delete_qa_state(app_name)
        {:ok, nil}

      error ->
        error
    end
  end

  defp handle_get_response({:ok, %{body: body}}), do: {:ok, body}

  defp handle_get_response({:error, {:http_error, 404, _}}) do
    {:error, ErrorMessage.not_found("qa state not found")}
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

  defp handle_delete_response({:ok, _}), do: :ok

  defp handle_delete_response({:error, {:http_error, 404, _}}), do: :ok

  defp handle_delete_response({:error, {:http_error, status, reason}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["aws failure", %{reason: reason}])}
  end

  defp handle_delete_response({:error, error}) when is_binary(error) do
    {:error, ErrorMessage.failed_dependency("aws failure: #{error}")}
  end
end
