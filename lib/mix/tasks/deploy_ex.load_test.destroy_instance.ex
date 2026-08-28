defmodule Mix.Tasks.DeployEx.LoadTest.DestroyInstance do
  use Mix.Task

  @shortdoc "Destroys a k6 runner instance"
  @moduledoc """
  Terminates a k6 runner EC2 instance and cleans up S3 state.

  If more than one runner is found, either `--instance-id` or `--all` is
  required — an ambiguous multi-runner destroy is refused rather than
  silently destroying everything.

  ## Example
  ```bash
  mix deploy_ex.load_test.destroy_instance
  mix deploy_ex.load_test.destroy_instance --instance-id i-0abc123
  mix deploy_ex.load_test.destroy_instance --all
  mix deploy_ex.load_test.destroy_instance --force
  ```

  ## Options
  - `--instance-id, -i` - Specific instance ID to destroy
  - `--all` - Destroy every k6 runner found (required when more than one exists)
  - `--force, -f` - Skip confirmation prompt
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, _extra_args} = parse_args(args)

      runners = find_runners_to_destroy(opts)

      case runners do
        [] ->
          Mix.shell().info([:yellow, "No k6 runners found to destroy"])

        nodes ->
          case ambiguous_scope_error(nodes, opts) do
            :ok -> destroy_nodes(nodes, opts)
            {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
          end
      end
    end
  end

  defp destroy_nodes(nodes, opts) do
    unless opts[:force] do
      prompt_confirmation(nodes)
    end

    terminate_fn = opts[:terminate_fn] || (&DeployEx.K6Runner.terminate_runner/2)
    results = destroy_runners(nodes, terminate_fn, opts)

    case failed_runners(results) do
      [] ->
        Mix.shell().info([:green, "\n✓ Destroyed #{length(nodes)} k6 runner(s)"])

      failed ->
        Mix.raise(destroy_failure_message(nodes, failed))
    end
  end

  @doc false
  def ambiguous_scope_error(runners, opts) when length(runners) > 1 do
    if is_nil(opts[:instance_id]) and !opts[:all] do
      ids = Enum.map_join(runners, ", ", & &1.instance_id)

      {:error, ErrorMessage.bad_request(
        "found #{length(runners)} k6 runners (#{ids}) — pass --all to destroy all of them, " <>
          "or --instance-id/-i to target one",
        %{instance_ids: Enum.map(runners, & &1.instance_id)}
      )}
    else
      :ok
    end
  end

  def ambiguous_scope_error(_runners, _opts), do: :ok

  defp parse_args(args) do
    {opts, extra_args} = OptionParser.parse!(args,
      aliases: [i: :instance_id, f: :force, q: :quiet],
      switches: [
        instance_id: :string,
        all: :boolean,
        force: :boolean,
        quiet: :boolean,
        provider: :string
      ]
    )

    {DeployExHelpers.parse_provider_opt!(opts), extra_args}
  end

  defp find_runners_to_destroy(opts) do
    case DeployEx.K6Runner.fetch_all_runners(opts) do
      {:ok, runners} ->
        runners
        |> maybe_filter_by_instance_id(opts[:instance_id])
        |> Enum.map(fn runner ->
          case DeployEx.K6Runner.verify_instance_exists(runner) do
            {:ok, verified} when not is_nil(verified) -> verified
            _ -> runner
          end
        end)

      {:error, _} ->
        case DeployEx.K6Runner.find_runners_from_ec2(opts) do
          {:ok, runners} -> maybe_filter_by_instance_id(runners, opts[:instance_id])
          _ -> []
        end
    end
  end

  defp maybe_filter_by_instance_id(runners, nil), do: runners
  defp maybe_filter_by_instance_id(runners, instance_id) do
    Enum.filter(runners, &(&1.instance_id === instance_id))
  end

  defp prompt_confirmation(runners) do
    Mix.shell().info("\nk6 runners to destroy:")

    Enum.each(runners, fn runner ->
      Mix.shell().info([
        "  - ", :cyan, runner.instance_name || runner.instance_id, :reset,
        " (", runner.instance_id, ")"
      ])
    end)

    unless Mix.shell().yes?("\nProceed with destruction?") do
      Mix.raise("Aborted")
    end
  end

  @doc false
  def destroy_runners(runners, terminate_fn, opts) do
    Enum.map(runners, fn runner -> {runner, destroy_runner(runner, terminate_fn, opts)} end)
  end

  @doc false
  def failed_runners(results) do
    for {runner, {:error, _error}} <- results, do: runner
  end

  @doc false
  def destroy_failure_message(runners, failed) do
    succeeded_count = length(runners) - length(failed)
    failed_ids = Enum.map_join(failed, ", ", & &1.instance_id)

    "Destroyed #{succeeded_count}/#{length(runners)} k6 runner(s); still running: #{failed_ids}"
  end

  defp destroy_runner(runner, terminate_fn, opts) do
    unless opts[:quiet] do
      Mix.shell().info("Destroying #{runner.instance_name || runner.instance_id}...")
    end

    case terminate_fn.(runner, opts) do
      :ok ->
        unless opts[:quiet] do
          Mix.shell().info([:green, "  ✓ Destroyed #{runner.instance_name || runner.instance_id}"])
        end

        :ok

      {:error, error} = error_tuple ->
        Mix.shell().error("  ✗ Failed to destroy #{runner.instance_name || runner.instance_id}: #{ErrorMessage.to_string(error)}")

        error_tuple
    end
  end
end
