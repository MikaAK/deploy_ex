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
        orphans = Enum.flat_map(app_names, fn app_name ->
          case DeployEx.QaNode.fetch_all_qa_states_for_app(app_name, opts) do
            {:ok, states} ->
              Enum.reduce(states, [], fn state, acc ->
                if is_nil(state.instance_id) do
                  acc
                else
                    case DeployEx.AwsMachine.find_instances_by_id([state.instance_id]) do
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
                end
              end)

            _ ->
              []
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
        orphans = instances
        |> Enum.reject(fn instance -> instance["instanceState"]["name"] === "terminated" end)
        |> Enum.reduce([], fn instance, acc ->
          tags = get_instance_tags(instance)
          instance_group = tags["InstanceGroup"]
          instance_id = instance["instanceId"]

          app_name = extract_app_name_from_instance_group(instance_group)

          if app_name do
            case DeployEx.QaNode.fetch_qa_state(app_name, instance_id, opts) do
              {:ok, nil} ->
                [instance | acc]

              {:ok, _state} ->
                acc

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

  defp extract_app_name_from_instance_group(nil), do: nil
  defp extract_app_name_from_instance_group(instance_group) do
    case String.split(instance_group, "_") do
      parts when length(parts) >= 2 ->
        parts |> Enum.drop(-1) |> Enum.join("_")
      _ ->
        instance_group
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
    Mix.shell().info([:cyan, "\nQA Node Cleanup Report"])
    Mix.shell().info(String.duplicate("=", 40))

    unless Enum.empty?(s3_orphans) do
      Mix.shell().info([:yellow, "\nS3 State Orphans ", :reset, "(instance terminated/not found):"])

      Enum.each(s3_orphans, fn {app_name, state, reason} ->
        Mix.shell().info([
          "  - ", :cyan, app_name, :reset,
          ": ", :white, state.instance_id || "unknown", :reset,
          " (", :red, reason, :reset, ")"
        ])
      end)
    end

    unless Enum.empty?(instance_orphans) do
      Mix.shell().info([:yellow, "\nInstance Orphans ", :reset, "(no S3 state):"])

      Enum.each(instance_orphans, fn instance ->
        tags = get_instance_tags(instance)
        state_name = instance["instanceState"]["name"]
        state_color = if state_name === "running", do: :green, else: :yellow

        Mix.shell().info([
          "  - ", :white, instance["instanceId"], :reset,
          " (", :cyan, tags["Name"] || "unnamed", :reset,
          ", ", state_color, state_name, :reset, ")"
        ])
      end)
    end

    Mix.shell().info([:yellow, "\nActions:"])

    unless Enum.empty?(s3_orphans) do
      Mix.shell().info(["  - ", :red, "Delete ", :reset, "#{length(s3_orphans)} S3 state file(s)"])
    end

    unless Enum.empty?(instance_orphans) do
      Mix.shell().info(["  - ", :red, "Terminate ", :reset, "#{length(instance_orphans)} orphaned instance(s)"])
    end
  end

  defp prompt_confirmation(s3_orphans, instance_orphans) do
    total = length(s3_orphans) + length(instance_orphans)

    unless Mix.shell().yes?("\nProceed with cleanup of #{total} orphan(s)?") do
      Mix.raise("Aborted")
    end
  end

  defp cleanup_s3_orphans(orphans, opts) do
    Enum.each(orphans, fn {app_name, state, _reason} ->
      case DeployEx.QaNode.delete_qa_state(state, opts) do
        :ok ->
          unless opts[:quiet] do
            Mix.shell().info([:green, "  ✓ Deleted S3 state for #{app_name} (#{state.instance_id})"])
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
