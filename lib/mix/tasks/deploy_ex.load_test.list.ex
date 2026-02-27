defmodule Mix.Tasks.DeployEx.LoadTest.List do
  use Mix.Task

  @shortdoc "Lists all active k6 runner instances"
  @moduledoc """
  Lists all active k6 runner instances with their status.

  ## Example
  ```bash
  mix deploy_ex.load_test.list
  mix deploy_ex.load_test.list --json
  ```

  ## Options
  - `--json` - Output as JSON
  - `--quiet, -q` - Minimal output
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      opts = parse_args(args)

      case list_runners(opts) do
        {:ok, []} ->
          unless opts[:quiet] do
            Mix.shell().info([:yellow, "No k6 runners found"])
          end

        {:ok, runners} ->
          output_runners(runners, opts)

        {:error, error} ->
          Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [q: :quiet],
      switches: [
        json: :boolean,
        quiet: :boolean
      ]
    )

    opts
  end

  defp list_runners(opts) do
    case DeployEx.K6Runner.fetch_all_runners(opts) do
      {:ok, runners} ->
        verified = Enum.map(runners, fn runner ->
          case DeployEx.K6Runner.verify_instance_exists(runner) do
            {:ok, verified} when not is_nil(verified) -> verified
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

        {:ok, verified}

      {:error, _} ->
        DeployEx.K6Runner.find_runners_from_ec2(opts)
    end
  end

  defp output_runners(runners, %{json: true}) do
    json = runners
    |> Enum.map(&runner_to_map/1)
    |> Jason.encode!(pretty: true)

    Mix.shell().info(json)
  end

  defp output_runners(runners, opts) do
    unless opts[:quiet] do
      Mix.shell().info("\nk6 Runners:")
      Mix.shell().info(String.duplicate("-", 80))
    end

    Enum.each(runners, fn runner ->
      state_color = case runner.state do
        "running" -> :green
        "stopped" -> :yellow
        "terminated" -> :red
        _ -> :reset
      end

      Mix.shell().info([
        :cyan, runner.instance_name || runner.instance_id, :reset, "\n",
        "  Instance ID: ", runner.instance_id || "unknown", "\n",
        "  State:       ", state_color, runner.state || "unknown", :reset, "\n",
        "  Public IP:   ", runner.public_ip || "N/A", "\n",
        "  IPv6:        ", runner.ipv6_address || "N/A", "\n",
        "  Created:     ", runner.created_at || "unknown", "\n"
      ])
    end)

    unless opts[:quiet] do
      Mix.shell().info(String.duplicate("-", 80))
      Mix.shell().info("Total: #{length(runners)} k6 runner(s)")
    end
  end

  defp runner_to_map(runner) do
    %{
      instance_id: runner.instance_id,
      instance_name: runner.instance_name,
      state: runner.state,
      public_ip: runner.public_ip,
      ipv6_address: runner.ipv6_address,
      private_ip: runner.private_ip,
      created_at: runner.created_at
    }
  end
end
