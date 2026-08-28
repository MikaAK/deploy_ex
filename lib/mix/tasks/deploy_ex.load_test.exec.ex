defmodule Mix.Tasks.DeployEx.LoadTest.Exec do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()
  @prometheus_monitoring_tag {"MonitoringKey", "prometheus_db"}

  @shortdoc "Executes a k6 test on a runner"
  @moduledoc """
  Runs a k6 load test on a runner instance via SSH, streaming output back.

  Results are pushed to Prometheus via remote write for Grafana visualization.
  When no `--prometheus-url` is given, the running prometheus node's private IP
  is discovered by tag; if none is found, the test runs without metrics export.

  ## Example
  ```bash
  mix deploy_ex.load_test.exec my_app
  mix deploy_ex.load_test.exec my_app --target-url http://my-app:4000
  mix deploy_ex.load_test.exec my_app --script custom_test.js
  mix deploy_ex.load_test.exec my_app --prometheus-url http://10.0.101.171:9090
  ```

  ## Options
  - `--script` - Script filename on runner (default: load_test.js)
  - `--target-url` - Application endpoint URL passed as TARGET_URL env var
  - `--prometheus-url` - Prometheus remote write base URL (default: discovered by tag)
  - `--instance-id, -i` - Specific runner instance ID
  - `--pem` - Path to PEM file
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, extra_args} = parse_args(args)

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required: mix deploy_ex.load_test.exec <app_name>")
      end

      with {:ok, runner} <- resolve_runner(opts),
           {:ok, pem_file} <- DeployEx.Terraform.find_pem_file(@terraform_default_path, opts[:pem]),
           {:ok, prometheus_url} <- resolve_prometheus_url(opts) do
        ip = runner.public_ip || runner.ipv6_address

        if is_nil(ip) do
          Mix.raise("Runner has no reachable IP address")
        end

        unless opts[:quiet] do
          if is_nil(prometheus_url) do
            Mix.shell().info([
              :yellow,
              "⚠ No prometheus node found and --prometheus-url not set — running without metrics export"
            ])
          end
        end

        script = opts[:script] || "load_test.js"
        target_url = opts[:target_url]

        unless opts[:quiet] do
          Mix.shell().info([
            :cyan, "\nRunning k6 load test", :reset, "\n",
            "  Runner:     ", :cyan, ip, :reset, "\n",
            "  App:        ", :cyan, app_name, :reset, "\n",
            "  Script:     ", :cyan, script, :reset, "\n",
            "  Prometheus: ", :cyan, prometheus_url || "(disabled)", :reset, "\n",
            "  Target URL: ", :cyan, target_url || "(from script)", :reset, "\n",
            "\n"
          ])
        end

        with :ok <- preflight_k6(ip, pem_file, opts) do
          command = build_k6_command(script, prometheus_url, target_url)

          case run_k6_via_ssh(ip, pem_file, command, opts) do
            :ok -> :ok
            {:error, reason} -> Mix.raise(reason)
          end
        else
          {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
        end
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    {opts, extra_args} = OptionParser.parse!(args,
      aliases: [i: :instance_id, q: :quiet],
      switches: [
        script: :string,
        target_url: :string,
        prometheus_url: :string,
        instance_id: :string,
        pem: :string,
        quiet: :boolean,
        provider: :string
      ]
    )

    {DeployExHelpers.parse_provider_opt!(opts), extra_args}
  end

  defdelegate resolve_runner(opts, k6_runner_impl \\ DeployEx.K6Runner), to: DeployEx.K6Runner

  def resolve_prometheus_url(opts, discover_fn \\ nil) do
    discover_fn = discover_fn || fn -> discover_prometheus_ip(opts) end

    case opts[:prometheus_url] do
      url when is_binary(url) -> {:ok, url}
      _ -> resolve_discovered_prometheus_url(discover_fn)
    end
  end

  defp resolve_discovered_prometheus_url(discover_fn) do
    case discover_fn.() do
      {:ok, ip} when is_binary(ip) -> {:ok, "http://#{ip}:9090"}
      _ -> {:ok, nil}
    end
  end

  @doc false
  def discover_prometheus_ip(opts \\ []) do
    with {:ok, machine} <- DeployEx.Cloud.capability(:machine, opts) do
      case machine.list_instances([@prometheus_monitoring_tag], opts) do
        {:ok, instances} -> find_running_prometheus_ip(instances)
        error -> error
      end
    end
  end

  defp find_running_prometheus_ip(instances) do
    case Enum.find(instances, &running_instance?/1) do
      nil -> {:error, ErrorMessage.not_found("no running prometheus node found")}
      instance -> {:ok, instance.private_ip}
    end
  end

  defp running_instance?(instance), do: instance.state === "running"

  @doc """
  SSH `user@host` target for a runner, resolved through `DeployEx.Cloud.ssh_user/1` so a
  non-AWS provider's default user (e.g. OCI's `ubuntu`) reaches these SSH transports.
  """
  def ssh_target(ip, opts \\ []), do: "#{DeployEx.Cloud.ssh_user(opts)}@#{ip}"

  @doc """
  Argv for the `ssh` binary, shared by both SSH transports below (`System.cmd` preflight and
  the `Port.open` k6 run). Pure and pinned directly by tests — mirrors `build_k6_command/3` —
  so a regression to a hardcoded ssh user shows up as a failing assertion on the argv itself,
  not just on the `ssh_target/2` helper that could silently go unused at a call site.
  """
  def ssh_args(ip, pem_file, command, opts \\ []) do
    [
      "-i", Path.expand(pem_file),
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      ssh_target(ip, opts),
      command
    ]
  end

  defp preflight_k6(ip, pem_file, opts) do
    case run_ssh_command(ip, pem_file, "k6 version", opts) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        {:error, ErrorMessage.failed_dependency(
          "k6 is not available on the runner — verify setup completed via mix deploy_ex.load_test.create_instance",
          %{reason: reason}
        )}
    end
  end

  # SSH transport shell-out — dev-tooling exemption (spawns the ssh binary, no pure
  # logic to unit test; behavior is pinned by run_k6_via_ssh's Port-based sibling below).
  defp run_ssh_command(ip, pem_file, command, opts) do
    case System.cmd("ssh", ssh_args(ip, pem_file, command, opts), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, output}
    end
  end

  def build_k6_command(script, prometheus_url, target_url) do
    env_vars = []
    |> maybe_add_env_var("TARGET_URL", target_url)
    |> maybe_add_env_var("K6_PROMETHEUS_RW_SERVER_URL", prometheus_write_url(prometheus_url))

    "#{env_var_prefix(env_vars)}k6 run#{prometheus_flag(prometheus_url)} /srv/k6/scripts/#{script}"
  end

  defp maybe_add_env_var(env_vars, _name, nil), do: env_vars
  defp maybe_add_env_var(env_vars, name, value), do: env_vars ++ ["#{name}=#{value}"]

  defp prometheus_write_url(nil), do: nil
  defp prometheus_write_url(prometheus_url), do: "#{prometheus_url}/api/v1/write"

  defp prometheus_flag(nil), do: ""
  defp prometheus_flag(_prometheus_url), do: " -o experimental-prometheus-rw"

  defp env_var_prefix([]), do: ""
  defp env_var_prefix(env_vars), do: "#{Enum.join(env_vars, " ")} "

  defp run_k6_via_ssh(ip, pem_file, command, opts) do
    port = Port.open({:spawn_executable, System.find_executable("ssh")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ssh_args(ip, pem_file, "sudo #{command}", opts)
    ])

    stream_output(port)
  end

  @idle_timeout_ms :timer.minutes(5)

  defp stream_output(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        stream_output(port)

      {^port, {:exit_status, 0}} ->
        Mix.shell().info([:green, "\n✓ k6 test completed successfully"])
        :ok

      {^port, {:exit_status, code}} ->
        {:error, "k6 test exited with code #{code}"}
    after
      @idle_timeout_ms ->
        Port.close(port)
        {:error, "k6 test produced no output for 5 minutes — aborting"}
    end
  end
end
