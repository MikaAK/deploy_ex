defmodule Mix.Tasks.Terraform.DeleteEbsSnapshot do
  use Mix.Task

  alias DeployEx.{AwsMachine, Config}

  @shortdoc "Deletes EBS snapshots for a specified app or by snapshot IDs"
  @moduledoc """
  Deletes EBS snapshots for a specified app or by providing specific snapshot IDs.

  ## Usage

  ```bash
  # Delete snapshots by app name (shows interactive selection)
  mix terraform.delete_ebs_snapshot <app_name>

  # Delete specific snapshots by ID
  mix terraform.delete_ebs_snapshot --snapshot-ids snap-123,snap-456

  # Delete all snapshots for an app (with confirmation)
  mix terraform.delete_ebs_snapshot <app_name> --all
  ```

  ## Arguments

  - `app_name` - The name of the app to find and delete snapshots for (optional if using --snapshot-ids)

  ## Options

  - `--snapshot-ids` - Comma-separated list of snapshot IDs to delete
  - `--all` - Delete all snapshots for the app without interactive selection
  - `--force` - Skip confirmation prompts
  - `--aws-region` - AWS region (default: from config)
  - `--resource_group` - Specify the resource group to target
  - `--max-age-days` - Only delete snapshots older than N days

  ## Examples

  ```bash
  # Interactive selection for app snapshots
  mix terraform.delete_ebs_snapshot my_app

  # Delete specific snapshots
  mix terraform.delete_ebs_snapshot --snapshot-ids snap-0abc123,snap-0def456

  # Delete all snapshots for app with confirmation
  mix terraform.delete_ebs_snapshot my_app --all

  # Delete old snapshots (older than 30 days)
  mix terraform.delete_ebs_snapshot my_app --max-age-days 30 --all

  # Force delete without confirmation
  mix terraform.delete_ebs_snapshot my_app --all --force
  ```
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, app_params, _} = OptionParser.parse(args,
      switches: [
        snapshot_ids: :string,
        all: :boolean,
        force: :boolean,
        aws_region: :string,
        resource_group: :string,
        max_age_days: :integer
      ]
    )

    region = opts[:aws_region] || Config.aws_region()
    {machine_opts, opts} = Keyword.split(opts, [:resource_group])

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, snapshots_to_delete} <- determine_snapshots_to_delete(region, app_params, machine_opts, opts),
         :ok <- confirm_deletion(snapshots_to_delete, opts),
         {:ok, deleted_snapshots} <- delete_snapshots(region, snapshots_to_delete) do
      
      Mix.shell().info([
        :green, "Successfully deleted ", :bright, "#{length(deleted_snapshots)}", :reset, :green,
        " snapshot(s):", :reset
      ])

      Enum.each(deleted_snapshots, fn snapshot_id ->
        Mix.shell().info([
          :green, "  - Deleted snapshot ", :bright, snapshot_id, :reset
        ])
      end)

      :ok
    else
      {:error, :cancelled} ->
        Mix.shell().info([:yellow, "Deletion cancelled by user", :reset])
        :ok

      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp determine_snapshots_to_delete(region, app_params, machine_opts, opts) do
    cond do
      opts[:snapshot_ids] ->
        snapshot_ids = String.split(opts[:snapshot_ids], ",") |> Enum.map(&String.trim/1)
        get_snapshots_by_ids(region, snapshot_ids)

      app_params !== [] ->
        with {:ok, app_name} <- DeployExHelpers.find_project_name(app_params),
             {:ok, instance_ips} <- AwsMachine.find_instance_ips(DeployExHelpers.project_name(), app_name, machine_opts),
             {:ok, instances} <- find_instances_by_ips(region, instance_ips),
             {:ok, volumes} <- find_volumes_for_instances(region, instances),
             {:ok, snapshots} <- find_snapshots_for_volumes(region, volumes, opts) do
          
          if opts[:all] do
            {:ok, snapshots}
          else
            {:ok, prompt_for_snapshot_selection(snapshots)}
          end
        end

      true ->
        {:error, ErrorMessage.bad_request("Must provide either app name or --snapshot-ids")}
    end
  end

  defp get_snapshots_by_ids(region, snapshot_ids) do
    ExAws.EC2.describe_snapshots(snapshot_ids: snapshot_ids)
      |> ExAws.request(region: region)
      |> case do
        {:ok, %{body: body}} ->
          case parse_snapshots_response(body) do
            {:ok, snapshots} ->
              snapshot_data = Enum.map(snapshots, fn snapshot ->
                %{
                  snapshot_id: snapshot["snapshotId"],
                  volume_id: snapshot["volumeId"],
                  description: snapshot["description"],
                  start_time: snapshot["startTime"]
                }
              end)
              {:ok, snapshot_data}

            {:error, _} = error -> error
          end

        {:error, {:http_error, status_code, %{body: body}}} ->
          {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
            "Error fetching snapshots from AWS",
            %{error_body: body, snapshot_ids: snapshot_ids}
          ])}

        {:error, error} ->
          {:error, ErrorMessage.bad_request(
            "Failed to describe snapshots",
            %{error: error, snapshot_ids: snapshot_ids}
          )}
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

  defp find_snapshots_for_volumes(region, volumes, opts) do
    volume_ids = Enum.map(volumes, & &1["volumeId"])
    
    filters = [
      {"volume-id", volume_ids}
    ]

    ExAws.EC2.describe_snapshots(filters: filters)
      |> ExAws.request(region: region)
      |> case do
        {:ok, %{body: body}} ->
          case parse_snapshots_response(body) do
            {:ok, snapshots} ->
              filtered_snapshots = snapshots
                |> filter_snapshots_by_age(opts[:max_age_days])
                |> Enum.map(fn snapshot ->
                  %{
                    snapshot_id: snapshot["snapshotId"],
                    volume_id: snapshot["volumeId"],
                    description: snapshot["description"],
                    start_time: snapshot["startTime"]
                  }
                end)

              {:ok, filtered_snapshots}

            {:error, _} = error -> error
          end

        {:error, {:http_error, status_code, %{body: body}}} ->
          {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
            "Error fetching snapshots from AWS",
            %{error_body: body, volume_ids: volume_ids}
          ])}

        {:error, error} ->
          {:error, ErrorMessage.bad_request(
            "Failed to describe snapshots",
            %{error: error, volume_ids: volume_ids}
          )}
      end
  end

  defp filter_snapshots_by_age(snapshots, nil), do: snapshots
  defp filter_snapshots_by_age(snapshots, max_age_days) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-max_age_days, :day)
    
    Enum.filter(snapshots, fn snapshot ->
      case DateTime.from_iso8601(snapshot["startTime"]) do
        {:ok, snapshot_date, _} -> DateTime.compare(snapshot_date, cutoff_date) === :lt
        _ -> false
      end
    end)
  end

  defp prompt_for_snapshot_selection(snapshots) do
    if Enum.empty?(snapshots) do
      Mix.shell().info([:yellow, "No snapshots found to delete", :reset])
      []
    else
      Mix.shell().info([
        :green, "Found ", :bright, "#{length(snapshots)}", :reset, :green,
        " snapshot(s). Select which ones to delete:", :reset
      ])

      snapshot_choices = Enum.map(snapshots, fn snapshot ->
        "#{snapshot.snapshot_id} (Volume: #{snapshot.volume_id}, Created: #{snapshot.start_time})"
      end)

      selected_choices = DeployExHelpers.prompt_for_choice(snapshot_choices, true)
      
      Enum.filter(snapshots, fn snapshot ->
        choice = "#{snapshot.snapshot_id} (Volume: #{snapshot.volume_id}, Created: #{snapshot.start_time})"
        choice in selected_choices
      end)
    end
  end

  defp confirm_deletion([], _opts), do: :ok
  defp confirm_deletion(_snapshots, %{force: true}), do: :ok
  defp confirm_deletion(snapshots, _opts) do
    Mix.shell().info([
      :red, "WARNING: You are about to delete ", :bright, "#{length(snapshots)}", :reset, :red,
      " snapshot(s). This action cannot be undone!", :reset
    ])

    Enum.each(snapshots, fn snapshot ->
      Mix.shell().info([
        :red, "  - ", :bright, snapshot.snapshot_id, :reset, :red,
        " (Volume: #{snapshot.volume_id})", :reset
      ])
    end)

    case Mix.shell().yes?("Are you sure you want to delete these snapshots?") do
      true -> :ok
      false -> {:error, :cancelled}
    end
  end

  defp delete_snapshots(region, snapshots) do
    snapshots
      |> Task.async_stream(fn snapshot ->
        delete_single_snapshot(region, snapshot.snapshot_id)
      end, max_concurrency: 4, timeout: :timer.seconds(30))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, snapshot_id}}, {:ok, acc} ->
          {:cont, {:ok, [snapshot_id | acc]}}

        {:ok, {:error, _} = error}, _acc ->
          {:halt, error}

        {:exit, reason}, _acc ->
          {:halt, {:error, ErrorMessage.failed_dependency(
            "Task failed while deleting snapshot",
            %{reason: reason}
          )}}
      end)
      |> case do
        {:ok, deleted_snapshots} -> {:ok, Enum.reverse(deleted_snapshots)}
        error -> error
      end
  end

  defp delete_single_snapshot(region, snapshot_id) do
    Mix.shell().info([
      :green, "Deleting snapshot ", :bright, snapshot_id, :reset
    ])

    ExAws.EC2.delete_snapshot(snapshot_id)
      |> ExAws.request(region: region)
      |> case do
        {:ok, %{body: _body}} ->
          Mix.shell().info([
            :green, "Successfully deleted snapshot ", :bright, snapshot_id, :reset
          ])
          {:ok, snapshot_id}

        {:error, {:http_error, status_code, %{body: body}}} ->
          {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
            "Error deleting snapshot",
            %{error_body: body, snapshot_id: snapshot_id}
          ])}

        {:error, error} ->
          {:error, ErrorMessage.bad_request(
            "Failed to delete snapshot",
            %{error: error, snapshot_id: snapshot_id}
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

  defp parse_snapshots_response(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeSnapshotsResponse" => %{"snapshotSet" => %{"item" => snapshots}}} when is_list(snapshots) ->
        {:ok, snapshots}

      %{"DescribeSnapshotsResponse" => %{"snapshotSet" => %{"item" => snapshot}}} ->
        {:ok, [snapshot]}

      %{"DescribeSnapshotsResponse" => %{"snapshotSet" => nil}} ->
        {:ok, []}

      structure ->
        {:error, ErrorMessage.bad_request(
          "Couldn't parse snapshots response from AWS",
          %{structure: structure}
        )}
    end
  end
end
