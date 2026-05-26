defmodule Mix.Tasks.DeployEx.Qa.Deploy do
  use Mix.Task

  @shortdoc "Deploys a specific SHA to an existing QA node"
  @moduledoc """
  Deploys a specific SHA to an existing QA node.

  ## Example
  ```bash
  mix deploy_ex.qa.deploy my_app --sha def5678
  mix deploy_ex.qa.deploy my_app --sha def5678 --instance-id i-0abc123
  mix deploy_ex.qa.deploy my_app --sha def5678 --git-branch qa/my_app-canary
  mix deploy_ex.qa.deploy my_app --sha def5678 --public-ip-cert       # enable cert mode
  mix deploy_ex.qa.deploy my_app --sha def5678 --no-public-ip-cert    # disable cert mode
  ```

  ## Options
  - `--sha, -s` - Target git SHA (required)
  - `--instance-id, -i` - Target a specific QA instance when multiple exist
  - `--git-branch` - Auto-select the QA node whose `git_branch` matches. Required
    for non-interactive use (GitHub Actions); errors with `:conflict` when more
    than one node shares the branch.
  - `--public-ip-cert` / `--no-public-ip-cert` - Toggle public-IP Let's Encrypt cert
    mode before the deploy. Updates the `UsePublicIpCert` EC2 tag and S3 state so
    ansible picks up the new mode on this run and every subsequent one. Omit the
    flag entirely to leave the current mode unchanged.
  - `--quiet, -q` - Suppress output messages
  - `--aws-region` - AWS region (default: from config)
  - `--aws-release-bucket` - S3 bucket for releases (default: from config)
  """

  @ansible_default_path DeployEx.Config.ansible_folder_path()

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project(),
         :ok <- DeployEx.ToolInstaller.ensure_installed(:ansible) do
      {opts, extra_args} = parse_args(args)
      DeployEx.TUI.setup_no_tui(opts)

      if DeployEx.TUI.enabled?() do
        run_unified_flow(extra_args, opts)
      else
        run_console_flow(extra_args, opts)
      end
    end
  end

  defp run_console_flow([name | _], opts) do
    sha = require_sha(opts)

    name
    |> deploy_single_app(sha, opts)
    |> handle_final_result(opts)
  end

  defp run_console_flow([], opts) do
    case opts[:git_branch] do
      branch when is_binary(branch) and branch !== "" ->
        run_branch_fanout(branch, opts)

      _ ->
        Mix.raise(
          "app name or --git-branch is required (so the target release can be resolved from the QA node)"
        )
    end
  end

  defp deploy_single_app(app_name, sha, opts) do
    DeployEx.TUI.Progress.run_stream(
      stream_title(app_name, sha),
      fn tui_pid -> run_deploy_pipeline(tui_pid, app_name, sha, opts, 5) end
    )
  end

  defp run_branch_fanout(branch, opts) do
    sha = require_sha(opts)

    with {:ok, nodes} <- DeployEx.QaNode.find_qa_nodes_by_branch(branch, opts),
         {:ok, targets} <- filter_branch_targets(nodes, branch, opts) do
      targets
      |> Enum.map(fn node -> deploy_branch_target(node, sha, opts) end)
      |> handle_branch_fanout_results(opts)
    else
      {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
    end
  end

  defp filter_branch_targets([], branch, _opts) do
    {:error,
     ErrorMessage.not_found(
       "no QA node found on branch #{branch} — create one with mix deploy_ex.qa.create"
     )}
  end

  defp filter_branch_targets(nodes, branch, opts) do
    if opts[:only_local_release] do
      apply_local_release_filter(nodes, branch)
    else
      {:ok, nodes}
    end
  end

  defp apply_local_release_filter(nodes, branch) do
    local_apps = DeployEx.ReleaseUploader.local_release_app_names()
    {kept, skipped} = Enum.split_with(nodes, &(&1.app_name in local_apps))

    Enum.each(skipped, fn node ->
      Mix.shell().info([
        :yellow,
        "  ⚠ skipping #{node.app_name} (no local release)",
        :reset
      ])
    end)

    case kept do
      [] ->
        {:error,
         ErrorMessage.not_found(
           "no QA nodes on branch #{branch} match locally-built releases",
           %{branch: branch, local_apps: local_apps, node_apps: Enum.map(nodes, & &1.app_name)}
         )}

      _ ->
        {:ok, kept}
    end
  end

  defp deploy_branch_target(node, sha, opts) do
    title = stream_title(node.app_name, sha)
    work_fn = fn tui_pid -> run_branch_target_pipeline(tui_pid, node, sha, opts) end
    {node, DeployEx.TUI.Progress.run_stream(title, work_fn)}
  end

  defp run_branch_target_pipeline(tui_pid, node, sha, opts) do
    progress = fn step, label ->
      DeployEx.TUI.Progress.update_progress(tui_pid, step / 4, label)
    end

    with {:ok, verified} <- (progress.(1, "Verifying QA instance..."); DeployEx.QaNode.verify_instance_exists(node)),
         {:ok, full_sha} <- (progress.(2, "Validating SHA..."); validate_and_find_sha(verified.app_name, sha, opts)),
         :ok <- (progress.(3, "Running ansible deploy..."); run_ansible_deploy(verified, full_sha, tui_pid, opts)),
         {:ok, updated} <- (progress.(4, "Updating QA state..."); update_qa_state(verified, full_sha, opts)) do
      {:ok, {updated, full_sha}}
    end
  end

  defp handle_branch_fanout_results(results, opts) do
    {successes, failures} =
      Enum.split_with(results, fn {_node, result} -> match?({:ok, _}, result) end)

    print_fanout_summary(successes, failures, opts)

    case failures do
      [] -> :ok
      _ -> Mix.raise("#{length(failures)} of #{length(results)} QA deploys failed")
    end
  end

  defp print_fanout_summary(successes, [], opts) do
    unless opts[:quiet] do
      Mix.shell().info(IO.ANSI.format([:green, "\n✓ Deployed all QA nodes for branch", :reset], true))
      Enum.each(successes, &print_success_line/1)
    end
  end

  defp print_fanout_summary(successes, failures, _opts) do
    Enum.each(successes, &print_success_line/1)
    Enum.each(failures, &print_failure_line/1)
  end

  defp print_success_line({_node, {:ok, {qa_node, full_sha}}}) do
    Mix.shell().info(
      IO.ANSI.format(
        [
          :green,
          "  • #{qa_node.app_name} (#{qa_node.instance_name}) → ",
          :cyan,
          String.slice(full_sha, 0, 7),
          :reset
        ],
        true
      )
    )
  end

  defp print_failure_line({node, {:error, error}}) do
    Mix.shell().error("✗ #{node.app_name} (#{node.instance_id}): #{ErrorMessage.to_string(error)}")
  end

  defp require_sha(opts) do
    opts[:sha] ||
      Mix.raise("--sha option is required (or run interactively without --no-tui)")
  end

  defp run_unified_flow(extra_args, opts) do
    {final_result, log_tail} =
      DeployEx.TUI.run(fn terminal ->
        with {:ok, app_name} <- resolve_app_in_terminal(extra_args, terminal),
             {:ok, qa_node} <- resolve_qa_node_in_terminal(terminal, app_name, opts),
             {:ok, sha} <- resolve_sha_in_terminal(terminal, app_name, opts),
             {:ok, full_sha} <- validate_and_find_sha(app_name, sha, opts) do
          title = stream_title(app_name, full_sha)
          work_fn = fn tui_pid ->
            run_resolved_deploy_pipeline(tui_pid, qa_node, full_sha, opts)
          end

          DeployEx.TUI.Progress.stream_in_terminal(terminal, title, work_fn, opts)
        else
          {:error, _} = err -> {err, []}
        end
      end)

    DeployEx.TUI.Progress.print_log_tail_on_error(final_result, log_tail)
    handle_final_result(final_result, opts)
  end

  defp handle_final_result({:ok, {qa_node, full_sha}}, opts) do
    unless opts[:quiet] do
      Mix.shell().info([
        :green, "\n✓ Deployed SHA ", :cyan, String.slice(full_sha, 0, 7),
        :green, " (branch ", :cyan, qa_node.git_branch || "—",
        :green, ") to QA node ", :cyan, qa_node.instance_name, :reset
      ])
    end
  end
  defp handle_final_result({:error, error}, _opts), do: Mix.raise(ErrorMessage.to_string(error))

  defp stream_title(app_name, sha), do: "QA Deploy: #{app_name} (SHA #{String.slice(sha, 0, 7)})"

  defp resolve_app_in_terminal([name | _], _terminal), do: {:ok, name}
  defp resolve_app_in_terminal([], terminal) do
    case DeployEx.QaNode.list_all_qa_states() do
      {:ok, []} ->
        {:error, ErrorMessage.not_found("no QA nodes found — create one with mix deploy_ex.qa.create")}

      {:ok, app_names} ->
        pick_app_in_terminal(terminal, app_names)

      {:error, _} = error ->
        error
    end
  end

  defp pick_app_in_terminal(terminal, app_names) do
    sorted = Enum.sort(app_names)

    case DeployEx.TUI.Select.run_in_terminal(terminal, sorted,
           title: "Select app to deploy to",
           allow_all: false,
           always_prompt: true
         ) do
      [chosen] -> {:ok, chosen}
      [] -> {:error, ErrorMessage.bad_request("no app selected")}
    end
  end

  defp resolve_qa_node_in_terminal(terminal, app_name, opts) do
    with {:ok, nodes} <- DeployEx.QaNode.find_qa_nodes_for_app(app_name, opts),
         {:ok, chosen} <- choose_node_in_terminal(terminal, nodes, app_name, opts) do
      DeployEx.QaNode.verify_instance_exists(chosen)
    end
  end

  defp choose_node_in_terminal(_terminal, [], app_name, _opts) do
    {:error, ErrorMessage.not_found("no QA node found for app '#{app_name}'")}
  end

  defp choose_node_in_terminal(terminal, nodes, app_name, opts) do
    cond do
      opts[:instance_id] -> find_node_by_instance_id(nodes, opts[:instance_id], app_name)
      opts[:git_branch] -> DeployEx.QaNode.select_by_branch(nodes, opts[:git_branch])
      true -> pick_node_in_terminal(terminal, nodes)
    end
  end

  defp pick_node_in_terminal(terminal, nodes) do
    case DeployEx.QaNode.pick_interactive_in_terminal(terminal, nodes,
           title: "Select QA node to deploy to",
           allow_all: false,
           always_prompt: true
         ) do
      {:ok, [picked]} -> {:ok, picked}
      {:ok, []} -> {:error, ErrorMessage.bad_request("no QA node selected")}
    end
  end

  defp find_node_by_instance_id(nodes, instance_id, app_name) do
    case Enum.find(nodes, &(&1.instance_id === instance_id)) do
      nil ->
        {:error,
         ErrorMessage.not_found(
           "no QA node matching --instance-id #{instance_id} for app '#{app_name}'",
           %{available_ids: Enum.map(nodes, & &1.instance_id)}
         )}

      node ->
        {:ok, node}
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

  defp run_deploy_pipeline(tui_pid, app_name, sha, opts, total) do
    progress = fn step, label ->
      DeployEx.TUI.Progress.update_progress(tui_pid, step / total, label)
    end

    with {:ok, qa_node} <- (progress.(1, "Fetching QA node..."); fetch_and_verify_qa_node(app_name, opts)),
         {:ok, full_sha} <- (progress.(2, "Validating SHA..."); validate_and_find_sha(app_name, sha, opts)),
         {:ok, qa_node} <- (progress.(3, "Applying cert mode..."); maybe_apply_cert_mode_change(qa_node, opts)),
         :ok <- (progress.(4, "Running ansible deploy..."); run_ansible_deploy(qa_node, full_sha, tui_pid, opts)),
         {:ok, updated} <- (progress.(5, "Updating QA state..."); update_qa_state(qa_node, full_sha, opts)) do
      {:ok, {updated, full_sha}}
    end
  end

  defp run_resolved_deploy_pipeline(tui_pid, qa_node, full_sha, opts) do
    total = 4

    progress = fn step, label ->
      DeployEx.TUI.Progress.update_progress(tui_pid, step / total, label)
    end

    with {:ok, qa_node} <- (progress.(1, "Verifying QA instance..."); DeployEx.QaNode.verify_instance_exists(qa_node)),
         {:ok, qa_node} <- (progress.(2, "Applying cert mode..."); maybe_apply_cert_mode_change(qa_node, opts)),
         :ok <- (progress.(3, "Running ansible deploy..."); run_ansible_deploy(qa_node, full_sha, tui_pid, opts)),
         {:ok, updated} <- (progress.(4, "Updating QA state..."); update_qa_state(qa_node, full_sha, opts)) do
      {:ok, {updated, full_sha}}
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :sha, i: :instance_id, q: :quiet, l: :only_local_release],
      switches: [
        sha: :string,
        instance_id: :string,
        git_branch: :string,
        public_ip_cert: :boolean,
        quiet: :boolean,
        aws_region: :string,
        aws_release_bucket: :string,
        only_local_release: :boolean,
        no_tui: :boolean
      ]
    )
  end

  defp maybe_apply_cert_mode_change(qa_node, opts) do
    case opts[:public_ip_cert] do
      nil -> {:ok, qa_node}
      desired when desired === qa_node.use_public_ip_cert? -> {:ok, qa_node}
      desired -> DeployEx.QaNode.set_use_public_ip_cert(qa_node, desired, opts)
    end
  end

  defp fetch_and_verify_qa_node(app_name, opts) do
    with {:ok, nodes} <- DeployEx.QaNode.find_qa_nodes_for_app(app_name, opts),
         {:ok, chosen} <- choose_node(nodes, app_name, opts) do
      DeployEx.QaNode.verify_instance_exists(chosen)
    end
  end

  defp choose_node([], app_name, _opts) do
    {:error, ErrorMessage.not_found("no QA node found for app '#{app_name}'")}
  end

  defp choose_node(nodes, app_name, opts) do
    cond do
      opts[:instance_id] -> find_node_by_instance_id(nodes, opts[:instance_id], app_name)
      opts[:git_branch] -> DeployEx.QaNode.select_by_branch(nodes, opts[:git_branch])
      true -> pick_node_interactively(nodes)
    end
  end

  defp pick_node_interactively(nodes) do
    case DeployEx.QaNode.pick_interactive(nodes,
           title: "Select QA node to deploy to",
           allow_all: false,
           always_prompt: true
         ) do
      {:ok, [picked]} -> {:ok, picked}
      {:ok, []} -> {:error, ErrorMessage.bad_request("no QA node selected")}
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


  defp run_ansible_deploy(qa_node, sha, tui_pid, opts) do
    if !opts[:quiet] and not DeployEx.TUI.enabled?() do
      Mix.shell().info("Deploying SHA #{String.slice(sha, 0, 7)} to #{qa_node.instance_name}...")
    end

    directory = @ansible_default_path
    vars = deploy_vars(qa_node, sha)

    DeployEx.QaPlaybook.with_temp_playbook(qa_node, :deploy, vars, directory, fn rel_path ->
      command = "ansible-playbook #{rel_path} --limit '#{DeployEx.QaNode.inventory_hostname(qa_node)},'"
      line_callback = build_line_callback(tui_pid)

      case DeployEx.Utils.run_command_streaming(command, directory, line_callback) do
        :ok -> :ok
        {:error, error} -> {:error, ErrorMessage.failed_dependency("ansible deploy failed", %{error: error})}
      end
    end)
  end

  defp build_line_callback(nil), do: fn _line -> :ok end
  defp build_line_callback(tui_pid), do: fn line -> DeployEx.TUI.Progress.update_log(tui_pid, line) end

  defp deploy_vars(%{use_public_ip_cert?: true}, sha),
    do: [target_release_sha: sha, letsencrypt_use_public_ip: true]
  defp deploy_vars(_qa_node, sha), do: [target_release_sha: sha]

  defp update_qa_state(qa_node, sha, opts) do
    branch = case DeployEx.ReleaseUploader.get_git_branch() do
      {:ok, b} -> b
      {:error, _} -> qa_node.git_branch
    end

    updated = %{qa_node | target_sha: sha, git_branch: branch}

    case DeployEx.QaNode.save_qa_state(updated, opts) do
      {:ok, :saved} -> {:ok, updated}
      error -> error
    end
  end
end
