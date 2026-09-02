defmodule Mix.Tasks.DeployEx.LoadTest.CreateInstance do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @ssh_wait_retries 30
  @ssh_wait_sleep_ms 5_000

  @setup_wait_retries 30
  @setup_wait_sleep_ms 10_000

  @setup_log_path "/var/log/k6-setup.log"

  @shortdoc "Creates a k6 runner EC2 instance"
  @moduledoc """
  Provisions an EC2 instance with k6 pre-installed for load testing.

  Checks for an existing runner first and reuses it unless --force is provided.
  A freshly created runner is not reported ready until SSH is reachable and k6
  is confirmed installed on the instance.

  ## Example
  ```bash
  mix deploy_ex.load_test.create_instance
  mix deploy_ex.load_test.create_instance --instance-type t3.medium
  mix deploy_ex.load_test.create_instance --force
  ```

  ## Options
  - `--instance-type` - EC2 instance type (default: t3.small)
  - `--force, -f` - Terminate existing runner(s) and their state, then create a new one
  - `--quiet, -q` - Suppress output messages
  - `--resource-group` - Specify a custom resource group name
  - `--pem` - Specify a custom pem file
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, _extra_args} = parse_args(args)

      with {:ok, _runner} <- maybe_reuse_or_create(opts) do
        :ok
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  @doc false
  def parse_args(args) do
    {opts, extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet],
      switches: [
        instance_type: :string,
        force: :boolean,
        quiet: :boolean,
        resource_group: :string,
        pem: :string,
        provider: :string
      ]
    )

    {DeployExHelpers.parse_provider_opt!(opts), extra_args}
  end

  defp maybe_reuse_or_create(opts) do
    if !opts[:quiet] do
      Mix.shell().info([:faint, "Checking for existing k6 runners..."])
    end

    case DeployEx.K6Runner.fetch_all_runners(opts) do
      {:ok, [runner | _] = runners} ->
        if opts[:force] do
          replace_runners(runners, opts)
        else
          case DeployEx.K6Runner.verify_instance_exists(runner, opts) do
            {:ok, verified} when not is_nil(verified) ->
              reuse_existing_runner(verified, opts)

            _ ->
              create_new_runner(opts)
          end
        end

      _ ->
        create_new_runner(opts)
    end
  end

  # Reuse-path readiness gate — an existing runner is only handed back once k6
  # is confirmed installed, same as a freshly created one; a half-provisioned
  # or broken existing runner never passes as "ready".

  @doc false
  def reuse_existing_runner(runner, opts) do
    if !opts[:quiet] do
      Mix.shell().info([
        :green, "  ✓ ", :reset, "Found existing runner: ",
        :cyan, runner.instance_id, :reset,
        " (", runner.state || "unknown", ")"
      ])
    end

    case find_pem_file(opts) do
      {:ok, pem_file} -> verify_reused_runner_ready(runner, pem_file, opts)
      {:error, _} = error -> error
    end
  end

  defp verify_reused_runner_ready(runner, pem_file, opts) do
    case wait_for_setup_complete(runner, pem_file, opts) do
      :ok ->
        if !opts[:quiet] do
          print_runner_info(runner)
        end

        {:ok, runner}

      {:error, reason} ->
        reuse_setup_check_failed(runner, reason)
    end
  end

  defp reuse_setup_check_failed(runner, reason) do
    {:error, ErrorMessage.failed_dependency(
      "existing k6 runner #{runner.instance_id} did not pass the k6 setup check — " <>
        "recreate it with: mix deploy_ex.load_test.create_instance --force",
      %{instance_id: runner.instance_id, reason: reason}
    )}
  end

  defp replace_runners(runners, opts) do
    if !opts[:quiet] do
      Mix.shell().info([
        :faint, "--force: replacing ", :reset, :cyan, "#{length(runners)}", :reset,
        :faint, " existing runner(s)...", :reset
      ])
    end

    terminate_fn = opts[:terminate_fn] || (&DeployEx.K6Runner.terminate_runner/2)

    case terminate_all_runners(runners, terminate_fn, opts) do
      :ok -> create_new_runner(opts)
      {:error, _} = error -> error
    end
  end

  @doc false
  def terminate_all_runners(runners, terminate_fn, opts) do
    Enum.reduce_while(runners, :ok, fn runner, :ok ->
      case terminate_fn.(runner, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
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
         {:ok, :saved} <- DeployEx.K6Runner.save_state(runner, opts),
         :ok <- announce_instance_created(runner, opts),
         {:ok, machine} <- DeployEx.Cloud.capability(:machine, opts),
         :ok <- machine.await_running([runner.instance_id], opts),
         {:ok, verified} <- verify_created_runner(runner, opts) do
      if !opts[:quiet] do
        Mix.shell().info([:green, "  ✓ ", :reset, "Instance running"])
      end

      await_runner_ready(verified, opts)
    end
  end

  defp announce_instance_created(runner, opts) do
    if !opts[:quiet] do
      Mix.shell().info([:green, "  ✓ ", :reset, "Instance created: ", :cyan, runner.instance_id])
      Mix.shell().info([:faint, "Waiting for instance to start..."])
    end

    :ok
  end

  # Post-create verify (LT-D6/LT-FIX-A orphan guard) — AWS describe-instances
  # can lag behind a just-created instance (eventual consistency). Routing
  # through the shared resolver's {:ok, nil} handling would misreport this as
  # "no runner exists" and (via verify_instance_exists) delete the S3 state we
  # just wrote, orphaning an instance that is very much still running and
  # billing, invisible to list/destroy. Turn that into a loud, actionable
  # error naming the leaked instance instead of letting {:ok, nil} slip
  # through as a false success, and re-save state so it stays findable.
  @doc false
  def verify_created_runner(runner, opts, k6_runner_impl \\ DeployEx.K6Runner) do
    resolve_opts = Keyword.put(opts, :instance_id, runner.instance_id)

    case DeployEx.K6Runner.resolve_runner(resolve_opts, k6_runner_impl) do
      {:ok, verified} -> {:ok, verified}
      {:error, _reason} -> orphaned_runner_error(runner, opts, k6_runner_impl)
    end
  end

  defp orphaned_runner_error(runner, opts, k6_runner_impl) do
    k6_runner_impl.save_state(runner, opts)
    provider = DeployEx.Cloud.active_provider(opts)

    {:error, ErrorMessage.failed_dependency(
      "k6 runner #{runner.instance_id} was created but #{inspect(provider)} does not yet report it as running " <>
        "(eventual consistency) — the instance and its billing still exist; check again with " <>
        "mix deploy_ex.load_test.list, or destroy it with: " <>
        "mix deploy_ex.load_test.destroy_instance --instance-id #{runner.instance_id}",
      %{instance_id: runner.instance_id, provider: provider}
    )}
  end

  defp await_runner_ready(runner, opts) do
    with {:ok, pem_file} <- find_pem_file(opts),
         :ok <- wait_for_ssh(runner, opts),
         :ok <- wait_for_setup_complete(runner, pem_file, opts) do
      if !opts[:quiet] do
        print_runner_info(runner)
      end

      {:ok, runner}
    end
  end

  defp find_pem_file(opts) do
    DeployEx.Terraform.find_pem_file(@terraform_default_path, opts[:pem])
  end

  # Whitelisted to the keys a provider's gather_infrastructure/1 legitimately needs, not
  # forwarded whole — mirrors the same reasoning as AwsMachine's request_fn whitelist
  # (LT-OCI review-fix G1): :resource_group is AWS's own key, :pem lets OCI's find_key_pair
  # honor a user's --pem override instead of always falling back to a directory glob, and
  # :run_fn is the test injection seam (unused live; OCI's discovery is config-driven and
  # never shells out, but the seam still needs to reach a provider that later does).
  @doc false
  def gather_infrastructure(opts) do
    if !opts[:quiet] do
      Mix.shell().info([:faint, "Gathering infrastructure..."])
    end

    with {:ok, infrastructure} <- DeployEx.Cloud.capability(:infrastructure, opts) do
      infrastructure.gather_infrastructure(Keyword.take(opts, [:resource_group, :pem, :run_fn] ++ oci_setting_keys(opts)))
    end
  end

  # oci_* keys carry the OCI CLI's opts-first config overrides (DeployEx.Cloud.OciCli.setting/2)
  # — Keyword.take/2 only needs their NAMES, so this just filters opts down to that shape
  # without hardcoding the specific oci_subnet_id/oci_base_image/... list here twice.
  defp oci_setting_keys(opts) do
    opts |> Keyword.keys() |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "oci_"))
  end

  # SSH reachability wait (D7: honest failure — never claims ready after exhausting retries)

  defp wait_for_ssh(runner, opts) do
    ip = runner.public_ip || runner.ipv6_address

    if is_nil(ip) do
      {:error, ErrorMessage.not_found(
        "k6 runner #{runner.instance_id} has no reachable ip address",
        %{instance_id: runner.instance_id}
      )}
    else
      if !opts[:quiet] do
        Mix.shell().info([:faint, "Waiting for SSH on ", :reset, :cyan, ip, :reset, :faint, "..."])
      end

      probe_fn = opts[:ssh_probe_fn] || (&default_ssh_probe?/1)
      sleep_fn = opts[:sleep_fn] || (&Process.sleep/1)
      retries = opts[:ssh_wait_retries] || @ssh_wait_retries

      case do_wait_for_ssh(runner.instance_id, ip, retries, probe_fn, sleep_fn) do
        :ok ->
          if !opts[:quiet] do
            Mix.shell().info([:green, "  ✓ ", :reset, "SSH ready"])
          end

          :ok

        error ->
          error
      end
    end
  end

  @doc false
  def do_wait_for_ssh(instance_id, ip, 0, _probe_fn, _sleep_fn) do
    {:error, ErrorMessage.failed_dependency(
      "ssh did not become reachable on #{instance_id} (#{ip}) before timeout",
      %{instance_id: instance_id, ip: ip}
    )}
  end

  def do_wait_for_ssh(instance_id, ip, retries, probe_fn, sleep_fn) do
    if probe_fn.(ip) do
      :ok
    else
      if retries > 1, do: sleep_fn.(@ssh_wait_sleep_ms)
      do_wait_for_ssh(instance_id, ip, retries - 1, probe_fn, sleep_fn)
    end
  end

  defp default_ssh_probe?(ip) do
    case DeployEx.Utils.run_command_with_return("nc -z -w 5 #{ip} 22", File.cwd!()) do
      {:ok, _output} -> true
      _ -> false
    end
  end

  # k6 setup readiness gate (D3: no success claim until k6 is verified installed)

  defp wait_for_setup_complete(runner, pem_file, opts) do
    ip = runner.public_ip || runner.ipv6_address

    if !opts[:quiet] do
      Mix.shell().info([:faint, "Waiting for k6 setup to complete on ", :reset, :cyan, ip, :reset, :faint, "..."])
    end

    check_fn = opts[:check_fn] || (&default_k6_ready?(&1, &2, opts))
    sleep_fn = opts[:sleep_fn] || (&Process.sleep/1)
    retries = opts[:setup_wait_retries] || @setup_wait_retries

    case do_wait_for_setup_complete(runner.instance_id, ip, pem_file, retries, check_fn, sleep_fn) do
      :ok ->
        if !opts[:quiet] do
          Mix.shell().info([:green, "  ✓ ", :reset, "k6 setup complete"])
        end

        :ok

      error ->
        error
    end
  end

  @doc false
  def do_wait_for_setup_complete(instance_id, ip, _pem_file, 0, _check_fn, _sleep_fn) do
    {:error, ErrorMessage.failed_dependency(
      "k6 setup did not complete on #{instance_id} before timeout — check #{@setup_log_path} on #{ip}",
      %{instance_id: instance_id, ip: ip, setup_log: @setup_log_path}
    )}
  end

  def do_wait_for_setup_complete(instance_id, ip, pem_file, retries, check_fn, sleep_fn) do
    if check_fn.(ip, pem_file) do
      :ok
    else
      if retries > 1, do: sleep_fn.(@setup_wait_sleep_ms)
      do_wait_for_setup_complete(instance_id, ip, pem_file, retries - 1, check_fn, sleep_fn)
    end
  end

  defp default_k6_ready?(ip, pem_file, opts) do
    case DeployEx.SSH.run_command(ip, pem_file, "k6 version", user: DeployEx.Cloud.ssh_user(opts)) do
      {:ok, _output} -> true
      _ -> false
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
