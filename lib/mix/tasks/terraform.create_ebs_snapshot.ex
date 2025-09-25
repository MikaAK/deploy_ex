defmodule Mix.Tasks.Terraform.CreateEbsSnapshot do
  use Mix.Task

  alias DeployEx.{AwsMachine, Config}

  @shortdoc "Creates an EBS snapshot for a specified node"
  @moduledoc """
  Creates an EBS snapshot for a specified node by finding the node's instance
  and its associated EBS volumes, then creating snapshots.

  ## Usage

  ```bash
  mix terraform.create_ebs_snapshot <node_name>
  ```

  ## Arguments

  - `node_name` - The name of the node to create snapshots for

  ## Options

  - `--description` - Description for the snapshot (optional)
  - `--aws-region` - AWS region (default: from config)

  ## Examples

  ```bash
  mix terraform.create_ebs_snapshot web-server-1
  mix terraform.create_ebs_snapshot web-server-1 --description "Backup before deployment"
  ```
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, [node_name | _], _} = OptionParser.parse(args,
      switches: [
        description: :string,
        aws_region: :string
      ]
    )

    if is_nil(node_name) do
      Mix.raise("Node name is required. Usage: mix terraform.create_ebs_snapshot <node_name>")
    end

    region = opts[:aws_region] || Config.aws_region()
    description = opts[:description] || "EBS snapshot for #{node_name} - #{DateTime.utc_now()}"

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, instance} <- find_instance_by_name(region, node_name),
         {:ok, volumes} <- find_instance_volumes(region, instance["instanceId"]),
         {:ok, snapshots} <- create_snapshots_for_volumes(region, volumes, description) do
      
      Mix.shell().info([
        :green, "Successfully created ", :bright, "#{length(snapshots)}", :reset, :green,
        " snapshot(s) for node ", :bright, node_name, :reset, :green, ":"
      ])

      Enum.each(snapshots, fn snapshot ->
        Mix.shell().info([
          :green, "  - Snapshot ", :bright, snapshot["snapshotId"], :reset, :green,
          " for volume ", :bright, snapshot["volumeId"], :reset
        ])
      end)

      :ok
    else
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp find_instance_by_name(region, node_name) do
    with {:ok, instances} <- AwsMachine.fetch_instances(region) do
      case find_instance_with_name_tag(instances, node_name) do
        nil ->
          {:error, ErrorMessage.not_found(
            "No instance found with name '#{node_name}'",
            %{node_name: node_name, region: region}
          )}

        instance ->
          Mix.shell().info([
            :green, "Found instance ", :bright, instance["instanceId"], :reset, :green,
            " for node ", :bright, node_name, :reset
          ])
          {:ok, instance}
      end
    end
  end

  defp find_instance_with_name_tag(instances, node_name) do
    Enum.find(instances, fn instance ->
      case instance["tagSet"]["item"] do
        tags when is_list(tags) ->
          Enum.any?(tags, fn
            %{"key" => "Name", "value" => ^node_name} -> true
            _ -> false
          end)

        %{"key" => "Name", "value" => ^node_name} -> true
        _ -> false
      end
    end)
  end

  defp find_instance_volumes(region, instance_id) do
    filters = [
      %{name: "attachment.instance-id", values: [instance_id]}
    ]

    ExAws.EC2.describe_volumes(filters: filters)
      |> ExAws.request(region: region)
      |> case do
        {:ok, %{body: body}} ->
          case parse_volumes_response(body) do
            {:ok, []} ->
              {:error, ErrorMessage.not_found(
                "No volumes found for instance #{instance_id}",
                %{instance_id: instance_id}
              )}

            {:ok, volumes} ->
              Mix.shell().info([
                :green, "Found ", :bright, "#{length(volumes)}", :reset, :green,
                " volume(s) for instance ", :bright, instance_id, :reset
              ])
              {:ok, volumes}

            {:error, _} = error -> error
          end

        {:error, {:http_error, status_code, %{body: body}}} ->
          {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
            "Error fetching volumes from AWS",
            %{error_body: body, instance_id: instance_id}
          ])}

        {:error, error} ->
          {:error, ErrorMessage.bad_request(
            "Failed to describe volumes",
            %{error: error, instance_id: instance_id}
          )}
      end
  end

  defp parse_volumes_response(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeVolumesResponse" => %{"volumeSet" => %{"item" => volumes}}} when is_list(volumes) ->
        {:ok, volumes}

      %{"DescribeVolumesResponse" => %{"volumeSet" => %{"item" => volume}}} ->
        {:ok, [volume]}

      %{"DescribeVolumesResponse" => %{"volumeSet" => nil}} ->
        {:ok, []}

      structure ->
        {:error, ErrorMessage.bad_request(
          "Couldn't parse volumes response from AWS",
          %{structure: structure}
        )}
    end
  end

  defp create_snapshots_for_volumes(region, volumes, description) do
    volumes
      |> Task.async_stream(fn volume ->
        create_snapshot_for_volume(region, volume, description)
      end, max_concurrency: 4, timeout: :timer.seconds(30))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, snapshot}}, {:ok, acc} ->
          {:cont, {:ok, [snapshot | acc]}}

        {:ok, {:error, _} = error}, _acc ->
          {:halt, error}

        {:exit, reason}, _acc ->
          {:halt, {:error, ErrorMessage.failed_dependency(
            "Task failed while creating snapshot",
            %{reason: reason}
          )}}
      end)
      |> case do
        {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
        error -> error
      end
  end

  defp create_snapshot_for_volume(region, volume, description) do
    volume_id = volume["volumeId"]
    snapshot_description = "#{description} (Volume: #{volume_id})"

    Mix.shell().info([
      :green, "Creating snapshot for volume ", :bright, volume_id, :reset
    ])

    ExAws.EC2.create_snapshot(volume_id, description: snapshot_description)
      |> ExAws.request(region: region)
      |> case do
        {:ok, %{body: body}} ->
          case parse_snapshot_response(body) do
            {:ok, snapshot} ->
              Mix.shell().info([
                :green, "Snapshot ", :bright, snapshot["snapshotId"], :reset, :green,
                " created for volume ", :bright, volume_id, :reset
              ])
              {:ok, snapshot}

            {:error, _} = error -> error
          end

        {:error, {:http_error, status_code, %{body: body}}} ->
          {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
            "Error creating snapshot",
            %{error_body: body, volume_id: volume_id}
          ])}

        {:error, error} ->
          {:error, ErrorMessage.bad_request(
            "Failed to create snapshot",
            %{error: error, volume_id: volume_id}
          )}
      end
  end

  defp parse_snapshot_response(body) do
    case XmlToMap.naive_map(body) do
      %{"CreateSnapshotResponse" => snapshot} ->
        {:ok, snapshot}

      structure ->
        {:error, ErrorMessage.bad_request(
          "Couldn't parse snapshot response from AWS",
          %{structure: structure}
        )}
    end
  end
end
