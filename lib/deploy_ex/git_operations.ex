defmodule DeployEx.GitOperations do
  @moduledoc """
  Git operations for the QA pipeline: resolve which branch to push QA rewrites
  to, commit + push specific files, revert the rewrite commit, and delete
  remote branches.

  All shell-outs go through `opts[:shell]`, defaulting to
  `DeployEx.Utils.run_command_with_return/3`. This makes the module fully
  testable without hitting a real git repo.
  """

  @qa_branch_pattern ~r/^qa[\/-]/

  @doc """
  Determines whether to reuse the current branch (if it matches `^qa[\\/-]`)
  or create a new branch derived from `app_name` + `tag` (or short SHA if
  `tag` is nil).
  """
  @spec resolve_qa_branch(Path.t(), String.t(), String.t() | nil, String.t(), keyword()) ::
          {:reuse_current, String.t()} | {:create_new, String.t()}
  def resolve_qa_branch(repo_root, app_name, tag, sha, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)

    case shell.("git rev-parse --abbrev-ref HEAD", repo_root, []) do
      {:ok, output} ->
        current = String.trim(output)

        if Regex.match?(@qa_branch_pattern, current) do
          {:reuse_current, current}
        else
          {:create_new, derive_qa_branch_name(app_name, tag, sha)}
        end

      {:error, _} ->
        {:create_new, derive_qa_branch_name(app_name, tag, sha)}
    end
  end

  defp derive_qa_branch_name(app_name, nil, sha), do: "qa/#{app_name}-#{String.slice(sha, 0, 7)}"
  defp derive_qa_branch_name(app_name, tag, _sha) when is_binary(tag), do: "qa/#{app_name}-#{tag}"
end
