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
          {:ok, %{file: String.t(), job_id: String.t(), steps_file: String.t()}}
          | {:error, ErrorMessage.t()}
  def find_build_workflow(workflows_root, qa_branch) do
    workflows = list_workflows(workflows_root)
    if_context = build_if_context(qa_branch)

    candidates =
      workflows
      |> Enum.filter(&workflow_triggers_on_branch?(&1, qa_branch))
      |> Enum.flat_map(&find_release_jobs(&1, workflows, if_context))

    case candidates do
      [%{file: _, job_id: _, steps_file: _} = match] ->
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
    |> Enum.flat_map(fn {id, job} ->
      with true <- job_if_active?(job, if_context),
           {:ok, steps_basename} <- locate_release_steps_file(job, basename, all_workflows) do
        [%{file: basename, job_id: id, steps_file: steps_basename}]
      else
        _ -> []
      end
    end)
  end

  defp job_if_active?(%{"if" => expr}, if_context) when is_binary(expr) do
    case DeployEx.GitHubActions.IfEvaluator.evaluate(expr, if_context) do
      {:ok, active?} -> active?
      :unknown -> true
    end
  end

  defp job_if_active?(_job, _if_context), do: true

  defp locate_release_steps_file(%{"steps" => steps}, basename, _all) when is_list(steps) do
    if Enum.any?(steps, &step_runs_release?/1), do: {:ok, basename}, else: :error
  end

  defp locate_release_steps_file(%{"uses" => "./" <> sub_path}, _basename, all_workflows) do
    sub_basename = Path.basename(sub_path)

    case Enum.find(all_workflows, &(&1.basename === sub_basename)) do
      nil ->
        :error

      sub ->
        sub.parsed
        |> Map.get("jobs", %{})
        |> Enum.find_value(:error, fn {_id, job} ->
          case locate_release_steps_file(job, sub_basename, all_workflows) do
            {:ok, _} = ok -> ok
            :error -> nil
          end
        end)
    end
  end

  defp locate_release_steps_file(_job, _basename, _all), do: :error

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

end
