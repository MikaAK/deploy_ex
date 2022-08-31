defmodule DeployEx.ReleaseUploader.UpdateValidator.MixLockFileDiffParser do
  @dep_regex ~r/^\+  "(?<dep_name>[a-z0-9_]+)":/

  def git_diff_mix_lock({{current_sha, last_sha} = sha_tuple, _file_diffs}) do
    case System.shell("git diff #{current_sha}..#{last_sha} mix.lock") do
      {output, 0} ->
        {:ok, {sha_tuple, output |> String.trim_trailing("\n") |> parse_mix_lock_diff}}

      {output, code} -> {:error, ErrorMessage.failed_dependency(
        "couldn't run git diff for mix.lock",
        %{output: output, code: code}
      )}
    end
  end

  def parse_mix_lock_diff(output) do
    output
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ @dep_regex))
      |> Enum.map(&(@dep_regex |> Regex.run(&1, capture: [:dep_name]) |> List.first))
  end
end
