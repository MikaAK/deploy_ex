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

  ## CI build flow (default)

  By default, qa.create commits + pushes the SSL/host rewrites and waits for
  GitHub Actions to build the release artifact before deploying. Pass
  `--use-local-build` to opt out and use a locally-built release instead.

      mix deploy_ex.qa.create cfx_web --public-ip-cert --tag canary
      mix deploy_ex.qa.create cfx_web --use-local-build           # local build path

  Detection: scans `.github/workflows/*.yml` for the workflow whose `on.push.branches`
  matches the QA branch and whose jobs (or sub-workflow jobs) run `mix deploy_ex.release`.
  Hard-errors when no workflow matches; pass `--use-local-build` if you don't have one.

  Branch resolution: if the current branch matches `^qa[\/-]` it is reused; otherwise
  derives `qa/<app>-<tag>` (or `qa/<app>-<short_sha>` if `--tag` is omitted).

  ### Auto-installed QA deploy step

  In the default (CI build) flow, qa.create idempotently patches the detected
  workflow so the build job ends with a `Deploy to QA Node` step that runs
  `mix deploy_ex.qa.deploy --git-branch <branch>` for QA refs. The existing
  `Run Ansible Deploy` step is guarded so it skips on QA branches. The patch is
  marked with sentinel comments (`# deploy_ex:qa-deploy:*`) and is a no-op on
  subsequent runs. Pass `--skip-action-install` to opt out of just the patch.

  After commit + push the local task does NOT wait for the CI build to finish.
  It runs Ansible setup against the new node (so Let's Encrypt provisioning and
  any one-time setup happen synchronously) and then hands off — the CI runner
  builds + uploads the release and the patched `Deploy to QA Node` step
  triggers `mix deploy_ex.qa.deploy` on the runner once the build completes.
  Pass `--use-local-build` if you want the legacy synchronous local build +
  ansible deploy instead.

  ### Deploy strategy

  When CI flow is active and `--sha` is not passed, qa.create prompts up-front
  for the deploy strategy:

    * **push current working tree** (default — Y) — uses HEAD as the deploy
      target, skips the S3 release lookup, and lets CI build + deploy the
      pushed qa branch.
    * **pre-built SHA** (n) — picks an existing release from S3 the legacy way
      via `DeployEx.ReleaseLookup`. Also implicit when you pass `--sha` or
      `--use-local-build`.

  `--quiet` / `--no-tui` skip the prompt and default to `:push_head`.

  Options:
    --use-local-build         Build + deploy locally instead of handing off to CI
    --build-workflow=<file>   Override workflow auto-detection
    --build-job=<job_id>      Override job auto-detection within the workflow
    --skip-action-install     Skip the workflow yml patch that installs the QA-deploy step

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

      opts = Keyword.put(opts, :deploy_strategy, decide_deploy_strategy(opts))

      if DeployEx.TUI.enabled?() do
        run_pipeline_tui(extra_args, opts)
      else
        run_pipeline_console(extra_args, opts)
      end
    end
  end

  defp decide_deploy_strategy(opts) do
    cond do
      is_binary(opts[:sha]) -> :pre_built_sha
      not ci_build_enabled?(opts) -> :pre_built_sha
      opts[:quiet] === true -> :push_head
      opts[:no_tui] === true -> :push_head
      true -> prompt_deploy_strategy()
    end
  end

  defp prompt_deploy_strategy do
    Mix.shell().info([
      :reset,
      :bright,
      "\nHow do you want to deploy?\n",
      :reset,
      "  ",
      :green,
      "1",
      :reset,
      ") Push current working tree — CI builds the release and deploys it via GitHub Actions ",
      :faint,
      "(default)\n",
      :reset,
      "  ",
      :green,
      "2",
      :reset,
      ") Deploy a specific pre-built SHA — pick an existing release from S3\n"
    ])

    raw = "Choice [1]: " |> Mix.shell().prompt() |> String.trim() |> String.downcase()

    case raw do
      "" -> :push_head
      "1" -> :push_head
      "y" -> :push_head
      "yes" -> :push_head
      "2" -> :pre_built_sha
      "n" -> :pre_built_sha
      "no" -> :pre_built_sha
      other -> retry_prompt_deploy_strategy(other)
    end
  end

  defp retry_prompt_deploy_strategy(invalid) do
    Mix.shell().error("  Unrecognized answer #{inspect(invalid)} — please enter 1 or 2.")
    prompt_deploy_strategy()
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

  defp ci_build_enabled?(opts), do: not (opts[:use_local_build] || false)

  defp validate_ci_build_preconditions(_opts, _umbrella_root, _app_name, false), do: {:ok, %{enabled?: false}}

  defp validate_ci_build_preconditions(opts, umbrella_root, app_name, true) do
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
        workflows_root
        |> DeployEx.GitHubActions.find_build_workflow(branch)
        |> hint_use_local_build_on_not_found()
    end
  end

  defp hint_use_local_build_on_not_found({:error, %ErrorMessage{code: :not_found} = err}) do
    hinted =
      err.message <>
        "\n\nPass --use-local-build if you don't have a CI workflow that runs mix deploy_ex.release for QA branches."

    {:error, %{err | message: hinted}}
  end

  defp hint_use_local_build_on_not_found(result), do: result

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
    tag_part = if opts[:tag], do: " — tag #{opts[:tag]}", else: ""

    descriptor =
      case opts[:deploy_strategy] do
        :push_head -> "CI build from HEAD #{String.slice(sha, 0, 7)}"
        _ -> "SHA #{String.slice(sha, 0, 7)}"
      end

    "QA Node: #{app_name} (#{descriptor}#{tag_part})"
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
    cond do
      is_binary(opts[:sha]) ->
        {:ok, opts[:sha]}

      opts[:deploy_strategy] === :push_head ->
        {:ok, head_sha(File.cwd!())}

      true ->
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

  @pipeline_total_steps_local 12
  @pipeline_total_steps_ci 14

  defp pipeline_total_steps(opts) do
    if ci_build_enabled?(opts), do: @pipeline_total_steps_ci, else: @pipeline_total_steps_local
  end

  defp step_for(:validate_app, _opts), do: 1
  defp step_for(:validate_sha, _opts), do: 2
  defp step_for(:plan_rewrite, _opts), do: 3
  defp step_for(:review_proposals, _opts), do: 4
  defp step_for(:preflight_build, _opts), do: 5
  defp step_for(:gather_infra, opts), do: if(ci_build_enabled?(opts), do: 6, else: 5)
  defp step_for(:create_node, opts), do: if(ci_build_enabled?(opts), do: 7, else: 6)
  defp step_for(:wait_instance, opts), do: if(ci_build_enabled?(opts), do: 8, else: 7)
  defp step_for(:save_state, opts), do: if(ci_build_enabled?(opts), do: 9, else: 8)
  defp step_for(:apply_rewrite, opts), do: if(ci_build_enabled?(opts), do: 10, else: 9)
  defp step_for(:commit_push, _opts), do: 11
  defp step_for(:wait_ssh, opts), do: if(ci_build_enabled?(opts), do: 12, else: 10)
  defp step_for(:setup_deploy, opts), do: if(ci_build_enabled?(opts), do: 13, else: 11)
  defp step_for(:attach_lb, opts), do: if(ci_build_enabled?(opts), do: 14, else: 12)

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
         {:ok, build_state} <- (maybe_progress_preflight(progress, opts); validate_ci_build_preconditions(opts, umbrella_root, app_name, ci_build_enabled?(opts))),
         {:ok, infra} <- (progress.(:gather_infra, "Gathering infrastructure..."); gather_infrastructure(app_name, opts)),
         {:ok, qa_node} <- (progress.(:create_node, "Creating QA node..."); create_qa_node(app_name, full_sha, infra, opts)),
         :ok <- (progress.(:wait_instance, "Waiting for instance to start..."); wait_for_instance(qa_node, opts)),
         {:ok, qa_node} <- (progress.(:save_state, "Saving QA state..."); save_and_refresh_state(qa_node, opts)),
         {:ok, entries} <- (progress.(:apply_rewrite, "Applying host config rewrite..."); maybe_apply_proposals(qa_node, plan, accepted)),
         {:ok, entries} <- maybe_install_qa_deploy_action(umbrella_root, build_state, entries, opts, tui_pid),
         {:ok, qa_node} <- (maybe_progress_commit_push(progress, opts); commit_and_push_rewrites(qa_node, build_state, entries, ci_build_enabled?(opts), tui_pid)),
         :ok <- (progress.(:wait_ssh, "Waiting for SSH..."); wait_for_ssh_ready(qa_node, tui_pid)),
         :ok <- (progress.(:setup_deploy, "Running setup & deploy..."); run_setup_and_deploy(qa_node, infra, tui_pid, opts)),
         {:ok, qa_node} <- (progress.(:attach_lb, "Attaching load balancer..."); maybe_attach_lb(qa_node, opts)) do
      {:ok, qa_node}
    end
  end

  defp maybe_progress_preflight(progress, opts) do
    if ci_build_enabled?(opts) do
      progress.(:preflight_build, "Validating CI build preconditions...")
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
      not ci_build_enabled?(opts) -> {:ok, entries}
      opts[:skip_action_install] === true -> {:ok, entries}
      build_state[:enabled?] !== true -> {:ok, entries}
      true -> install_qa_deploy_action(umbrella_root, build_state, entries, tui_pid)
    end
  end

  defp install_qa_deploy_action(umbrella_root, %{workflow: workflow}, entries, tui_pid) do
    file = Map.get(workflow, :steps_file, workflow.file)
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
    if ci_build_enabled?(opts) do
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
        use_local_build: :boolean,
        build_workflow: :string,
        build_job: :string,
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
    if opts[:deploy_strategy] === :push_head do
      {:ok, sha}
    else
      validate_sha_against_s3(app_name, sha, opts)
    end
  end

  defp validate_sha_against_s3(app_name, sha, opts) do
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
    cond do
      is_binary(opts[:sha]) ->
        {:ok, opts[:sha]}

      opts[:deploy_strategy] === :push_head ->
        {:ok, head_sha(File.cwd!())}

      true ->
        lookup_opts = [
          aws_region: opts[:aws_region] || DeployEx.Config.aws_region(),
          aws_release_bucket: opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket()
        ]

        DeployEx.ReleaseLookup.resolve_sha_any(app_name, [:qa, :prod], :prompt, lookup_opts)
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
    if ci_build_enabled?(opts) do
      log_ci_deploy_handoff(qa_node, tui_pid)
      :ok
    else
      if not DeployEx.TUI.enabled?() do
        Mix.shell().info([:cyan, "Deploying SHA ", :yellow, String.slice(qa_node.target_sha, 0, 7), :reset, :cyan, " to ", :bright, qa_node.instance_name, :reset, "..."])
      end

      run_ansible_deploy(qa_node, qa_node.target_sha, tui_pid, opts)
    end
  end

  defp log_ci_deploy_handoff(qa_node, tui_pid) when is_pid(tui_pid) do
    DeployEx.TUI.Progress.update_log(
      tui_pid,
      "  Deploy will run on CI runner once the build completes (#{qa_node.instance_name})"
    )
  end

  defp log_ci_deploy_handoff(qa_node, _tui_pid) do
    Mix.shell().info([
      :faint,
      "Deploy will run on CI runner once the build completes for ",
      :bright,
      qa_node.instance_name,
      :reset
    ])
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

  defp output_success(qa_node, opts) do
    Mix.shell().info([
      :green,
      "\n✓ QA node created successfully!\n",
      :reset,
      "\n",
      "  Steps completed:\n",
      format_pipeline_summary(opts),
      "\n",
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
      format_ci_handoff_note(opts),
      "  SSH: ", :yellow, "ssh admin@#{qa_node.public_ip || qa_node.ipv6_address}", :reset, "\n"
    ])
  end

  defp format_pipeline_summary(opts) do
    opts
    |> pipeline_step_labels()
    |> Enum.map(fn label -> ["    ", :green, "✓ ", :reset, label, "\n"] end)
  end

  defp format_ci_handoff_note(opts) do
    if ci_build_enabled?(opts) and opts[:deploy_strategy] === :push_head do
      [
        :faint,
        "  Deploy will run on the CI runner once the build completes — watch GitHub Actions.\n\n",
        :reset
      ]
    else
      []
    end
  end

  defp pipeline_step_labels(opts) do
    ci_build? = ci_build_enabled?(opts)
    host_rewrite? = host_rewrite_will_run?(opts)
    local_deploy? = not ci_build?

    [
      {true, "Validate app name"},
      {true, "Resolve target SHA"},
      {host_rewrite?, "Plan host config rewrite (LLM)"},
      {host_rewrite?, "Confirm target files"},
      {ci_build?, "Validate CI build preconditions"},
      {true, "Gather infrastructure"},
      {true, "Create QA node"},
      {true, "Wait for instance to start"},
      {true, "Save QA state"},
      {host_rewrite?, "Apply host config rewrite"},
      {ci_build?, "Install QA-deploy GitHub Actions step"},
      {ci_build?, "Commit + push QA branch (kicks off CI build)"},
      {true, "Wait for SSH"},
      {true, "Run Ansible setup"},
      {local_deploy?, "Run Ansible deploy"},
      {ci_build?, "Hand off deploy to CI runner"},
      {opts[:attach_lb] === true, "Attach load balancer"}
    ]
    |> Enum.filter(fn {include?, _label} -> include? end)
    |> Enum.map(fn {_include?, label} -> label end)
  end
end
