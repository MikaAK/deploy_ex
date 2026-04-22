defmodule DeployEx.QaNode do
  @moduledoc """
  Core module for QA node state management and AWS operations.

  QA nodes are standalone EC2 instances that can be spun up with a specific
  git SHA release for testing purposes, independent of any Auto Scaling Group.

  State is stored in S3 at `qa-nodes/{app_name}/{instance_id}.json` and is always
  read from S3 before any command executes. Multiple QA nodes per app are supported.
  """

  @type t :: %__MODULE__{
    instance_id: String.t() | nil,
    app_name: String.t(),
    target_sha: String.t(),
    instance_tag: String.t() | nil,
    git_branch: String.t() | nil,
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
    :instance_tag,
    :git_branch,
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

    instance_tag = params[:instance_tag]
    git_branch = params[:git_branch]
    name_opts = Keyword.put(opts, :instance_tag, instance_tag)
    instance_name = build_instance_name(app_name, target_sha, environment, name_opts)
    instance_type = params[:instance_type] || @default_instance_type

    base_tags = [
      {:Name, instance_name},
      {:Group, resource_group},
      {:InstanceGroup, "#{app_name}_#{environment}"},
      {:Environment, environment},
      {:ManagedBy, "DeployEx"},
      {:QaNode, "true"},
      {:TargetSha, target_sha},
      {:SetupComplete, "false"},
      {:Type, "Self Made"}
    ]

    tags = base_tags
      |> maybe_append_tag({:InstanceTag, instance_tag})
      |> maybe_append_tag({:GitBranch, git_branch})

    user_data = build_qa_user_data(app_name, target_sha, environment)

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
        qa_node = %__MODULE__{
          instance_id: instance_id,
          app_name: app_name,
          target_sha: target_sha,
          instance_tag: instance_tag,
          git_branch: git_branch,
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

  @doc """
  Interactive picker over a list of QaNode structs.

  - 0 nodes → `{:ok, []}`
  - 1 node  → `{:ok, [node]}` (no prompt)
  - 2+ nodes → uses `DeployEx.TUI.Select` (TUI + console fallback) to let the user
    pick one or all. Returns `{:ok, [picked]}`. Empty list means user cancelled.

  Options: `:title` (default `"Select QA node"`), `:allow_all` (default `true`).
  """
  @spec pick_interactive([t()], keyword()) :: {:ok, [t()]}
  def pick_interactive(nodes, opts \\ [])
  def pick_interactive([], _opts), do: {:ok, []}
  def pick_interactive([_] = nodes, _opts), do: {:ok, nodes}

  def pick_interactive(nodes, opts) when is_list(nodes) do
    labels = Enum.map(nodes, &format_picker_label/1)
    label_to_node = labels |> Enum.zip(nodes) |> Map.new()

    selected = DeployEx.TUI.Select.run(labels,
      title: Keyword.get(opts, :title, "Select QA node"),
      allow_all: Keyword.get(opts, :allow_all, true)
    )

    picked = Enum.map(selected, &Map.fetch!(label_to_node, &1))
    {:ok, picked}
  end

  @doc false
  @spec format_picker_label(t()) :: String.t()
  def format_picker_label(%__MODULE__{} = node) do
    short_sha = node.target_sha |> to_string() |> String.slice(0, 7)
    branch = node.git_branch || "—"
    tag_suffix = if node.instance_tag, do: " [#{node.instance_tag}]", else: ""
    display = node.instance_name || node.app_name

    "#{display}#{tag_suffix} (#{node.instance_id}, SHA: #{short_sha}, branch: #{branch})"
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
         :ok <- delete_qa_state(qa_node, opts) do
      :ok
    end
  end

  defp maybe_append_tag(tags, {_key, value}) when is_nil(value) or value === "", do: tags
  defp maybe_append_tag(tags, {key, value}), do: tags ++ [{key, value}]

  defp maybe_detach_from_load_balancer(%__MODULE__{load_balancer_attached?: false}, _opts), do: :ok
  defp maybe_detach_from_load_balancer(%__MODULE__{} = qa_node, opts) do
    detach_from_load_balancer(qa_node, opts)
  end

  def attach_to_load_balancer(%__MODULE__{} = qa_node, target_groups, opts \\ []) when is_list(target_groups) do
    override_port = opts[:port]

    results = Enum.map(target_groups, fn tg ->
      {arn, port} = target_group_arn_and_port(tg, override_port)
      DeployEx.AwsLoadBalancer.register_target(arn, qa_node.instance_id, port, opts)
    end)

    target_group_arns = Enum.map(target_groups, fn
      %{arn: arn} -> arn
      arn when is_binary(arn) -> arn
    end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        updated_qa_node = %{qa_node |
          load_balancer_attached?: true,
          target_group_arns: target_group_arns
        }
        with {:ok, :saved} <- save_qa_state(updated_qa_node, opts) do
          {:ok, updated_qa_node}
        end

      error ->
        error
    end
  end

  def detach_from_load_balancer(%__MODULE__{target_group_arns: []} = _qa_node, _opts), do: :ok
  def detach_from_load_balancer(%__MODULE__{} = qa_node, opts) do
    results = Enum.flat_map(qa_node.target_group_arns, fn arn ->
      case DeployEx.AwsLoadBalancer.describe_target_health(arn, opts) do
        {:ok, targets} ->
          targets
            |> Enum.filter(&(&1.id === qa_node.instance_id))
            |> Enum.map(fn target ->
              DeployEx.AwsLoadBalancer.deregister_target(arn, qa_node.instance_id, target.port, opts)
            end)

        {:error, _} = error -> [error]
      end
    end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        updated_qa_node = %{qa_node |
          load_balancer_attached?: false,
          target_group_arns: []
        }
        with {:ok, :saved} <- save_qa_state(updated_qa_node, opts) do
          {:ok, updated_qa_node}
        end

      error ->
        error
    end
  end

  defp target_group_arn_and_port(%{arn: arn, port: port}, _override_port) when is_integer(port), do: {arn, port}
  defp target_group_arn_and_port(%{arn: arn}, override_port) when is_integer(override_port), do: {arn, override_port}
  defp target_group_arn_and_port(%{arn: arn}, _override_port), do: {arn, 443}
  defp target_group_arn_and_port(arn, override_port) when is_binary(arn) and is_integer(override_port), do: {arn, override_port}
  defp target_group_arn_and_port(arn, _override_port) when is_binary(arn), do: {arn, 443}

  defp build_instance_name(app_name, target_sha, environment, opts) do
    {:ok, display_name} = DeployEx.TerraformState.get_app_display_name(app_name, opts)

    timestamp = System.system_time(:second)
    slug = instance_name_slug(target_sha, opts[:instance_tag])
    "#{display_name}-#{environment}-qa-#{slug}-#{timestamp}"
  end

  defp instance_name_slug(target_sha, raw_tag) do
    case sanitize_tag(raw_tag) do
      tag when is_binary(tag) and tag !== "" -> tag
      _ -> String.slice(target_sha, 0, 7)
    end
  end

  @doc false
  def sanitize_tag(nil), do: nil

  def sanitize_tag(tag) when is_binary(tag) do
    tag
    |> String.downcase()
    |> String.replace(~r/[ _]/, "-")
    |> String.replace(~r/[^a-z0-9-]/, "")
  end

  defp build_qa_user_data(app_name, target_sha, environment) do
    bucket_name = "#{app_name}-elixir-deploys-#{environment}"

    """
    #!/bin/bash
    set -euo pipefail

    exec > >(tee /var/log/qa-deploy.log | logger -t qa-deploy -s 2>/dev/console) 2>&1

    APP_NAME="#{app_name}"
    TARGET_SHA="#{target_sha}"
    BUCKET_NAME="#{bucket_name}"

    echo "QA Node auto-deploy starting for $APP_NAME"

    # Get instance ID and region for tag lookup
    INSTANCE_ID=$(ec2-metadata --instance-id | cut -d " " -f 2)
    REGION=$(ec2-metadata --availability-zone | cut -d " " -f 2 | sed 's/[a-z]$//')

    # Set hostname to instance ID
    echo "Setting hostname to $INSTANCE_ID"
    hostnamectl set-hostname "$INSTANCE_ID"

    # Try to use provided SHA first, otherwise check TargetSha tag
    if [ -z "$TARGET_SHA" ] || [ "$TARGET_SHA" = "" ]; then
      echo "No SHA provided, checking TargetSha tag..."
      TARGET_SHA=$(aws ec2 describe-tags --region "$REGION" \
        --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=TargetSha" \
        --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
    fi

    if [ -z "$TARGET_SHA" ] || [ "$TARGET_SHA" = "None" ]; then
      echo "ERROR: No target SHA found (not provided and no TargetSha tag)"
      exit 1
    fi

    echo "Using SHA: $TARGET_SHA"

    # Find release matching the target SHA
    RELEASE=$(aws s3 ls "s3://$BUCKET_NAME/$APP_NAME" --recursive | grep "$TARGET_SHA" | awk '{print $4}' | head -n 1)

    if [ -z "$RELEASE" ]; then
      echo "ERROR: No release found matching SHA $TARGET_SHA"
      exit 1
    fi

    echo "Found release: $RELEASE"

    # Create directories
    mkdir -p /srv/$APP_NAME
    mkdir -p /srv/unpack-directory

    # Download release
    echo "Downloading release from S3..."
    aws s3 cp "s3://$BUCKET_NAME/$RELEASE" "/srv/${RELEASE##*/}"

    # Extract release
    echo "Extracting release..."
    tar -xzf "/srv/${RELEASE##*/}" -C /srv/unpack-directory

    # Stop existing service if running
    if systemctl is-active --quiet $APP_NAME; then
      echo "Stopping existing $APP_NAME service..."
      systemctl stop $APP_NAME || true
    fi

    # Replace app directory
    rm -rf /srv/$APP_NAME
    mv /srv/unpack-directory /srv/$APP_NAME
    chmod -R 755 /srv/$APP_NAME

    # Start service
    echo "Starting $APP_NAME service..."
    systemctl daemon-reload
    systemctl start $APP_NAME

    echo "QA Node deployment complete!"
    systemctl status $APP_NAME --no-pager || true
    """
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

  def qa_state_key(app_name, instance_id) do
    "#{@qa_state_prefix}/#{app_name}/#{instance_id}.json"
  end

  def fetch_qa_state(app_name, opts) when is_list(opts) do
    case fetch_all_qa_states_for_app(app_name, opts) do
      {:ok, [state | _]} -> {:ok, state}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  def fetch_qa_state(app_name, instance_id, opts \\ []) when is_binary(instance_id) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.get_object(qa_state_key(app_name, instance_id))
    |> ExAws.request(region: region)
    |> handle_get_response()
    |> case do
      {:ok, json} -> {:ok, from_json(json)}
      {:error, %ErrorMessage{code: :not_found}} -> {:ok, nil}
      error -> error
    end
  end

  def fetch_all_qa_states_for_app(app_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()
    prefix = "#{@qa_state_prefix}/#{app_name}/"

    bucket
    |> ExAws.S3.list_objects(prefix: prefix)
    |> ExAws.request(region: region)
    |> case do
      {:ok, %{body: %{contents: contents}}} when is_list(contents) ->
        states = Enum.map(contents, fn content ->
          case ExAws.S3.get_object(bucket, content.key) |> ExAws.request(region: region) do
            {:ok, %{body: body}} -> from_json(body)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

        {:ok, states}

      {:ok, _} ->
        {:ok, []}

      {:error, error} ->
        {:error, ErrorMessage.failed_dependency("failed to list qa states", %{error: error})}
    end
  end

  def find_qa_nodes_for_app(app_name, opts \\ []) do
    case fetch_all_qa_states_for_app(app_name, opts) do
      {:ok, []} -> find_qa_nodes_from_ec2(app_name, opts)
      result -> result
    end
  end

  def find_qa_node_from_ec2(app_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    environment = opts[:environment] || DeployEx.Config.env()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    ExAws.EC2.describe_instances(filters: [
      "tag:QaNode": ["true"],
      "tag:Group": [resource_group],
      "tag:InstanceGroup": ["#{app_name}_#{environment}"],
      "instance-state-name": ["running", "pending", "stopping", "stopped"]
    ])
    |> ExAws.request(region: region)
    |> handle_describe_instances_for_qa()
  end

  def find_qa_nodes_from_ec2(app_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    environment = opts[:environment] || DeployEx.Config.env()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    ExAws.EC2.describe_instances(filters: [
      "tag:QaNode": ["true"],
      "tag:Group": [resource_group],
      "tag:InstanceGroup": ["#{app_name}_#{environment}"],
      "instance-state-name": ["running", "pending", "stopping", "stopped"]
    ])
    |> ExAws.request(region: region)
    |> handle_describe_instances_for_qa_list()
  end

  defp handle_describe_instances_for_qa({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeInstancesResponse" => %{"reservationSet" => %{"item" => reservations}}} ->
        instances = extract_qa_instances(reservations)
        case instances do
          [instance | _] -> {:ok, instance}
          [] -> {:ok, nil}
        end

      %{"DescribeInstancesResponse" => %{"reservationSet" => nil}} ->
        {:ok, nil}

      _ ->
        {:ok, nil}
    end
  end

  defp handle_describe_instances_for_qa_list({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeInstancesResponse" => %{"reservationSet" => %{"item" => reservations}}} ->
        {:ok, extract_qa_instances(reservations)}

      %{"DescribeInstancesResponse" => %{"reservationSet" => nil}} ->
        {:ok, []}

      _ ->
        {:ok, []}
    end
  end

  defp handle_describe_instances_for_qa_list({:error, {:http_error, status, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["error fetching QA instances", %{body: body}])}
  end

  defp extract_qa_instances(reservations) when is_list(reservations) do
    Enum.flat_map(reservations, fn reservation ->
      case reservation["instancesSet"]["item"] do
        items when is_list(items) -> Enum.map(items, &build_qa_node_from_instance/1)
        item when is_map(item) -> [build_qa_node_from_instance(item)]
        _ -> []
      end
    end)
  end

  defp extract_qa_instances(reservation) when is_map(reservation) do
    extract_qa_instances([reservation])
  end

  defp extract_qa_instances(_), do: []

  def build_qa_node_from_instance(instance) do
    tags = parse_instance_tags(instance["tagSet"])

    %__MODULE__{
      instance_id: instance["instanceId"],
      app_name: tags["InstanceGroup"] |> String.split("_") |> List.first(),
      target_sha: tags["TargetSha"],
      instance_tag: tags["InstanceTag"],
      git_branch: tags["GitBranch"],
      public_ip: instance["ipAddress"],
      private_ip: instance["privateIpAddress"],
      instance_name: tags["Name"],
      state: get_in(instance, ["instanceState", "name"]),
      created_at: instance["launchTime"],
      load_balancer_attached?: false,
      target_group_arns: []
    }
  end

  defp parse_instance_tags(%{"item" => items}) when is_list(items) do
    Map.new(items, fn %{"key" => key, "value" => value} -> {key, value} end)
  end

  defp parse_instance_tags(%{"item" => item}) when is_map(item) do
    %{item["key"] => item["value"]}
  end

  defp parse_instance_tags(_), do: %{}

  def save_qa_state(%__MODULE__{app_name: app_name, instance_id: instance_id} = state, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.put_object(qa_state_key(app_name, instance_id), to_json(state))
    |> ExAws.request(region: region)
    |> handle_put_response()
  end

  def delete_qa_state(%__MODULE__{app_name: app_name, instance_id: instance_id}, opts) do
    delete_qa_state(app_name, instance_id, opts)
  end

  def delete_qa_state(app_name, instance_id, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.delete_object(qa_state_key(app_name, instance_id))
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
      [@qa_state_prefix, app_name, filename] when is_binary(filename) ->
        if String.ends_with?(filename, ".json"), do: app_name, else: nil
      _ -> nil
    end
  end

  def to_json(%__MODULE__{} = state) do
    %{
      "version" => 1,
      "instance_id" => state.instance_id,
      "app_name" => state.app_name,
      "target_sha" => state.target_sha,
      "instance_tag" => state.instance_tag,
      "git_branch" => state.git_branch,
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
      instance_tag: map["instance_tag"],
      git_branch: map["git_branch"],
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

  def verify_instance_exists(%__MODULE__{instance_id: instance_id} = state) do
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
        :ok = delete_qa_state(state, [])
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
