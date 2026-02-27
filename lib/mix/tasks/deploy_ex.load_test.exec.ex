defmodule Mix.Tasks.DeployEx.LoadTest.Exec do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()
  @default_prometheus_url "http://10.0.1.40:9090"

  @shortdoc "Executes a k6 test on a runner"
  @moduledoc """
  Runs a k6 load test on a runner instance via SSH, streaming output back.

  Results are pushed to Prometheus via remote write for Grafana visualization.

  ## Example
  ```bash
  mix deploy_ex.load_test.exec my_app
  mix deploy_ex.load_test.exec my_app --target-url http://my-app:4000
  mix deploy_ex.load_test.exec my_app --script custom_test.js
  mix deploy_ex.load_test.exec my_app --prometheus-url http://10.0.1.40:9090
  ```

  ## Options
  - `--script` - Script filename on runner (default: load_test.js)
  - `--target-url` - Application endpoint URL passed as TARGET_URL env var
  - `--prometheus-url` - Prometheus remote write base URL (default: http://10.0.1.40:9090)
  - `--instance-id, -i` - Specific runner instance ID
  - `--pem` - Path to PEM file
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required: mix deploy_ex.load_test.exec <app_name>")
      end

      with {:ok, runner} <- find_runner(opts),
           {:ok, pem_file} <- DeployEx.Terraform.find_pem_file(@terraform_default_path, opts[:pem]) do
        ip = runner.public_ip || runner.ipv6_address

        if is_nil(ip) do
          Mix.raise("Runner has no reachable IP address")
        end

        script = opts[:script] || "load_test.js"
        prometheus_url = opts[:prometheus_url] || @default_prometheus_url
        target_url = opts[:target_url]

        unless opts[:quiet] do
          Mix.shell().info([
            :cyan, "\nRunning k6 load test", :reset, "\n",
            "  Runner:     ", :cyan, ip, :reset, "\n",
            "  App:        ", :cyan, app_name, :reset, "\n",
            "  Script:     ", :cyan, script, :reset, "\n",
            "  Prometheus: ", :cyan, prometheus_url, :reset, "\n",
            "  Target URL: ", :cyan, target_url || "(from script)", :reset, "\n",
            "\n"
          ])
        end

        command = build_k6_command(script, prometheus_url, target_url)
        run_k6_via_ssh(ip, pem_file, command)
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [i: :instance_id, q: :quiet],
      switches: [
        script: :string,
        target_url: :string,
        prometheus_url: :string,
        instance_id: :string,
        pem: :string,
        quiet: :boolean
      ]
    )
  end

  defp find_runner(opts) do
    case opts[:instance_id] do
      nil ->
        case DeployEx.K6Runner.fetch_all_runners(opts) do
          {:ok, [runner | _]} ->
            case DeployEx.K6Runner.verify_instance_exists(runner) do
              {:ok, verified} when not is_nil(verified) -> {:ok, verified}
              _ -> {:error, ErrorMessage.not_found("k6 runner not found or terminated")}
            end

          {:ok, []} ->
            {:error, ErrorMessage.not_found("no k6 runners found, create one with: mix deploy_ex.load_test.create_instance")}

          error ->
            error
        end

      instance_id ->
        case DeployEx.K6Runner.fetch_state(instance_id, opts) do
          {:ok, runner} when not is_nil(runner) ->
            DeployEx.K6Runner.verify_instance_exists(runner)

          {:ok, nil} ->
            {:error, ErrorMessage.not_found("k6 runner #{instance_id} not found")}

          error ->
            error
        end
    end
  end

  defp build_k6_command(script, prometheus_url, target_url) do
    env_vars = [
      "K6_PROMETHEUS_RW_SERVER_URL=#{prometheus_url}/api/v1/write"
    ]

    env_vars = if target_url do
      ["TARGET_URL=#{target_url}" | env_vars]
    else
      env_vars
    end

    env_string = Enum.join(env_vars, " ")

    "#{env_string} k6 run -o experimental-prometheus-rw /srv/k6/scripts/#{script}"
  end

  defp run_k6_via_ssh(ip, pem_file, command) do
    abs_pem = Path.expand(pem_file)

    port = Port.open({:spawn_executable, System.find_executable("ssh")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: [
        "-i", abs_pem,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "admin@#{ip}",
        "sudo #{command}"
      ]
    ])

    stream_output(port)
  end

  defp stream_output(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        stream_output(port)

      {^port, {:exit_status, 0}} ->
        Mix.shell().info([:green, "\n✓ k6 test completed successfully"])

      {^port, {:exit_status, code}} ->
        Mix.shell().error("\nk6 test exited with code #{code}")
    end
  end
end
