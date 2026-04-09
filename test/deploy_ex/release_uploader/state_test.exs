defmodule DeployEx.ReleaseUploader.StateTest do
  use ExUnit.Case, async: true

  alias DeployEx.ReleaseUploader.State

  describe "&lastest_remote_app_release/3" do
    test "returns latest release from app folder when no release_prefix" do
      remote_releases = [
        "my_app/1000000-abc1234-my_app-0.1.0.tar.gz",
        "my_app/2000000-def5678-my_app-0.1.0.tar.gz"
      ]

      assert {2000000, "def5678", "2000000-def5678-my_app-0.1.0.tar.gz"} =
        State.lastest_remote_app_release(remote_releases, "my_app")
    end

    test "returns nil when no releases exist for app" do
      assert is_nil(State.lastest_remote_app_release([], "my_app"))
    end

    test "with qa release_prefix only matches releases in qa/ folder" do
      remote_releases = [
        "my_app/1000000-abc1234-my_app-0.1.0.tar.gz",
        "qa/my_app/2000000-def5678-my_app-0.1.0.tar.gz"
      ]

      result = State.lastest_remote_app_release(remote_releases, "my_app", "qa")

      assert {2000000, "def5678", "2000000-def5678-my_app-0.1.0.tar.gz"} = result
    end

    test "with qa release_prefix ignores non-qa releases" do
      remote_releases = [
        "my_app/1000000-abc1234-my_app-0.1.0.tar.gz"
      ]

      assert is_nil(State.lastest_remote_app_release(remote_releases, "my_app", "qa"))
    end

    test "without release_prefix ignores qa releases" do
      remote_releases = [
        "qa/my_app/1000000-abc1234-my_app-0.1.0.tar.gz"
      ]

      assert is_nil(State.lastest_remote_app_release(remote_releases, "my_app"))
    end

    test "with qa release_prefix returns latest among multiple qa releases" do
      remote_releases = [
        "qa/my_app/1000000-abc1234-my_app-0.1.0.tar.gz",
        "qa/my_app/3000000-ghi9012-my_app-0.1.0.tar.gz",
        "qa/my_app/2000000-def5678-my_app-0.1.0.tar.gz",
        "my_app/4000000-jkl3456-my_app-0.1.0.tar.gz"
      ]

      result = State.lastest_remote_app_release(remote_releases, "my_app", "qa")

      assert {3000000, "ghi9012", "3000000-ghi9012-my_app-0.1.0.tar.gz"} = result
    end
  end

  describe "&last_sha_from_remote_file/3" do
    test "returns sha of latest release in qa folder" do
      remote_releases = [
        "qa/my_app/1000000-abc1234-my_app-0.1.0.tar.gz",
        "qa/my_app/2000000-def5678-my_app-0.1.0.tar.gz"
      ]

      assert "def5678" === State.last_sha_from_remote_file(remote_releases, "my_app", "qa")
    end

    test "returns nil when no qa releases exist" do
      remote_releases = [
        "my_app/1000000-abc1234-my_app-0.1.0.tar.gz"
      ]

      assert is_nil(State.last_sha_from_remote_file(remote_releases, "my_app", "qa"))
    end

    test "returns sha from non-prefixed folder when release_prefix is nil" do
      remote_releases = [
        "my_app/1000000-abc1234-my_app-0.1.0.tar.gz",
        "qa/my_app/2000000-def5678-my_app-0.1.0.tar.gz"
      ]

      assert "abc1234" === State.last_sha_from_remote_file(remote_releases, "my_app", nil)
    end
  end
end
