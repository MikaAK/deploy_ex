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

  defp escape_segment(segment) do
    segment
    |> Regex.escape()
    |> String.replace("\\*", "[^/]*")
  end
end
