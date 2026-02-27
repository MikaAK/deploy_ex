defmodule Mix.Tasks.DeployEx.LoadTest.DestroyInstance do
  use Mix.Task

  @shortdoc "Destroys a k6 runner instance"
  @moduledoc """
  Terminates a k6 runner EC2 instance and cleans up S3 state.

  ## Example
  ```bash
  mix deploy_ex.load_test.destroy_instance
  mix deploy_ex.load_test.destroy_instance --instance-id i-0abc123
  mix deploy_ex.load_test.destroy_instance --all
  mix deploy_ex.load_test.destroy_instance --force
  ```

  ## Options
  - `--instance-id, -i` - Specific instance ID to destroy
  - `--all` - Destroy all k6 runners
  - `--force, -f` - Skip confirmation prompt
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, _extra_args} = parse_args(args)

      runners = find_runners_to_destroy(opts)

      case runners do
        [] ->
          Mix.shell().info([:yellow, "No k6 runners found to destroy"])

        nodes ->
          unless opts[:force] do
            prompt_confirmation(nodes)
          end

          Enum.each(nodes, fn runner ->
            destroy_runner(runner, opts)
          end)

          Mix.shell().info([:green, "\n✓ Destroyed #{length(nodes)} k6 runner(s)"])
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [i: :instance_id, f: :force, q: :quiet],
      switches: [
        instance_id: :string,
        all: :boolean,
        force: :boolean,
        quiet: :boolean
      ]
    )
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

  defp destroy_runner(runner, opts) do
    unless opts[:quiet] do
      Mix.shell().info("Destroying #{runner.instance_name || runner.instance_id}...")
    end

    case DeployEx.K6Runner.terminate_runner(runner, opts) do
      :ok ->
        unless opts[:quiet] do
          Mix.shell().info([:green, "  ✓ Destroyed #{runner.instance_name || runner.instance_id}"])
        end

      {:error, error} ->
        Mix.shell().error("  ✗ Failed to destroy #{runner.instance_name || runner.instance_id}: #{ErrorMessage.to_string(error)}")
    end
  end
end
