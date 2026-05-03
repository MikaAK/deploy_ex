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

  @doc """
  Stages the listed `files`, commits with `message`, and pushes `branch` to
  origin. Returns the resulting commit's SHA.

  Options:
  * `:create_new?` — true if we created the branch (uses `--force-with-lease`).
  * `:base_sha` — when `:create_new?`, branch off this SHA via `git checkout -B`.
  * `:shell` — test shim.
  """
  @spec commit_and_push(Path.t(), String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, String.t()} | {:error, ErrorMessage.t()}
  def commit_and_push(repo_root, branch, files, message, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)
    create_new? = Keyword.get(opts, :create_new?, false)
    base_sha = Keyword.get(opts, :base_sha)

    with :ok <- maybe_checkout_branch(shell, repo_root, branch, create_new?, base_sha),
         :ok <- run_step(shell, repo_root, "git add #{quote_files(files)}"),
         :ok <- run_step(shell, repo_root, ~s|git commit -m #{shell_escape(message)}|),
         :ok <- run_step(shell, repo_root, push_command(branch, create_new?)),
         {:ok, sha_output} <- shell.("git rev-parse HEAD", repo_root, []) do
      {:ok, String.trim(sha_output)}
    end
  end

  defp maybe_checkout_branch(_shell, _repo, _branch, false, _base), do: :ok

  defp maybe_checkout_branch(shell, repo, branch, true, nil) do
    run_step(shell, repo, "git checkout -B #{branch}")
  end

  defp maybe_checkout_branch(shell, repo, branch, true, base_sha) do
    run_step(shell, repo, "git checkout -B #{branch} #{base_sha}")
  end

  defp push_command(branch, true), do: "git push --force-with-lease -u origin #{branch}"
  defp push_command(_branch, false), do: "git push"

  defp run_step(shell, repo, cmd) do
    case shell.(cmd, repo, []) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp quote_files(files), do: files |> Enum.map(&shell_escape/1) |> Enum.join(" ")

  defp shell_escape(value), do: ~s|'#{String.replace(value, "'", "'\\''")}'|
end
