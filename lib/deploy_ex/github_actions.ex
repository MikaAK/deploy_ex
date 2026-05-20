defmodule DeployEx.GitHubActions do
  @moduledoc """
  GitHub Actions integration: workflow detection (parses .github/workflows/*.yml
  to find the workflow that runs `mix deploy_ex.release` for a given branch),
  and `gh` CLI wrappers for run discovery + status polling.
  """

  @doc """
  Checks whether a GitHub Actions branch trigger glob (e.g. `qa/**`) matches a
  concrete branch name (e.g. `qa/cfx_web-canary`).

  GH supports `*` (matches any chars except `/`) and `**` (matches any chars
  including `/`). We translate to a regex.
  """
  @spec branch_glob_match?(String.t(), String.t()) :: boolean()
  def branch_glob_match?(pattern, branch) do
    regex_source =
      pattern
      |> String.split("**", parts: :infinity)
      |> Enum.map(&escape_segment/1)
      |> Enum.join(".*")

    Regex.match?(~r/^#{regex_source}$/, branch)
  end

  @release_command_signature "mix deploy_ex.release"

  @doc """
  Scans `<workflows_root>/*.yml` and returns `{:ok, %{file:, job_id:}}` for the
  workflow + job that builds a release for `qa_branch`.

  Detection logic:
  1. Parse each workflow file.
  2. Keep workflows whose `on.push.branches` patterns match `qa_branch` via
     `branch_glob_match?/2`.
  3. Among those, find a job whose steps include a `run:` containing
     `mix deploy_ex.release` — either directly OR by following a
     `uses: ./.github/workflows/<sub>.yml` reference into the sub-workflow's
     run steps.
  4. Drop any job whose `if:` gate evaluates to false against the qa branch
     (e.g. `deploy-main` gated on `github.ref == 'refs/heads/main'`). Jobs
     with an unparseable / unknown-context `if:` are kept as candidates so we
     never silently exclude a valid match. See `IfEvaluator`.
  5. If exactly one candidate matches, return it. If multiple, return :conflict.
     If none, return :not_found.
  """
  @spec find_build_workflow(Path.t(), String.t()) ::
          {:ok, %{file: String.t(), job_id: String.t()}} | {:error, ErrorMessage.t()}
  def find_build_workflow(workflows_root, qa_branch) do
    workflows = list_workflows(workflows_root)
    if_context = build_if_context(qa_branch)

    candidates =
      workflows
      |> Enum.filter(&workflow_triggers_on_branch?(&1, qa_branch))
      |> Enum.flat_map(&find_release_jobs(&1, workflows, if_context))

    case candidates do
      [%{file: _, job_id: _} = match] ->
        {:ok, match}

      [] ->
        {:error,
         ErrorMessage.not_found(
           "no workflow runs `#{@release_command_signature}` for branch #{qa_branch}",
           %{workflows_scanned: Enum.map(workflows, & &1.basename)}
         )}

      multiple ->
        {:error,
         ErrorMessage.conflict(
           "multiple workflows match for branch #{qa_branch}; pass --build-workflow to disambiguate",
           %{candidates: multiple}
         )}
    end
  end

  defp build_if_context(branch) do
    %{
      "github.ref" => "refs/heads/#{branch}",
      "github.ref_name" => branch,
      "github.event_name" => "push",
      "github.head_ref" => "",
      "github.base_ref" => ""
    }
  end

  defp escape_segment(segment) do
    segment
    |> Regex.escape()
    |> String.replace("\\*", "[^/]*")
  end

  defp list_workflows(workflows_root) do
    workflows_root
    |> Path.join("*.{yml,yaml}")
    |> Path.wildcard()
    |> Enum.map(&parse_workflow/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_workflow(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, parsed} -> %{basename: Path.basename(path), path: path, parsed: parsed}
      {:error, _} -> nil
    end
  end

  defp workflow_triggers_on_branch?(%{parsed: parsed}, branch) do
    parsed
    |> get_in(["on", "push", "branches"])
    |> List.wrap()
    |> Enum.any?(&branch_glob_match?(&1, branch))
  end

  defp find_release_jobs(%{basename: basename, parsed: parsed}, all_workflows, if_context) do
    parsed
    |> Map.get("jobs", %{})
    |> Enum.filter(fn {_id, job} ->
      job_if_active?(job, if_context) and job_runs_release?(job, all_workflows)
    end)
    |> Enum.map(fn {id, _job} -> %{file: basename, job_id: id} end)
  end

  defp job_if_active?(%{"if" => expr}, if_context) when is_binary(expr) do
    case DeployEx.GitHubActions.IfEvaluator.evaluate(expr, if_context) do
      {:ok, active?} -> active?
      :unknown -> true
    end
  end

  defp job_if_active?(_job, _if_context), do: true

  defp job_runs_release?(%{"steps" => steps}, _all) when is_list(steps) do
    Enum.any?(steps, &step_runs_release?/1)
  end

  defp job_runs_release?(%{"uses" => "./" <> sub_path}, all_workflows) do
    sub_basename = Path.basename(sub_path)

    case Enum.find(all_workflows, &(&1.basename === sub_basename)) do
      nil ->
        false

      sub ->
        sub.parsed
        |> Map.get("jobs", %{})
        |> Enum.any?(fn {_id, job} -> job_runs_release?(job, all_workflows) end)
    end
  end

  defp job_runs_release?(_job, _all), do: false

  defp step_runs_release?(%{"run" => run}) when is_binary(run) do
    String.contains?(run, @release_command_signature)
  end

  defp step_runs_release?(_step), do: false

  @doc """
  Checks `gh auth status`. Returns `:ok` if logged in, otherwise an
  `:unauthorized` ErrorMessage hinting at `gh auth login`.

  `opts[:shell]` injects a `(command, dir, opts) -> {:ok, output} | {:error, ErrorMessage}`
  function for testing. Defaults to `DeployEx.Utils.run_command_with_return/3`.
  """
  @spec ensure_authenticated(keyword()) :: :ok | {:error, ErrorMessage.t()}
  def ensure_authenticated(opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)

    case shell.("gh auth status", ".", []) do
      {:ok, _output} ->
        :ok

      {:error, _error} ->
        {:error,
         ErrorMessage.unauthorized(
           "gh CLI is not authenticated. Run: gh auth login",
           %{}
         )}
    end
  end

  @default_retry_interval_ms 5_000
  @default_retry_max 12

  @doc """
  Looks up the GitHub Actions run ID for the most recent run matching
  `branch` + `sha` + `workflow_file`. Retries up to `retry_max` times every
  `retry_interval_ms` if no run is found yet (the run takes a few seconds to
  register after `git push`).

  `opts[:shell]` injects a fake shell for tests.
  """
  @spec find_run_id(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, ErrorMessage.t()}
  def find_run_id(branch, sha, workflow_file, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)
    retry_interval_ms = Keyword.get(opts, :retry_interval_ms, @default_retry_interval_ms)
    retry_max = Keyword.get(opts, :retry_max, @default_retry_max)

    cmd =
      "gh run list --branch=#{branch} --commit=#{sha} --workflow=#{workflow_file} " <>
        "--json databaseId,status,conclusion,name --limit 1"

    Enum.reduce_while(1..retry_max, nil, fn attempt, _acc ->
      case shell.(cmd, ".", []) do
        {:ok, output} ->
          case extract_run_id(output) do
            {:ok, _id} = ok ->
              {:halt, ok}

            :not_yet when attempt < retry_max ->
              Process.sleep(retry_interval_ms)
              {:cont, nil}

            :not_yet ->
              {:halt,
               {:error,
                ErrorMessage.not_found(
                  "no workflow run found for #{branch} @ #{sha} after #{retry_max} attempts",
                  %{branch: branch, sha: sha, workflow: workflow_file}
                )}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp extract_run_id(json_output) do
    case Jason.decode(json_output) do
      {:ok, [%{"databaseId" => id} | _]} -> {:ok, id}
      {:ok, []} -> :not_yet
      {:error, _} -> :not_yet
    end
  end

  @default_poll_interval_ms 15_000
  @default_timeout_ms 30 * 60 * 1_000

  @doc """
  Polls `gh run view <run_id> --json status,conclusion,jobs` and returns
  `{:ok, run}` when the target job conclusion is success, `{:error, :build_failed}`
  if the target or any non-target job fails (which would skip the target),
  or `{:error, :timeout}` after `timeout_ms`.

  Options:
  * `:poll_interval_ms` — default 15_000
  * `:timeout_ms` — default 30 * 60 * 1_000 (30 min)
  * `:log_fn` — `(line :: String.t() -> any)` per-poll status emitter
  * `:shell` — test shim
  """
  @spec wait_for_run(integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :build_failed | :timeout | ErrorMessage.t()}
  def wait_for_run(run_id, target_job_name, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    log_fn = Keyword.get(opts, :log_fn, fn _line -> :ok end)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_loop(run_id, target_job_name, deadline, poll_interval_ms, shell, log_fn)
  end

  defp poll_loop(run_id, target_job_name, deadline, interval_ms, shell, log_fn) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case fetch_run(run_id, shell) do
        {:ok, run} -> evaluate_run(run, target_job_name, deadline, interval_ms, shell, log_fn, run_id)
        {:error, _} = err -> err
      end
    end
  end

  defp fetch_run(run_id, shell) do
    cmd = "gh run view #{run_id} --json status,conclusion,jobs"

    case shell.(cmd, ".", []) do
      {:ok, output} -> Jason.decode(output)
      {:error, _} = err -> err
    end
  end

  defp evaluate_run(run, target_job_name, deadline, interval_ms, shell, log_fn, run_id) do
    jobs = Map.get(run, "jobs", [])
    log_jobs(jobs, log_fn)

    cond do
      any_job_failed?(jobs) ->
        {:error, :build_failed}

      target_succeeded?(jobs, target_job_name) ->
        {:ok, run}

      true ->
        Process.sleep(interval_ms)
        poll_loop(run_id, target_job_name, deadline, interval_ms, shell, log_fn)
    end
  end

  defp any_job_failed?(jobs) do
    Enum.any?(jobs, fn job ->
      Map.get(job, "conclusion") in ["failure", "cancelled", "skipped"]
    end)
  end

  defp target_succeeded?(jobs, name) do
    Enum.any?(jobs, fn job ->
      Map.get(job, "name") === name and Map.get(job, "conclusion") === "success"
    end)
  end

  defp log_jobs(jobs, log_fn) do
    Enum.each(jobs, fn job ->
      log_fn.("#{Map.get(job, "name")}: #{Map.get(job, "status")} (#{Map.get(job, "conclusion") || "—"})")
    end)
  end
end
