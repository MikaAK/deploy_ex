defmodule Mix.Tasks.Terraform.CreateEbsSnapshot do
  use Mix.Task

  alias DeployEx.{AwsMachine, Config}

  @shortdoc "Creates an EBS snapshot for a specified app"
  @moduledoc """
  Creates an EBS snapshot for a specified app by finding the app's instances
  and their associated EBS volumes, then creating snapshots.

  ## Usage

  ```bash
  mix terraform.create_ebs_snapshot <app_name>
  ```

  ## Arguments

  - `app_name` - The name of the app to create snapshots for

  ## Options

  - `--description` - Description for the snapshot (optional)
  - `--aws-region` - AWS region (default: from config)
  - `--resource_group` - Specify the resource group to target
  - `--include-root` - Include root filesystem volumes in snapshots (default: false)

  ## Examples

  ```bash
  # Create snapshots for data volumes only (default)
  mix terraform.create_ebs_snapshot my_app

  # Include root filesystem volumes as well
  mix terraform.create_ebs_snapshot my_app --include-root

  # With custom description
  mix terraform.create_ebs_snapshot my_app --description "Backup before deployment"

  # With specific resource group
  mix terraform.create_ebs_snapshot my_app --resource_group "My Backend"
  ```
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, app_params, _} = OptionParser.parse(args,
      switches: [
        description: :string,
        aws_region: :string,
        resource_group: :string,
        include_root: :boolean
      ]
    )

    region = opts[:aws_region] || Config.aws_region()
    {machine_opts, opts} = Keyword.split(opts, [:resource_group])

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, app_name} <- DeployExHelpers.find_project_name(app_params),
         {:ok, instance_ips} <- AwsMachine.find_instance_ips(DeployExHelpers.project_name(), app_name, machine_opts),
         {:ok, instances} <- find_instances_by_ips(region, instance_ips),
         {:ok, all_volumes} <- find_volumes_for_instances(region, instances),
         {:ok, filtered_volumes} <- filter_volumes_by_type(all_volumes, opts),
         {:ok, snapshots} <- create_snapshots_for_volumes(region, filtered_volumes, app_name, opts) do

      Mix.shell().info([
        :green, "Successfully created ", :bright, "#{length(snapshots)}", :reset, :green,
        " snapshot(s) for app ", :bright, app_name, :reset, :green, ":"
      ])

      Enum.each(snapshots, fn snapshot ->
        device_info = if snapshot["device"], do: " (#{snapshot["device"]})", else: ""
        volume_type_info = if snapshot["volume_type"], do: " - #{snapshot["volume_type"]}", else: ""

        Mix.shell().info([
          :green, "  - Snapshot ", :bright, snapshot["snapshotId"], :reset, :green,
          " for volume ", :bright, snapshot["volumeId"], :reset, :green,
          device_info, :cyan, volume_type_info, :reset
        ])
      end)

      :ok
    else
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp find_instances_by_ips(region, instance_ips) do
    with {:ok, instances} <- AwsMachine.fetch_instances(region) do
      matching_instances = Enum.filter(instances, fn instance ->
        instance_ip = instance["ipAddress"] || instance["ipv6Address"]
        instance_ip in instance_ips
      end)

      case matching_instances do
        [] ->
          {:error, ErrorMessage.not_found(
            "No instances found with the provided IPs",
            %{instance_ips: instance_ips, region: region}
          )}

        instances ->
          Mix.shell().info([
            :green, "Found ", :bright, "#{length(instances)}", :reset, :green,
            " instance(s) for the app", :reset
          ])
          {:ok, instances}
      end
    end
  end

  defp find_volumes_for_instances(region, instances) do
    instance_ids = Enum.map(instances, & &1["instanceId"])

    filters = [
      {"attachment.instance-id", instance_ids}
    ]

    ExAws.EC2.describe_volumes(filters: filters)
      |> ExAws.request(region: region)
      |> case do
        {:ok, %{body: body}} ->
          case parse_volumes_response(body) do
            {:ok, []} ->
              {:error, ErrorMessage.not_found(
                "No volumes found for instances",
                %{instance_ids: instance_ids}
              )}

            {:ok, volumes} ->
              Mix.shell().info([
                :green, "Found ", :bright, "#{length(volumes)}", :reset, :green,
                " volume(s) across all instances", :reset
              ])
              {:ok, volumes}

            {:error, _} = error -> error
          end

        {:error, {:http_error, status_code, %{body: body}}} ->
          {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
            "Error fetching volumes from AWS",
            %{error_body: body, instance_ids: instance_ids}
          ])}

        {:error, error} ->
          {:error, ErrorMessage.bad_request(
            "Failed to describe volumes",
            %{error: error, instance_ids: instance_ids}
          )}
      end
  end

  defp filter_volumes_by_type(volumes, opts) do
    include_root = opts[:include_root] || false

    filtered_volumes = Enum.filter(volumes, fn volume ->
      device = extract_device_from_volume(volume)
      volume_type = classify_volume_type(device, volume)

      case volume_type do
        "Root Filesystem" -> include_root
        "Data Volume (/data)" -> true
        _ -> include_root  # Include other volumes only if include_root is true
      end
    end)

    case filtered_volumes do
      [] ->
        message = if include_root do
          "No volumes found for instances"
        else
          "No data volumes found for instances. Use --include-root to include root filesystem volumes"
        end

        {:error, ErrorMessage.not_found(message)}

      volumes ->
        volume_types = volumes
          |> Enum.map(fn volume ->
            device = extract_device_from_volume(volume)
            classify_volume_type(device, volume)
          end)
          |> Enum.uniq()

        Mix.shell().info([
          :green, "Found ", :bright, "#{length(volumes)}", :reset, :green,
          " volume(s) to snapshot: ", :cyan, Enum.join(volume_types, ", "), :reset
        ])

        {:ok, volumes}
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

  defp create_snapshots_for_volumes(region, volumes, app_name, opts) do
    description = opts[:description] || "EBS snapshot for #{app_name} - #{DateTime.utc_now()}"
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
    device = extract_device_from_volume(volume)
    volume_type = classify_volume_type(device, volume)

    snapshot_description = "#{description} (Volume: #{volume_id}#{if device, do: " - Device: #{device}", else: ""}#{if volume_type, do: " - #{volume_type}", else: ""})"

    device_info = if device, do: " on #{device}", else: ""
    type_info = if volume_type, do: " (#{volume_type})", else: ""

    Mix.shell().info([
      :green, "Creating snapshot for volume ", :bright, volume_id, :reset, :green,
      device_info, :cyan, type_info, :reset
    ])

    ExAws.EC2.create_snapshot(volume_id, description: snapshot_description)
      |> ExAws.request(region: region)
      |> case do
        {:ok, %{body: body}} ->
          case parse_snapshot_response(body) do
            {:ok, snapshot} ->
              # Add device and volume type info to snapshot for display
              snapshot_with_info = snapshot
                |> Map.put("device", device)
                |> Map.put("volume_type", volume_type)

              Mix.shell().info([
                :green, "Snapshot ", :bright, snapshot["snapshotId"], :reset, :green,
                " created for volume ", :bright, volume_id, :reset, :green,
                device_info, :cyan, type_info, :reset
              ])
              {:ok, snapshot_with_info}

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

  defp extract_device_from_volume(volume) do
    case volume["attachmentSet"]["item"] do
      attachments when is_list(attachments) ->
        # Get the first attachment's device
        case List.first(attachments) do
          %{"device" => device} -> device
          _ -> nil
        end

      %{"device" => device} ->
        device

      _ ->
        nil
    end
  end

  defp classify_volume_type(device, volume) do
    cond do
      is_root_volume?(device, volume) -> "Root Filesystem"
      is_data_volume?(device, volume) -> "Data Volume (/data)"
      is_swap_volume?(device, volume) -> "Swap Volume"
      is_log_volume?(device, volume) -> "Log Volume (/var/log)"
      is_tmp_volume?(device, volume) -> "Temp Volume (/tmp)"
      device -> "Additional Volume (#{device})"
      true -> "Unknown Volume"
    end
  end

  defp is_root_volume?(device, volume) do
    cond do
      # /dev/sdh is specifically the data volume, not root
      device === "/dev/sdh" -> false

      # Common root device names
      device in ["/dev/sda1", "/dev/xvda1", "/dev/nvme0n1p1", "/dev/sda", "/dev/xvda", "/dev/nvme0n1"] -> true

      # Check volume size - root volumes are typically smaller (8-50GB)
      volume["size"] && String.to_integer(volume["size"]) <= 50 -> true

      # Check if it's the boot volume
      volume["attachmentSet"]["item"]["deleteOnTermination"] === "true" -> true

      true -> false
    end
  end

  defp is_data_volume?(device, volume) do
    cond do
      # Primary data device used by deploy_ex (/dev/sdh maps to /data)
      device === "/dev/sdh" -> true

      # Other common data device names
      device in ["/dev/sdb", "/dev/xvdb", "/dev/nvme1n1", "/dev/sdf", "/dev/xvdf"] -> true

      # Check volume size - data volumes are typically larger (>50GB)
      volume["size"] && String.to_integer(volume["size"]) > 50 -> true

      # Check volume tags for data indication
      has_data_tag?(volume) -> true

      true -> false
    end
  end

  defp is_swap_volume?(device, _volume) do
    # Swap volumes are less common in cloud but can exist
    device in ["/dev/sdc", "/dev/xvdc", "/dev/nvme2n1"] and
    String.contains?(device || "", "swap")
  end

  defp is_log_volume?(device, volume) do
    # Log volumes for /var/log
    device in ["/dev/sdd", "/dev/xvdd", "/dev/nvme3n1"] or
    has_log_tag?(volume)
  end

  defp is_tmp_volume?(device, volume) do
    # Temp volumes for /tmp
    device in ["/dev/sde", "/dev/xvde", "/dev/nvme4n1"] or
    has_tmp_tag?(volume)
  end

  defp has_data_tag?(volume) do
    check_volume_tags(volume, ["data", "Data", "DATA", "storage", "Storage"])
  end

  defp has_log_tag?(volume) do
    check_volume_tags(volume, ["log", "Log", "LOG", "logs", "Logs"])
  end

  defp has_tmp_tag?(volume) do
    check_volume_tags(volume, ["tmp", "Tmp", "TMP", "temp", "Temp"])
  end

  defp check_volume_tags(volume, tag_values) do
    case volume["tagSet"]["item"] do
      tags when is_list(tags) ->
        Enum.any?(tags, fn tag ->
          case tag do
            %{"key" => "Name", "value" => value} -> value in tag_values or Enum.any?(tag_values, &String.contains?(value, &1))
            %{"key" => "Purpose", "value" => value} -> value in tag_values
            %{"key" => "Type", "value" => value} -> value in tag_values
            _ -> false
          end
        end)

      %{"key" => key, "value" => value} when key in ["Name", "Purpose", "Type"] ->
        value in tag_values or Enum.any?(tag_values, &String.contains?(value, &1))

      _ ->
        false
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
