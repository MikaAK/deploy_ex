defmodule Mix.Tasks.DeployEx.Qa.Create do
  use Mix.Task

  @shortdoc "Creates a new QA node with a specific SHA"
  @moduledoc """
  Creates a new QA node for a specific app and SHA.

  The QA node is a standalone EC2 instance that runs a specific release
  version for testing purposes.

  ## Example
  ```bash
  mix deploy_ex.qa.create my_app --sha abc1234
  mix deploy_ex.qa.create my_app                           # prompts for QA SHA on current branch
  mix deploy_ex.qa.create my_app --sha abc1234 --tag my-feature
  mix deploy_ex.qa.create my_app --sha abc1234 --public-ip-cert
  mix deploy_ex.qa.create my_app --sha abc1234 --attach-lb
  mix deploy_ex.qa.create my_app --sha abc1234 --skip-setup --skip-deploy
  mix deploy_ex.qa.create my_app --sha abc1234 --use-ami
  ```

  ## Options
  - `--sha, -s` - Target git SHA; if omitted, picks from QA releases on current branch
  - `--tag, -t` - Custom label used in the instance name (replaces the short SHA)
  - `--instance-type` - EC2 instance type (default: t3.small)
  - `--skip-setup` - Skip Ansible setup after creation
  - `--skip-deploy` - Skip deployment after setup
  - `--attach-lb` - Attach to load balancer after deployment
  - `--use-ami` - Boot from the app's pre-baked AMI (skips setup). Default is off for
    QA — nodes boot from the base AMI and run setup fresh
  - `--public-ip-cert` - Issue Let's Encrypt cert for the node's public IP (short-lived
    profile, HTTP-01 standalone). Use for standalone QA nodes not behind an LB. Persisted
    in the QA state so ansible picks it up on every subsequent run. Also triggers an
    LLM-assisted rewrite of host config in the umbrella to point at the QA IP; originals
    are restored on `qa.destroy`.
  - `--skip-host-rewrite` - Skip the LLM host config rewrite that normally runs with
    `--public-ip-cert`. Useful if you want to deploy with the existing config unchanged.
  - `--force, -f` - Replace existing QA node without prompting
  - `--quiet, -q` - Suppress output messages
  - `--aws-region` - AWS region (default: from config)
  - `--aws-release-bucket` - S3 bucket for releases (default: from config)
  """

  @ansible_default_path DeployEx.Config.ansible_folder_path()

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, extra_args} = parse_args(args)
      opts = default_skip_ami_for_qa(opts)

      DeployEx.TUI.setup_no_tui(opts)

      preflight_host_rewrite!(opts)

      opts = case DeployEx.ReleaseUploader.get_git_branch() do
        {:ok, branch} -> Keyword.put(opts, :git_branch, branch)
        {:error, _} -> opts
      end

      if DeployEx.TUI.enabled?() do
        run_unified_flow(extra_args, opts)
      else
        run_console_flow(extra_args, opts)
      end
    end
  end

  defp preflight_host_rewrite!(opts) do
    if host_rewrite_will_run?(opts) do
      check_llm_configured_or_raise()
      check_working_tree_or_raise()
    end
  end

  defp host_rewrite_will_run?(opts) do
    opts[:public_ip_cert] === true and opts[:skip_host_rewrite] !== true
  end

  defp check_llm_configured_or_raise do
    if is_nil(DeployEx.Config.llm_provider()) do
      Mix.raise("""
      --public-ip-cert triggers an LLM-assisted rewrite of host config so the QA node
      serves traffic from its public IP, but no LLM provider is configured.

      Either configure `:deploy_ex, :llm_provider` in config/*.exs (see
      DeployEx.Config.llm_provider/0), or pass --skip-host-rewrite to provision the
      node without touching config.
      """)
    end
  end

  defp check_working_tree_or_raise do
    case DeployEx.QaHostRewrite.working_tree_clean?(File.cwd!()) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        Mix.raise("""
        Working tree is dirty. --public-ip-cert will rewrite host config files in this
        umbrella so the QA node serves traffic from its public IP. Those rewrites are
        backed up and restored on `qa.destroy`, but the restore can't safely run on top
        of unrelated uncommitted changes.

        Either commit/stash your changes first, or pass --skip-host-rewrite to provision
        the node without touching config.
        """)

      {:error, _} ->
        Mix.shell().info([:yellow, "⚠ Could not check git status; continuing without clean-tree guard."])
        :ok
    end
  end

  defp run_console_flow(extra_args, opts) do
    app_name = resolve_app_name(extra_args)

    sha = case resolve_sha_for_create(app_name, opts) do
      {:ok, resolved} -> resolved
      {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
    end

    title = stream_title(app_name, sha, opts)

    provision_result = DeployEx.TUI.Progress.run_stream(
      "Provision: #{title}",
      fn tui_pid -> run_qa_provision(tui_pid, app_name, sha, opts, 6) end
    )

    case provision_result do
      {:ok, {qa_node, infra}} ->
        case maybe_rewrite_host_config(qa_node, opts) do
          :ok ->
            deploy_result = DeployEx.TUI.Progress.run_stream(
              "Deploy: #{title}",
              fn tui_pid -> run_qa_deploy(tui_pid, qa_node, infra, opts, 3) end
            )
            handle_final_result(deploy_result, opts)

          {:error, _} = error ->
            handle_final_result(error, opts)
        end

      {:error, _} = error ->
        handle_final_result(error, opts)
    end
  end

  defp run_unified_flow(extra_args, opts) do
    {provision_result, log_tail} =
      DeployEx.TUI.run(fn terminal ->
        with {:ok, app_name} <- resolve_app_in_terminal(extra_args, terminal),
             {:ok, sha} <- resolve_sha_in_terminal(terminal, app_name, opts) do
          title = stream_title(app_name, sha, opts)
          work_fn = fn tui_pid -> run_qa_provision(tui_pid, app_name, sha, opts, 6) end
          {result, tail} = DeployEx.TUI.Progress.stream_in_terminal(terminal, "Provision: #{title}", work_fn, opts)
          {{result, title}, tail}
        else
          {:error, _} = err -> {{err, nil}, []}
        end
      end)

    DeployEx.TUI.Progress.print_log_tail_on_error(provision_result, log_tail)

    case provision_result do
      {{:ok, {qa_node, infra}}, title} ->
        case maybe_rewrite_host_config(qa_node, opts) do
          :ok -> run_deploy_phase_unified(qa_node, infra, opts, title)
          {:error, _} = error -> handle_final_result(error, opts)
        end

      {{:error, _} = error, _title} ->
        handle_final_result(error, opts)
    end
  end

  defp run_deploy_phase_unified(qa_node, infra, opts, title) do
    {deploy_result, log_tail} =
      DeployEx.TUI.run(fn terminal ->
        work_fn = fn tui_pid -> run_qa_deploy(tui_pid, qa_node, infra, opts, 3) end
        DeployEx.TUI.Progress.stream_in_terminal(terminal, "Deploy: #{title}", work_fn, opts)
      end)

    DeployEx.TUI.Progress.print_log_tail_on_error(deploy_result, log_tail)
    handle_final_result(deploy_result, opts)
  end

  defp handle_final_result({:ok, qa_node}, opts), do: output_success(qa_node, opts)
  defp handle_final_result({:error, %ErrorMessage{} = error}, _opts), do: Mix.raise(ErrorMessage.to_string(error))
  defp handle_final_result({:error, error}, _opts), do: Mix.raise(inspect(error))

  defp stream_title(app_name, sha, opts) do
    short_sha = String.slice(sha, 0, 7)
    tag_part = if opts[:tag], do: " — tag #{opts[:tag]}", else: ""
    "QA Node: #{app_name} (SHA #{short_sha}#{tag_part})"
  end

  defp resolve_app_in_terminal([name | _], _terminal), do: {:ok, name}
  defp resolve_app_in_terminal([], terminal) do
    case fetch_available_app_names_safe() do
      {:ok, []} ->
        {:error, ErrorMessage.not_found("no mix releases found in this project")}

      {:ok, apps} ->
        pick_app_in_terminal(terminal, apps)

      {:error, _} = error ->
        error
    end
  end

  defp pick_app_in_terminal(terminal, apps) do
    case DeployEx.TUI.Select.run_in_terminal(terminal, apps,
           title: "Select app to create QA node for",
           allow_all: false,
           always_prompt: true
         ) do
      [chosen] -> {:ok, chosen}
      [] -> {:error, ErrorMessage.bad_request("no app selected")}
    end
  end

  defp resolve_sha_in_terminal(terminal, app_name, opts) do
    case opts[:sha] do
      sha when is_binary(sha) ->
        {:ok, sha}

      nil ->
        lookup_opts = [
          aws_region: opts[:aws_region] || DeployEx.Config.aws_region(),
          aws_release_bucket: opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket()
        ]

        DeployEx.ReleaseLookup.resolve_sha_any_in_terminal(
          terminal,
          app_name,
          [:qa, :prod],
          :prompt,
          lookup_opts
        )
    end
  end

  defp fetch_available_app_names_safe do
    case DeployExHelpers.fetch_mix_releases() do
      {:ok, releases} -> {:ok, releases |> Keyword.keys() |> Enum.map(&to_string/1)}
      {:error, e} -> {:error, ErrorMessage.failed_dependency("failed to fetch mix releases: #{e}")}
    end
  end

  defp run_qa_provision(tui_pid, app_name, sha, opts, total) do
    progress = fn step, label ->
      DeployEx.TUI.Progress.update_progress(tui_pid, step / total, label)
    end

    with :ok <- (progress.(1, "Validating app name..."); validate_app_name(app_name)),
         {:ok, full_sha} <- (progress.(2, "Validating SHA..."); validate_and_find_sha(app_name, sha, opts)),
         {:ok, infra} <- (progress.(3, "Gathering infrastructure..."); gather_infrastructure(app_name, opts)),
         {:ok, qa_node} <- (progress.(4, "Creating QA node..."); create_qa_node(app_name, full_sha, infra, opts)),
         :ok <- (progress.(5, "Waiting for instance to start..."); wait_for_instance(qa_node, opts)),
         {:ok, qa_node} <- (progress.(6, "Saving QA state..."); save_and_refresh_state(qa_node, opts)) do
      {:ok, {qa_node, infra}}
    end
  end

  defp run_qa_deploy(tui_pid, qa_node, infra, opts, total) do
    progress = fn step, label ->
      DeployEx.TUI.Progress.update_progress(tui_pid, step / total, label)
    end

    with :ok <- (progress.(1, "Waiting for SSH..."); wait_for_ssh_ready(qa_node)),
         :ok <- (progress.(2, "Running setup & deploy..."); maybe_run_setup(qa_node, infra, tui_pid, opts); maybe_wait_for_deploy(qa_node, infra, tui_pid, opts)),
         {:ok, qa_node} <- (progress.(3, "Attaching load balancer..."); maybe_attach_lb(qa_node, opts)) do
      {:ok, qa_node}
    end
  end

  defp maybe_rewrite_host_config(qa_node, opts) do
    cond do
      opts[:skip_host_rewrite] === true -> :ok
      qa_node.use_public_ip_cert? !== true -> :ok
      not is_binary(qa_node.public_ip) -> :ok
      true -> run_host_rewrite(qa_node)
    end
  end

  defp run_host_rewrite(qa_node) do
    public_ip = qa_node.public_ip

    Mix.shell().info([
      "\n", :cyan, "── QA Host Rewrite ──", :reset,
      "\nRewriting host config to route ", :bright, qa_node.app_name, :reset,
      " through ", :cyan, "https://#{public_ip}", :reset, "\n"
    ])

    umbrella_root = File.cwd!()
    app_name = qa_node.app_name
    module_prefix = DeployEx.ProjectContext.module_prefix_or_camelize(app_name)

    Mix.shell().info([:faint, "  Target app: :#{app_name} (module prefix: #{module_prefix})"])

    with {:ok, candidates} <- DeployEx.QaHostRewrite.scan_candidates(umbrella_root, app_name, module_prefix),
         :ok <- ensure_candidates_found(candidates),
         {:ok, proposals} <- propose_rewrites(candidates, public_ip, app_name, module_prefix),
         backup_dir = DeployEx.QaHostRewrite.backup_dir(app_name, qa_node.instance_id),
         {:ok, _entries} <- DeployEx.QaHostRewrite.review_and_apply(proposals, backup_dir) do
      Mix.shell().info([:green, "\n  ✓ Host rewrite complete. Originals backed up for restore on qa.destroy."])
      :ok
    else
      :no_candidates ->
        Mix.shell().info([:yellow, "  No host config candidates found; skipping rewrite."])
        :ok

      {:error, reason} ->
        Mix.shell().error("  ✗ Host rewrite failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_candidates_found([]), do: :no_candidates
  defp ensure_candidates_found(_list), do: :ok

  defp propose_rewrites(candidates, public_ip, app_name, module_prefix) do
    Mix.shell().info([:faint, "  Scanning #{length(candidates)} config file(s) with LLM..."])
    DeployEx.QaHostRewrite.propose_rewrite(candidates, public_ip, app_name, module_prefix)
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :sha, t: :tag, f: :force, q: :quiet],
      switches: [
        sha: :string,
        tag: :string,
        instance_type: :string,
        skip_setup: :boolean,
        skip_deploy: :boolean,
        skip_ami: :boolean,
        skip_host_rewrite: :boolean,
        use_ami: :boolean,
        attach_lb: :boolean,
        public_ip_cert: :boolean,
        force: :boolean,
        quiet: :boolean,
        aws_region: :string,
        aws_release_bucket: :string,
        no_tui: :boolean
      ]
    )
  end

  defp validate_app_name(app_name) do
    case DeployExHelpers.fetch_mix_releases() do
      {:ok, releases} ->
        release_names = releases |> Keyword.keys() |> Enum.map(&to_string/1)

        if app_name in release_names do
          :ok
        else
          {:error, ErrorMessage.not_found("app '#{app_name}' not found in mix releases", %{available: release_names})}
        end

      {:error, e} ->
        {:error, ErrorMessage.failed_dependency("failed to fetch mix releases: #{e}")}
    end
  end

  defp resolve_app_name([name | _]), do: name
  defp resolve_app_name([]) do
    case fetch_available_app_names() do
      [] -> Mix.raise("No mix releases found in this project. Define a release in mix.exs first.")
      apps -> pick_app(apps)
    end
  end

  defp fetch_available_app_names do
    case DeployExHelpers.fetch_mix_releases() do
      {:ok, releases} -> releases |> Keyword.keys() |> Enum.map(&to_string/1)
      {:error, e} -> Mix.raise("Failed to fetch mix releases: #{e}")
    end
  end

  defp pick_app(apps) do
    case DeployEx.TUI.Select.run(apps, title: "Select app to create QA node for", allow_all: false) do
      [chosen] -> chosen
      [] -> Mix.raise("No app selected. Pass an app name as the first argument or pick one from the list.")
    end
  end

  defp validate_and_find_sha(app_name, sha, opts) do
    release_fetch_opts = [
      aws_release_bucket: opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket(),
      aws_region: opts[:aws_region] || DeployEx.Config.aws_region()
    ]

    with {:error, _} <- find_sha_in_qa_releases(app_name, sha, release_fetch_opts),
         {:error, _} <- find_sha_in_prod_releases(app_name, sha, release_fetch_opts) do
      {:error, sha_not_found_error(app_name, sha, release_fetch_opts)}
    end
  end

  defp find_sha_in_qa_releases(app_name, sha, fetch_opts) do
    fetch_opts
      |> Keyword.put(:prefix, "qa/#{app_name}/")
      |> find_sha_in_releases(sha)
  end

  defp find_sha_in_prod_releases(app_name, sha, fetch_opts) do
    fetch_opts
      |> Keyword.put(:prefix, "#{app_name}/")
      |> find_sha_in_releases(sha)
  end

  defp find_sha_in_releases(fetch_opts, sha) do
    with {:ok, releases} <- DeployEx.ReleaseUploader.fetch_all_remote_releases(fetch_opts),
         release when not is_nil(release) <- Enum.find(releases, &String.contains?(&1, sha)),
         full_sha when not is_nil(full_sha) <- DeployExHelpers.extract_sha_from_release(release) do
      {:ok, full_sha}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp sha_not_found_error(app_name, sha, fetch_opts) do
    qa_releases = fetch_opts |> Keyword.put(:prefix, "qa/#{app_name}/") |> fetch_release_keys()
    prod_releases = fetch_opts |> Keyword.put(:prefix, "#{app_name}/") |> fetch_release_keys()
    suggestions = DeployExHelpers.format_release_suggestions(qa_releases ++ prod_releases, sha)

    ErrorMessage.not_found("no release found matching SHA '#{sha}' for app '#{app_name}'", %{suggestions: suggestions})
  end

  defp fetch_release_keys(opts) do
    case DeployEx.ReleaseUploader.fetch_all_remote_releases(opts) do
      {:ok, releases} -> releases
      {:error, _} -> []
    end
  end

  defp gather_infrastructure(app_name, opts) do
    console? = not DeployEx.TUI.enabled?()

    if console?, do: Mix.shell().info([:faint, "Gathering infrastructure details from AWS..."])

    infra_opts = if opts[:skip_ami] do
      opts
    else
      Keyword.put(opts, :app_name, app_name)
    end

    case DeployEx.AwsInfrastructure.gather_infrastructure(infra_opts) do
      {:ok, infra} ->
        if opts[:skip_ami] do
          {:ok, Map.put(infra, :using_app_ami, false)}
        else
          if infra.ami_id do
            if console?, do: Mix.shell().info([:green, "  ✓ ", :reset, "Using app AMI: ", :cyan, infra.ami_id, :reset, " (setup will be skipped)"])
            {:ok, Map.put(infra, :using_app_ami, true)}
          else
            if console?, do: Mix.shell().info([:yellow, "  ⚠ ", :reset, "No app AMI found, using base AMI"])
            {:ok, Map.put(infra, :using_app_ami, false)}
          end
        end

      error ->
        error
    end
  end

  defp create_qa_node(app_name, sha, infra, opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:cyan, "Creating QA node for ", :bright, app_name, :reset, :cyan, " with SHA ", :yellow, String.slice(sha, 0, 7), :reset, "..."])
    end

    params = %{
      ami_id: infra.ami_id,
      security_group_id: infra.security_group_id,
      subnet_id: infra.subnet_id,
      key_name: infra.key_name,
      iam_instance_profile: infra.iam_instance_profile,
      instance_type: opts[:instance_type],
      instance_tag: opts[:tag],
      git_branch: opts[:git_branch],
      use_public_ip_cert: opts[:public_ip_cert] === true
    }

    DeployEx.QaNode.create_instance(app_name, sha, params, opts)
  end

  defp resolve_sha_for_create(app_name, opts) do
    case opts[:sha] do
      nil ->
        lookup_opts = [
          aws_region: opts[:aws_region] || DeployEx.Config.aws_region(),
          aws_release_bucket: opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket()
        ]

        DeployEx.ReleaseLookup.resolve_sha_any(app_name, [:qa, :prod], :prompt, lookup_opts)

      sha ->
        {:ok, sha}
    end
  end

  defp wait_for_instance(qa_node, _opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:faint, "Waiting for instance ", :reset, qa_node.instance_id, :faint, " to start..."])
    end

    DeployEx.AwsMachine.wait_for_started([qa_node.instance_id])
  end

  defp wait_for_ssh_ready(qa_node) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:faint, "Waiting for SSH to be ready on ", :reset, :cyan, qa_node.public_ip, :reset, :faint, "..."])
    end

    wait_for_ssh(qa_node.public_ip)
  end

  defp save_and_refresh_state(qa_node, opts) do
    console? = not DeployEx.TUI.enabled?()

    if console?, do: Mix.shell().info([:faint, "Saving QA state to S3..."])

    case DeployEx.QaNode.save_qa_state(qa_node, opts) do
      {:ok, :saved} ->
        if console?, do: Mix.shell().info([:green, "  ✓ ", :reset, "QA state saved"])
        DeployEx.QaNode.verify_instance_exists(qa_node)

      {:error, error} ->
        Mix.shell().error("Failed to save QA state: #{inspect(error)}")
        {:error, error}
    end
  end

  defp maybe_run_setup(_qa_node, _infra, _tui_pid, %{skip_setup: true}), do: :ok
  defp maybe_run_setup(_qa_node, %{using_app_ami: true}, _tui_pid, _opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:green, "  ✓ ", :reset, "Skipping setup (using pre-configured AMI)"])
    end

    :ok
  end
  defp maybe_run_setup(qa_node, _infra, tui_pid, opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:faint, "Waiting for SSH to be ready on ", :reset, :cyan, qa_node.instance_name, :reset, :faint, "..."])
    end

    wait_for_ssh(qa_node.public_ip)

    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:cyan, "Running Ansible setup for ", :bright, qa_node.instance_name, :reset, "..."])
    end

    run_ansible_setup(qa_node, tui_pid, opts)
  end

  defp wait_for_ssh(ip, retries \\ 30) do
    case System.cmd("nc", ["-z", "-w", "5", ip, "22"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ when retries > 0 ->
        Process.sleep(5000)
        wait_for_ssh(ip, retries - 1)
      _ -> :ok
    end
  end

  defp maybe_wait_for_deploy(_qa_node, _infra, _tui_pid, %{skip_deploy: true}), do: :ok
  defp maybe_wait_for_deploy(qa_node, %{using_app_ami: true}, _tui_pid, _opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:faint, "Waiting for cloud-init to deploy release..."])
    end

    wait_for_ssh(qa_node.public_ip)

    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:green, "  ✓ ", :reset, "Release deployed via cloud-init"])
    end

    :ok
  end
  defp maybe_wait_for_deploy(qa_node, _infra, tui_pid, opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:cyan, "Deploying SHA ", :yellow, String.slice(qa_node.target_sha, 0, 7), :reset, :cyan, " to ", :bright, qa_node.instance_name, :reset, "..."])
    end

    run_ansible_deploy(qa_node, qa_node.target_sha, tui_pid, opts)
  end

  defp maybe_attach_lb(qa_node, %{attach_lb: true} = opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:faint, "Attaching to load balancer..."])
    end

    with {:ok, target_groups} <- DeployEx.AwsLoadBalancer.find_target_groups_by_app(qa_node.app_name, opts) do
      if Enum.empty?(target_groups) do
        if not DeployEx.TUI.enabled?() do
          Mix.shell().info([:yellow, "No target groups found for #{qa_node.app_name}"])
        end

        {:ok, qa_node}
      else
        DeployEx.QaNode.attach_to_load_balancer(qa_node, target_groups, opts)
      end
    end
  end
  defp maybe_attach_lb(qa_node, _opts), do: {:ok, qa_node}

  defp run_ansible_setup(qa_node, tui_pid, _opts) do
    run_qa_ansible(qa_node, :setup, setup_vars(qa_node), tui_pid, "ansible setup failed")
  end

  defp run_ansible_deploy(qa_node, sha, tui_pid, _opts) do
    run_qa_ansible(qa_node, :deploy, deploy_vars(qa_node, sha), tui_pid, "ansible deploy failed")
  end

  defp run_qa_ansible(qa_node, kind, vars, tui_pid, failure_message) do
    directory = @ansible_default_path

    DeployEx.QaPlaybook.with_temp_playbook(qa_node, kind, vars, directory, fn rel_path ->
      command = "ansible-playbook #{rel_path} --limit '#{qa_node.instance_name},'"
      line_callback = build_line_callback(tui_pid)

      case DeployEx.Utils.run_command_streaming(command, directory, line_callback) do
        :ok -> :ok
        {:error, error} -> {:error, ErrorMessage.failed_dependency(failure_message, %{error: error})}
      end
    end)
  end

  defp build_line_callback(nil), do: fn _line -> :ok end
  defp build_line_callback(tui_pid), do: fn line -> DeployEx.TUI.Progress.update_log(tui_pid, line) end

  defp setup_vars(_qa_node), do: []
  defp deploy_vars(_qa_node, sha), do: [target_release_sha: sha]

  defp default_skip_ami_for_qa(opts) do
    if opts[:use_ami], do: opts, else: Keyword.put(opts, :skip_ami, true)
  end

  defp output_success(qa_node, _opts) do
    Mix.shell().info([
      :green, "\n✓ QA node created successfully!\n",
      :reset, "\n",
      "  Instance ID: ", :cyan, qa_node.instance_id, :reset, "\n",
      "  Instance Name: ", :cyan, qa_node.instance_name, :reset, "\n",
      "  App: ", :cyan, qa_node.app_name, :reset, "\n",
      "  SHA: ", :cyan, qa_node.target_sha, :reset, "\n",
      "  Tag: ", :cyan, qa_node.instance_tag || "—", :reset, "\n",
      "  Branch: ", :cyan, qa_node.git_branch || "—", :reset, "\n",
      "  Public IP: ", :cyan, to_string(qa_node.public_ip || "pending"), :reset, "\n",
      "  IPv6: ", :cyan, to_string(qa_node.ipv6_address || "pending"), :reset, "\n",
      "  LB Attached: ", :cyan, to_string(qa_node.load_balancer_attached?), :reset, "\n",
      "\n",
      "  SSH: ", :yellow, "ssh admin@#{qa_node.public_ip || qa_node.ipv6_address}", :reset, "\n"
    ])
  end
end
