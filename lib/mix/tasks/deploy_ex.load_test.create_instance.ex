defmodule Mix.Tasks.DeployEx.LoadTest.CreateInstance do
  use Mix.Task

  @shortdoc "Creates a k6 runner EC2 instance"
  @moduledoc """
  Provisions an EC2 instance with k6 pre-installed for load testing.

  Checks for an existing runner first and reuses it unless --force is provided.

  ## Example
  ```bash
  mix deploy_ex.load_test.create_instance
  mix deploy_ex.load_test.create_instance --instance-type t3.medium
  mix deploy_ex.load_test.create_instance --force
  ```

  ## Options
  - `--instance-type` - EC2 instance type (default: t3.small)
  - `--force, -f` - Replace existing runner without prompting
  - `--quiet, -q` - Suppress output messages
  - `--resource-group` - Specify a custom resource group name
  - `--pem` - Specify a custom pem file
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, _extra_args} = parse_args(args)

      with {:ok, _runner} <- maybe_reuse_or_create(opts) do
        :ok
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet],
      switches: [
        instance_type: :string,
        force: :boolean,
        quiet: :boolean,
        resource_group: :string,
        pem: :string
      ]
    )
  end

  defp maybe_reuse_or_create(opts) do
    if !opts[:quiet] do
      Mix.shell().info([:faint, "Checking for existing k6 runners..."])
    end

    case DeployEx.K6Runner.fetch_all_runners(opts) do
      {:ok, [runner | _]} ->
        if opts[:force] do
          create_new_runner(opts)
        else
          case DeployEx.K6Runner.verify_instance_exists(runner) do
            {:ok, verified} when not is_nil(verified) ->
              if !opts[:quiet] do
                Mix.shell().info([
                  :green, "  ✓ ", :reset, "Found existing runner: ",
                  :cyan, verified.instance_id, :reset,
                  " (", verified.state || "unknown", ")"
                ])

                print_runner_info(verified)
              end

              {:ok, verified}

            _ ->
              create_new_runner(opts)
          end
        end

      _ ->
        create_new_runner(opts)
    end
  end

  defp create_new_runner(opts) do
    if !opts[:quiet] do
      Mix.shell().info([:cyan, "Creating k6 runner instance..."])
    end

    with {:ok, infra} <- gather_infrastructure(opts),
         {:ok, runner} <- DeployEx.K6Runner.create_instance(
           Map.put(infra, :instance_type, opts[:instance_type]),
           opts
         ),
         {:ok, :saved} <- DeployEx.K6Runner.save_state(runner, opts) do
      if !opts[:quiet] do
        Mix.shell().info([:green, "  ✓ ", :reset, "Instance created: ", :cyan, runner.instance_id])
        Mix.shell().info([:faint, "Waiting for instance to start..."])
      end

      DeployEx.AwsMachine.wait_for_started([runner.instance_id])

      case DeployEx.K6Runner.verify_instance_exists(runner) do
        {:ok, verified} when not is_nil(verified) ->
          if !opts[:quiet] do
            Mix.shell().info([:green, "  ✓ ", :reset, "Instance running"])
            wait_for_ssh(verified)
            Mix.shell().info([:green, "  ✓ ", :reset, "SSH ready"])
            print_runner_info(verified)
          end

          {:ok, verified}

        other ->
          other
      end
    end
  end

  defp gather_infrastructure(opts) do
    if !opts[:quiet] do
      Mix.shell().info([:faint, "Gathering infrastructure..."])
    end

    DeployEx.AwsInfrastructure.gather_infrastructure(
      Keyword.take(opts, [:resource_group])
    )
  end

  defp wait_for_ssh(runner) do
    ip = runner.public_ip || runner.ipv6_address

    if ip do
      Mix.shell().info([:faint, "Waiting for SSH on ", :reset, :cyan, ip, :reset, :faint, "..."])
      do_wait_for_ssh(ip, 30)
    end
  end

  defp do_wait_for_ssh(ip, retries) do
    case System.cmd("nc", ["-z", "-w", "5", ip, "22"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ when retries > 0 ->
        Process.sleep(5000)
        do_wait_for_ssh(ip, retries - 1)
      _ -> :ok
    end
  end

  defp print_runner_info(runner) do
    Mix.shell().info([
      :green, "\n✓ k6 Runner Ready\n", :reset,
      "\n",
      "  Instance ID: ", :cyan, runner.instance_id || "unknown", :reset, "\n",
      "  Public IP:   ", :cyan, runner.public_ip || "N/A", :reset, "\n",
      "  IPv6:        ", :cyan, runner.ipv6_address || "N/A", :reset, "\n",
      "  State:       ", :cyan, runner.state || "unknown", :reset, "\n",
      "  Created:     ", :cyan, runner.created_at || "unknown", :reset, "\n"
    ])
  end
end
