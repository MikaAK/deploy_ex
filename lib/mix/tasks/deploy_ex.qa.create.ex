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

  ## Wait for build (CI-gated deploys)

  Pass `--wait-for-build` to commit + push the SSL/host rewrites and wait for
  GitHub Actions to build the release artifact before deploying.

      mix deploy_ex.qa.create cfx_web --public-ip-cert --wait-for-build --tag canary

  Detection: scans `.github/workflows/*.yml` for the workflow whose `on.push.branches`
  matches the QA branch and whose jobs (or sub-workflow jobs) run `mix deploy_ex.release`.

  Branch resolution: if the current branch matches `^qa[\/-]` it is reused; otherwise
  derives `qa/<app>-<tag>` (or `qa/<app>-<short_sha>` if `--tag` is omitted).

  ### Auto-installed QA deploy step

  While running with `--wait-for-build`, qa.create idempotently patches the detected
  workflow so the build job ends with a `Deploy to QA Node` step that runs
  `mix deploy_ex.qa.deploy --git-branch <branch>` for QA refs. The existing
  `Run Ansible Deploy` step is guarded so it skips on QA branches. The patch is
  marked with sentinel comments (`# deploy_ex:qa-deploy:*`) and is a no-op on
  subsequent runs. Pass `--skip-action-install` to opt out.

  Options:
    --build-workflow=<file>   Override workflow auto-detection
    --build-job=<job_id>      Override job auto-detection within the workflow
    --build-timeout=<minutes> Default 30. Max wait for the build to complete
    --skip-action-install     Skip the workflow yml patch that installs the QA-deploy step

  On build failure, prompts with 4 options:
    1. Destroy QA node + revert (full rollback)
    2. Leave everything (no cleanup)
    3. Destroy QA node only (keep commit + local files)
    4. Revert LLM changes + repush (keep QA node, retry build)

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
        run_pipeline_tui(extra_args, opts)
      else
        run_pipeline_console(extra_args, opts)
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

  defp validate_wait_for_build_preconditions(_opts, _umbrella_root, _app_name, false), do: {:ok, %{enabled?: false}}

  defp validate_wait_for_build_preconditions(opts, umbrella_root, app_name, true) do
    with :ok <- DeployEx.ToolInstaller.ensure_installed(:gh),
         :ok <- DeployEx.GitHubActions.ensure_authenticated(),
         {:ok, branch_resolution} <- resolve_branch(opts, umbrella_root, app_name),
         {:ok, %{} = workflow} <- detect_or_override_workflow(opts, umbrella_root, branch_resolution) do
      {:ok,
       %{
         enabled?: true,
         workflow: workflow,
         branch_resolution: branch_resolution
       }}
    end
  end

  defp detect_or_override_workflow(opts, umbrella_root, {_action, branch}) do
    workflows_root = Path.join(umbrella_root, ".github/workflows")

    case {opts[:build_workflow], opts[:build_job]} do
      {wf, job} when is_binary(wf) and is_binary(job) ->
        {:ok, %{file: wf, job_id: job}}

      _ ->
        DeployEx.GitHubActions.find_build_workflow(workflows_root, branch)
    end
  end

  defp resolve_branch(opts, umbrella_root, app_name) do
    sha = opts[:sha] || head_sha(umbrella_root)
    tag = opts[:tag]

    case DeployEx.GitOperations.resolve_qa_branch(umbrella_root, app_name, tag, sha) do
      {:reuse_current, b} = result ->
        if opts[:sha] && opts[:sha] !== sha do
          {:error,
           ErrorMessage.bad_request(
             "already on qa branch #{b}; --sha conflicts with HEAD. Drop --sha or checkout a different branch first.",
             %{}
           )}
        else
          {:ok, result}
        end

      {:create_new, _b} = result ->
        {:ok, result}
    end
  end

  defp head_sha(repo_root) do
    case DeployEx.Utils.run_command_with_return("git rev-parse HEAD", repo_root) do
      {:ok, sha} -> String.trim(sha)
      _ -> "HEAD"
    end
  end

  defp run_pipeline_tui(extra_args, opts) do
    {result, log_tail} =
      DeployEx.TUI.run(fn terminal ->
        with {:ok, app_name} <- resolve_app_in_terminal(extra_args, terminal),
             {:ok, sha} <- resolve_sha_in_terminal(terminal, app_name, opts) do
          title = stream_title(app_name, sha, opts)
          work_fn = fn tui_pid -> run_qa_pipeline_work(tui_pid, app_name, sha, opts) end
          DeployEx.TUI.Progress.stream_in_terminal(terminal, title, work_fn, opts)
        else
          {:error, _} = err -> {err, []}
        end
      end)

    DeployEx.TUI.Progress.print_log_tail_on_error(result, log_tail)
    handle_final_result(result, opts)
  end

  defp run_pipeline_console(extra_args, opts) do
    app_name = resolve_app_name(extra_args)

    sha = case resolve_sha_for_create(app_name, opts) do
      {:ok, resolved} -> resolved
      {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
    end

    title = stream_title(app_name, sha, opts)

    result = DeployEx.TUI.Progress.run_stream(title, fn tui_pid ->
      run_qa_pipeline_work(tui_pid, app_name, sha, opts)
    end)

    handle_final_result(result, opts)
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

  @pipeline_total_steps_base 12
  @pipeline_total_steps_wait_for_build 15

  defp pipeline_total_steps(opts) do
    if opts[:wait_for_build], do: @pipeline_total_steps_wait_for_build, else: @pipeline_total_steps_base
  end

  defp step_for(:validate_app, _opts), do: 1
  defp step_for(:validate_sha, _opts), do: 2
  defp step_for(:plan_rewrite, _opts), do: 3
  defp step_for(:review_proposals, _opts), do: 4
  defp step_for(:preflight_build, _opts), do: 5
  defp step_for(:gather_infra, opts), do: if(opts[:wait_for_build], do: 6, else: 5)
  defp step_for(:create_node, opts), do: if(opts[:wait_for_build], do: 7, else: 6)
  defp step_for(:wait_instance, opts), do: if(opts[:wait_for_build], do: 8, else: 7)
  defp step_for(:save_state, opts), do: if(opts[:wait_for_build], do: 9, else: 8)
  defp step_for(:apply_rewrite, opts), do: if(opts[:wait_for_build], do: 10, else: 9)
  defp step_for(:commit_push, _opts), do: 11
  defp step_for(:wait_build, _opts), do: 12
  defp step_for(:wait_ssh, opts), do: if(opts[:wait_for_build], do: 13, else: 10)
  defp step_for(:setup_deploy, opts), do: if(opts[:wait_for_build], do: 14, else: 11)
  defp step_for(:attach_lb, opts), do: if(opts[:wait_for_build], do: 15, else: 12)

  defp run_qa_pipeline_work(tui_pid, app_name, sha, opts) do
    total_steps = pipeline_total_steps(opts)
    umbrella_root = File.cwd!()

    progress = fn key, label ->
      DeployEx.TUI.Progress.update_progress(tui_pid, step_for(key, opts) / total_steps, label)
    end

    with :ok <- (progress.(:validate_app, "Validating app name..."); validate_app_name(app_name)),
         {:ok, full_sha} <- (progress.(:validate_sha, "Validating SHA..."); validate_and_find_sha(app_name, sha, opts)),
         {:ok, plan} <- (progress.(:plan_rewrite, "Planning host config rewrite (LLM)..."); maybe_plan_host_rewrite(app_name, opts)),
         {:ok, accepted} <- (progress.(:review_proposals, "Confirming target files..."); maybe_review_proposals(plan, tui_pid)),
         {:ok, build_state} <- (maybe_progress_preflight(progress, opts); validate_wait_for_build_preconditions(opts, umbrella_root, app_name, opts[:wait_for_build] || false)),
         {:ok, infra} <- (progress.(:gather_infra, "Gathering infrastructure..."); gather_infrastructure(app_name, opts)),
         {:ok, qa_node} <- (progress.(:create_node, "Creating QA node..."); create_qa_node(app_name, full_sha, infra, opts)),
         :ok <- (progress.(:wait_instance, "Waiting for instance to start..."); wait_for_instance(qa_node, opts)),
         {:ok, qa_node} <- (progress.(:save_state, "Saving QA state..."); save_and_refresh_state(qa_node, opts)),
         {:ok, entries} <- (progress.(:apply_rewrite, "Applying host config rewrite..."); maybe_apply_proposals(qa_node, plan, accepted)),
         {:ok, entries} <- maybe_install_qa_deploy_action(umbrella_root, build_state, entries, opts, tui_pid),
         {:ok, qa_node} <- (maybe_progress_commit_push(progress, opts); commit_and_push_rewrites(qa_node, build_state, entries, opts[:wait_for_build] || false, tui_pid)),
         :ok <- (maybe_progress_wait_build(progress, opts); wait_for_build_step(qa_node, build_state, opts, tui_pid)),
         :ok <- (progress.(:wait_ssh, "Waiting for SSH..."); wait_for_ssh_ready(qa_node, tui_pid)),
         :ok <- (progress.(:setup_deploy, "Running setup & deploy..."); run_setup_and_deploy(qa_node, infra, tui_pid, opts)),
         {:ok, qa_node} <- (progress.(:attach_lb, "Attaching load balancer..."); maybe_attach_lb(qa_node, opts)) do
      {:ok, qa_node}
    end
  end

  defp maybe_progress_preflight(progress, opts) do
    if opts[:wait_for_build] do
      progress.(:preflight_build, "Validating wait-for-build preconditions...")
    else
      :ok
    end
  end

  defp run_setup_and_deploy(qa_node, infra, tui_pid, opts) do
    maybe_run_setup(qa_node, infra, tui_pid, opts)
    maybe_wait_for_deploy(qa_node, infra, tui_pid, opts)
  end

  defp maybe_plan_host_rewrite(app_name, opts) do
    if host_rewrite_will_run?(opts) do
      umbrella_root = File.cwd!()
      module_prefix = DeployEx.ProjectContext.module_prefix_or_camelize(app_name)

      with {:ok, candidates} <- DeployEx.QaHostRewrite.scan_candidates(umbrella_root, app_name, module_prefix),
           {:ok, proposals} <- DeployEx.QaHostRewrite.propose_rewrite(candidates, app_name, module_prefix) do
        {:ok, %{proposals: proposals, app_name: app_name, module_prefix: module_prefix}}
      end
    else
      {:ok, :skip}
    end
  end

  defp maybe_review_proposals(:skip, _tui_pid), do: {:ok, :skip}
  defp maybe_review_proposals(%{proposals: []}, _tui_pid), do: {:ok, []}

  defp maybe_review_proposals(%{proposals: proposals, module_prefix: module_prefix}, tui_pid) do
    DeployEx.QaHostRewrite.review_proposals(proposals, module_prefix, tui_pid)
  end

  defp maybe_apply_proposals(_qa_node, :skip, _accepted), do: {:ok, []}
  defp maybe_apply_proposals(_qa_node, _plan, :skip), do: {:ok, []}
  defp maybe_apply_proposals(_qa_node, _plan, []), do: {:ok, []}

  defp maybe_apply_proposals(qa_node, %{app_name: app_name}, accepted) do
    backup_dir = DeployEx.QaHostRewrite.backup_dir(app_name, qa_node.instance_id)
    DeployEx.QaHostRewrite.apply_proposals(accepted, qa_node.public_ip, backup_dir)
  end

  defp maybe_install_qa_deploy_action(umbrella_root, build_state, entries, opts, tui_pid) do
    cond do
      not (opts[:wait_for_build] || false) -> {:ok, entries}
      opts[:skip_action_install] === true -> {:ok, entries}
      build_state[:enabled?] !== true -> {:ok, entries}
      true -> install_qa_deploy_action(umbrella_root, build_state, entries, tui_pid)
    end
  end

  defp install_qa_deploy_action(umbrella_root, %{workflow: %{file: file}}, entries, tui_pid) do
    workflow_path = Path.join([umbrella_root, ".github/workflows", file])

    case DeployEx.GitHubActions.QaDeployStepInstaller.install(workflow_path) do
      {:ok, %{qa_step: :inserted}} = ok ->
        log_action_install_status(tui_pid, ok, workflow_path)
        {:ok, append_workflow_entry(entries, workflow_path)}

      {:ok, %{qa_step: :already_installed}} = ok ->
        log_action_install_status(tui_pid, ok, workflow_path)
        {:ok, entries}

      {:error, _} = error ->
        error
    end
  end

  defp log_action_install_status(tui_pid, {:ok, %{qa_step: status}}, workflow_path) when is_pid(tui_pid) do
    DeployEx.TUI.Progress.update_log(tui_pid, "  QA deploy step #{status}: #{workflow_path}")
  end

  defp log_action_install_status(_tui_pid, {:ok, %{qa_step: status}}, workflow_path) do
    Mix.shell().info([:faint, "QA deploy step #{status}: #{workflow_path}"])
  end

  defp append_workflow_entry(entries, workflow_path) do
    relative = Path.relative_to(workflow_path, File.cwd!())
    entries ++ [%{path: relative}]
  end

  defp maybe_progress_commit_push(progress, opts) do
    if opts[:wait_for_build] do
      progress.(:commit_push, "Committing & pushing QA branch...")
    else
      :ok
    end
  end

  defp commit_and_push_rewrites(qa_node, _build_state, _entries, false, _tui_pid), do: {:ok, qa_node}

  defp commit_and_push_rewrites(qa_node, build_state, entries, true, _tui_pid) do
    {action, branch} = build_state.branch_resolution
    files = Enum.map(entries, &(&1.path))
    short = String.slice(qa_node.target_sha || "", 0, 7)
    message = "qa: rewrite host config for #{qa_node.app_name} (#{short})"
    base_sha = if action === :create_new, do: qa_node.target_sha, else: nil

    case DeployEx.GitOperations.commit_and_push(umbrella_root(), branch, files, message,
           create_new?: action === :create_new,
           base_sha: base_sha
         ) do
      {:ok, new_sha} -> {:ok, %{qa_node | target_sha: new_sha}}
      {:error, _} = error -> error
    end
  end

  defp umbrella_root, do: File.cwd!()

  defp maybe_progress_wait_build(progress, opts) do
    if opts[:wait_for_build] do
      progress.(:wait_build, "Waiting for build workflow...")
    else
      :ok
    end
  end

  defp wait_for_build_step(qa_node, build_state, opts, tui_pid) do
    case wait_for_build(qa_node, build_state, opts[:wait_for_build] || false, opts, tui_pid) do
      {:ok, :skipped} ->
        :ok

      {:ok, _run_id} ->
        DeployEx.TUI.Progress.update_log(tui_pid, "  Build succeeded.")
        :ok

      {:error, reason} ->
        handle_build_failure(qa_node, build_state, reason, opts, tui_pid)
    end
  end

  defp wait_for_build(_qa_node, _build_state, false, _opts, _tui_pid), do: {:ok, :skipped}

  defp wait_for_build(qa_node, build_state, true, opts, tui_pid) do
    {_action, branch} = build_state.branch_resolution
    %{file: workflow_file, job_id: job_id} = build_state.workflow

    log_fn = fn line -> DeployEx.TUI.Progress.update_log(tui_pid, "  " <> line) end
    timeout_ms = (opts[:build_timeout] || 30) * 60 * 1_000

    with {:ok, run_id} <- DeployEx.GitHubActions.find_run_id(branch, qa_node.target_sha, workflow_file),
         {:ok, _run} <-
           DeployEx.GitHubActions.wait_for_run(run_id, job_id,
             log_fn: log_fn,
             timeout_ms: timeout_ms
           ) do
      {:ok, run_id}
    else
      {:error, reason} ->
        {:error, %{reason: reason, run_id: find_known_run_id(branch, qa_node.target_sha, workflow_file)}}
    end
  end

  defp find_known_run_id(branch, sha, workflow_file) do
    case DeployEx.GitHubActions.find_run_id(branch, sha, workflow_file, retry_max: 1) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp handle_build_failure(qa_node, build_state, %{reason: reason, run_id: run_id}, opts, tui_pid) do
    workflow_url = build_workflow_url(run_id)
    preamble = "Build failed (#{inspect(reason)})\nWorkflow run: #{workflow_url}\n\n"

    destroy? = DeployEx.TUI.Progress.confirm(tui_pid, preamble <> "Destroy the QA node?") === :yes
    revert? = DeployEx.TUI.Progress.confirm(tui_pid, "Revert local + remote SSL/host rewrites?") === :yes

    apply_failure_choices(destroy?, revert?, qa_node, build_state, opts)
    System.halt(1)
  end

  defp apply_failure_choices(destroy?, revert?, qa_node, build_state, opts) do
    if revert?, do: revert_pushed_changes(qa_node, build_state, opts)
    if destroy?, do: DeployEx.QaNode.terminate_qa_node(qa_node, opts)
    :ok
  end

  defp revert_pushed_changes(qa_node, %{branch_resolution: {action, branch}}, opts) do
    backup_dir = DeployEx.QaHostRewrite.backup_dir(qa_node.app_name, qa_node.instance_id)
    DeployEx.QaHostRewrite.restore(backup_dir, opts)

    case action do
      :create_new -> DeployEx.GitOperations.delete_remote_branch(umbrella_root(), branch)
      :reuse_current -> DeployEx.GitOperations.revert_and_push(umbrella_root())
    end
  end

  defp build_workflow_url(run_id) when is_integer(run_id) do
    case github_repo_slug() do
      slug when is_binary(slug) -> "https://github.com/#{slug}/actions/runs/#{run_id}"
      _ -> "(workflow run URL unavailable)"
    end
  end

  defp build_workflow_url(_run_id), do: "(workflow run URL unavailable)"

  defp github_repo_slug do
    case DeployEx.Utils.run_command_with_return("gh repo view --json nameWithOwner --jq .nameWithOwner", umbrella_root()) do
      {:ok, slug} -> String.trim(slug)
      _ -> nil
    end
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
        no_tui: :boolean,
        wait_for_build: :boolean,
        build_workflow: :string,
        build_job: :string,
        build_timeout: :integer,
        skip_action_install: :boolean
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

  defp wait_for_ssh_ready(qa_node, tui_pid) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:faint, "Waiting for SSH to be ready on ", :reset, :cyan, qa_node.public_ip, :reset, :faint, "..."])
    end

    wait_for_ssh(qa_node.public_ip, tui_pid)
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

  defp maybe_run_setup(%{use_public_ip_cert?: true} = qa_node, _infra, tui_pid, opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([
        :cyan,
        "Running Ansible setup for ",
        :bright,
        qa_node.instance_name,
        :reset,
        " — required by --public-ip-cert (provisions Let's Encrypt cert)..."
      ])
    end

    run_ansible_setup(qa_node, tui_pid, opts)
  end

  defp maybe_run_setup(_qa_node, %{using_app_ami: true}, _tui_pid, _opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:green, "  ✓ ", :reset, "Skipping setup (using pre-configured AMI)"])
    end

    :ok
  end

  defp maybe_run_setup(qa_node, _infra, tui_pid, opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:cyan, "Running Ansible setup for ", :bright, qa_node.instance_name, :reset, "..."])
    end

    run_ansible_setup(qa_node, tui_pid, opts)
  end

  @ssh_max_attempts 24
  @ssh_retry_sleep_ms 5_000
  @ssh_probe_timeout_s "3"

  defp wait_for_ssh(ip, tui_pid, attempt \\ 1) do
    log_ssh_attempt(tui_pid, ip, attempt)

    case System.cmd("nc", ["-z", "-w", @ssh_probe_timeout_s, ip, "22"], stderr_to_stdout: true) do
      {_, 0} ->
        log_ssh_ready(tui_pid, ip)
        :ok

      _ when attempt < @ssh_max_attempts ->
        Process.sleep(@ssh_retry_sleep_ms)
        wait_for_ssh(ip, tui_pid, attempt + 1)

      _ ->
        {:error,
         ErrorMessage.failed_dependency(
           "SSH did not open on #{ip}:22 after #{@ssh_max_attempts} attempts (~#{div(@ssh_max_attempts * @ssh_retry_sleep_ms, 1000)}s). Check the security group allows port 22 from your IP.",
           %{ip: ip, attempts: @ssh_max_attempts}
         )}
    end
  end

  defp log_ssh_attempt(tui_pid, ip, attempt) when is_pid(tui_pid) do
    DeployEx.TUI.Progress.update_log(
      tui_pid,
      "  ssh probe #{attempt}/#{@ssh_max_attempts} → #{ip}:22"
    )
  end

  defp log_ssh_attempt(_tui_pid, _ip, _attempt), do: :ok

  defp log_ssh_ready(tui_pid, ip) when is_pid(tui_pid) do
    DeployEx.TUI.Progress.update_log(tui_pid, "  ✓ SSH ready on #{ip}:22")
  end

  defp log_ssh_ready(_tui_pid, _ip), do: :ok

  defp maybe_wait_for_deploy(_qa_node, _infra, _tui_pid, %{skip_deploy: true}), do: :ok
  defp maybe_wait_for_deploy(qa_node, %{using_app_ami: true}, tui_pid, _opts) do
    if not DeployEx.TUI.enabled?() do
      Mix.shell().info([:faint, "Waiting for cloud-init to deploy release..."])
    end

    case wait_for_ssh(qa_node.public_ip, tui_pid) do
      :ok ->
        if not DeployEx.TUI.enabled?() do
          Mix.shell().info([:green, "  ✓ ", :reset, "Release deployed via cloud-init"])
        end

        :ok

      {:error, _} = error ->
        error
    end
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

  defp setup_vars(%{use_public_ip_cert?: true}), do: [letsencrypt_use_public_ip: true]
  defp setup_vars(_qa_node), do: []

  defp deploy_vars(%{use_public_ip_cert?: true}, sha),
    do: [target_release_sha: sha, letsencrypt_use_public_ip: true]
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
