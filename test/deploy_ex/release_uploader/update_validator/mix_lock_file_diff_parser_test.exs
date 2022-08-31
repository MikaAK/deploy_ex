defmodule DeployEx.ReleaseUploader.UpdateValidator.MixLockFileDiffParserTest do
  use ExUnit.Case, async: true

  alias DeployEx.ReleaseUploader.UpdateValidator.MixLockFileDiffParser

  @cmd_output File.read!(Path.join(__DIR__, "./mix_lock_file_diff.txt"))

  describe "&parse_deps_tree/1" do
    test "parses the tree correctly" do
      output = MixLockFileDiffParser.parse_mix_lock_diff(@cmd_output)

      assert output === [
        "blitz_credo_checks", "bunt", "credo",
        "dart_sass", "earmark", "earmark_parser",
        "error_message", "ex_aws", "ex_aws_s3",
        "excoveralls", "floki", "gettext", "hpax",
        "httpoison", "phoenix", "phoenix_live_view",
        "plug_crypto", "postgrex", "prometheus_telemetry",
        "swoosh", "tailwind", "timex"
      ]
    end
  end
end
