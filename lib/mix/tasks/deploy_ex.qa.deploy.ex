defmodule Mix.Tasks.DeployEx.Qa.Deploy do
  use Mix.Task

  @shortdoc "Deploys a specific SHA to an existing QA node"
  @moduledoc """
  Deploys a specific SHA to an existing QA node.

  ## Example
  ```bash
  mix deploy_ex.qa.deploy my_app --sha def5678
  ```

  ## Options
  - `--sha, -s` - Target git SHA (required)
  - `--instance-id, -i` - Target a specific QA instance when multiple exist
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

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required. Usage: mix deploy_ex.qa.deploy <app_name> --sha <sha>")
      end

      sha = opts[:sha] || Mix.raise("--sha option is required")
      total_steps = 4

      result = DeployEx.TUI.Progress.run_stream(
        "QA Deploy: #{app_name}",
        fn tui_pid ->
          run_deploy_pipeline(tui_pid, app_name, sha, opts, total_steps)
        end
      )

      case result do
        {:ok, {qa_node, full_sha}} ->
          unless opts[:quiet] do
            Mix.shell().info([
              :green, "\n✓ Deployed SHA ", :cyan, String.slice(full_sha, 0, 7),
              :green, " (branch ", :cyan, qa_node.git_branch || "—",
              :green, ") to QA node ", :cyan, qa_node.instance_name, :reset
            ])
          end

        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp run_deploy_pipeline(tui_pid, app_name, sha, opts, total) do
    progress = fn step, label ->
      DeployEx.TUI.Progress.update_progress(tui_pid, step / total, label)
    end

    with {:ok, qa_node} <- (progress.(1, "Fetching QA node..."); fetch_and_verify_qa_node(app_name, opts)),
         {:ok, full_sha} <- (progress.(2, "Validating SHA..."); validate_and_find_sha(app_name, sha, opts)),
         :ok <- (progress.(3, "Running ansible deploy..."); run_ansible_deploy(qa_node, full_sha, tui_pid, opts)),
         {:ok, updated} <- (progress.(4, "Updating QA state..."); update_qa_state(qa_node, full_sha, opts)) do
      {:ok, {updated, full_sha}}
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :sha, i: :instance_id, q: :quiet],
      switches: [
        sha: :string,
        instance_id: :string,
        quiet: :boolean,
        aws_region: :string,
        aws_release_bucket: :string,
        no_tui: :boolean
      ]
    )
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
    case opts[:instance_id] do
      nil ->
        case DeployEx.QaNode.pick_interactive(nodes,
               title: "Select QA node to deploy to",
               allow_all: false
             ) do
          {:ok, [picked]} -> {:ok, picked}
          {:ok, []} -> {:error, ErrorMessage.bad_request("no QA node selected")}
        end

      instance_id ->
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
      command = "ansible-playbook #{rel_path} --limit '#{qa_node.instance_name},'"
      line_callback = build_line_callback(tui_pid)

      case DeployEx.Utils.run_command_streaming(command, directory, line_callback) do
        :ok -> :ok
        {:error, error} -> {:error, ErrorMessage.failed_dependency("ansible deploy failed", %{error: error})}
      end
    end)
  end

  defp build_line_callback(nil), do: fn _line -> :ok end
  defp build_line_callback(tui_pid), do: fn line -> DeployEx.TUI.Progress.update_log(tui_pid, line) end

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
