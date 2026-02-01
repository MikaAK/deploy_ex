defmodule Mix.Tasks.DeployEx.Qa.Cleanup do
  use Mix.Task

  @shortdoc "Cleans up orphaned QA nodes"
  @moduledoc """
  Detects and cleans up orphaned QA nodes where S3 state exists but instance
  is terminated, or instances exist without S3 state.

  ## Example
  ```bash
  mix deploy_ex.qa.cleanup
  mix deploy_ex.qa.cleanup --dry-run
  mix deploy_ex.qa.cleanup --force
  ```

  ## Options
  - `--dry-run` - Show what would be cleaned up without taking action
  - `--force, -f` - Skip confirmation prompt
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      opts = parse_args(args)

      with {:ok, s3_orphans} <- find_s3_orphans(opts),
           {:ok, instance_orphans} <- find_instance_orphans(opts) do
        if Enum.empty?(s3_orphans) and Enum.empty?(instance_orphans) do
          unless opts[:quiet] do
            Mix.shell().info([:green, "No orphaned QA nodes found"])
          end
        else
          report_orphans(s3_orphans, instance_orphans, opts)

          if opts[:dry_run] do
            Mix.shell().info([:yellow, "\nDry run - no changes made"])
          else
            unless opts[:force] do
              prompt_confirmation(s3_orphans, instance_orphans)
            end

            cleanup_s3_orphans(s3_orphans, opts)
            cleanup_instance_orphans(instance_orphans, opts)

            unless opts[:quiet] do
              total = length(s3_orphans) + length(instance_orphans)
              Mix.shell().info([:green, "\n✓ Cleaned up #{total} orphan(s)"])
            end
          end
        end
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet],
      switches: [
        dry_run: :boolean,
        force: :boolean,
        quiet: :boolean
      ]
    )

    opts
  end

  defp find_s3_orphans(opts) do
    case DeployEx.QaNode.list_all_qa_states(opts) do
      {:ok, app_names} ->
        orphans = Enum.reduce(app_names, [], fn app_name, acc ->
          case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
            {:ok, %{instance_id: instance_id} = state} when not is_nil(instance_id) ->
              case DeployEx.AwsMachine.find_instances_by_id([instance_id]) do
                {:ok, [instance]} ->
                  if instance["instanceState"]["name"] === "terminated" do
                    [{app_name, state, "terminated"} | acc]
                  else
                    acc
                  end

                {:error, %ErrorMessage{code: :not_found}} ->
                  [{app_name, state, "not found"} | acc]

                _ ->
                  acc
              end

            _ ->
              acc
          end
        end)

        {:ok, orphans}

      error ->
        error
    end
  end

  defp find_instance_orphans(opts) do
    case DeployEx.AwsMachine.find_instances_by_tags([{"QaNode", "true"}], opts) do
      {:ok, instances} ->
        orphans = Enum.reduce(instances, [], fn instance, acc ->
          tags = get_instance_tags(instance)
          app_name = tags["InstanceGroup"]

          if app_name do
            instance_id = instance["instanceId"]

            case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
              {:ok, nil} ->
                [instance | acc]

              {:ok, %{instance_id: stored_id}} when stored_id !== instance_id ->
                [instance | acc]

              _ ->
                acc
            end
          else
            [instance | acc]
          end
        end)

        {:ok, orphans}

      {:error, %ErrorMessage{code: :not_found}} ->
        {:ok, []}

      error ->
        error
    end
  end

  defp get_instance_tags(instance) do
    case instance["tagSet"] do
      %{"item" => items} when is_list(items) ->
        Map.new(items, fn %{"key" => k, "value" => v} -> {k, v} end)

      %{"item" => %{"key" => k, "value" => v}} ->
        %{k => v}

      _ ->
        %{}
    end
  end

  defp report_orphans(s3_orphans, instance_orphans, _opts) do
    Mix.shell().info("\nQA Node Cleanup Report")
    Mix.shell().info(String.duplicate("=", 40))

    unless Enum.empty?(s3_orphans) do
      Mix.shell().info("\nS3 State Orphans (instance terminated/not found):")

      Enum.each(s3_orphans, fn {app_name, state, reason} ->
        Mix.shell().info([
          "  - ", :cyan, app_name, :reset,
          ": ", state.instance_id || "unknown", " (", reason, ")"
        ])
      end)
    end

    unless Enum.empty?(instance_orphans) do
      Mix.shell().info("\nInstance Orphans (no S3 state):")

      Enum.each(instance_orphans, fn instance ->
        tags = get_instance_tags(instance)
        Mix.shell().info([
          "  - ", instance["instanceId"],
          " (", tags["Name"] || "unnamed", ", ", instance["instanceState"]["name"], ")"
        ])
      end)
    end

    Mix.shell().info("\nActions:")

    unless Enum.empty?(s3_orphans) do
      Mix.shell().info("  - Delete #{length(s3_orphans)} S3 state file(s)")
    end

    unless Enum.empty?(instance_orphans) do
      Mix.shell().info("  - Terminate #{length(instance_orphans)} orphaned instance(s)")
    end
  end

  defp prompt_confirmation(s3_orphans, instance_orphans) do
    total = length(s3_orphans) + length(instance_orphans)

    unless Mix.shell().yes?("\nProceed with cleanup of #{total} orphan(s)?") do
      Mix.raise("Aborted")
    end
  end

  defp cleanup_s3_orphans(orphans, opts) do
    Enum.each(orphans, fn {app_name, _state, _reason} ->
      case DeployEx.QaNode.delete_qa_state(app_name, opts) do
        :ok ->
          unless opts[:quiet] do
            Mix.shell().info([:green, "  ✓ Deleted S3 state for #{app_name}"])
          end

        {:error, error} ->
          Mix.shell().error("  ✗ Failed to delete S3 state for #{app_name}: #{ErrorMessage.to_string(error)}")
      end
    end)
  end

  defp cleanup_instance_orphans(orphans, opts) do
    Enum.each(orphans, fn instance ->
      instance_id = instance["instanceId"]

      case DeployEx.QaNode.terminate_instance(instance_id, opts) do
        :ok ->
          unless opts[:quiet] do
            Mix.shell().info([:green, "  ✓ Terminated orphaned instance #{instance_id}"])
          end

        {:error, error} ->
          Mix.shell().error("  ✗ Failed to terminate #{instance_id}: #{ErrorMessage.to_string(error)}")
      end
    end)
  end
end
