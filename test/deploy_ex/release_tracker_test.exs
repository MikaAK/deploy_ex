defmodule DeployEx.ReleaseTrackerTest do
  use ExUnit.Case, async: true

  alias DeployEx.ReleaseTracker

  @source "lib/deploy_ex/release_tracker.ex"

  describe "public API" do
    test "keeps every function its call sites use" do
      Code.ensure_loaded!(ReleaseTracker)

      for {name, arity} <- [
            current_release_key: 1,
            current_release_key: 2,
            release_history_key: 1,
            release_history_key: 2,
            fetch_current_release: 1,
            fetch_current_release: 2,
            fetch_release_history: 1,
            fetch_release_history: 2,
            set_current_release: 2,
            set_current_release: 3,
            append_to_release_history: 2,
            append_to_release_history: 3,
            list_release_history: 1,
            list_release_history: 2,
            list_release_history: 3
          ] do
        assert function_exported?(ReleaseTracker, name, arity),
               "ReleaseTracker.#{name}/#{arity} disappeared"
      end
    end
  end

  describe "current_release_key/2" do
    test "defaults to the release-state prefix" do
      assert ReleaseTracker.current_release_key("cfx_web") ===
               "release-state/cfx_web/current_release.txt"
    end

    test "qa_release nests under a qa segment" do
      assert ReleaseTracker.current_release_key("cfx_web", qa_release: true) ===
               "release-state/qa/cfx_web/current_release.txt"
    end

    test "release_prefix wins over qa_release" do
      opts = [release_prefix: "branch-x", qa_release: true]

      assert ReleaseTracker.current_release_key("cfx_web", opts) ===
               "release-state/branch-x/cfx_web/current_release.txt"
    end

    test "release_state_prefix replaces the whole prefix" do
      assert ReleaseTracker.current_release_key("cfx_web", release_state_prefix: "custom/state") ===
               "custom/state/cfx_web/current_release.txt"
    end

    test "accepts a map of opts" do
      assert ReleaseTracker.current_release_key("cfx_web", %{qa_release: true}) ===
               "release-state/qa/cfx_web/current_release.txt"
    end

    test "blank prefixes fall back to the default" do
      assert ReleaseTracker.current_release_key("cfx_web", release_prefix: "") ===
               "release-state/cfx_web/current_release.txt"

      assert ReleaseTracker.current_release_key("cfx_web", release_state_prefix: "") ===
               "release-state/cfx_web/current_release.txt"
    end
  end

  describe "release_history_key/2" do
    test "defaults to the release-state prefix" do
      assert ReleaseTracker.release_history_key("cfx_web") ===
               "release-state/cfx_web/release_history.txt"
    end

    test "honours the same prefix rules as current_release_key/2" do
      assert ReleaseTracker.release_history_key("cfx_web", qa_release: true) ===
               "release-state/qa/cfx_web/release_history.txt"
    end
  end

  describe "object-store delegation" do
    test "holds no ExAws calls of its own" do
      refute File.read!(@source) =~ "ExAws.",
             "release_tracker.ex must route its S3 calls through S3ObjectStore"
    end

    test "routes through S3ObjectStore" do
      assert File.read!(@source) =~ "S3ObjectStore",
             "release_tracker.ex must call the provider-neutral object store"
    end

    test "reads fixed keys only, so no listing can silently truncate" do
      refute File.read!(@source) =~ "list_objects",
             "a listing here would need pagination; release_tracker.ex must not grow one"
    end
  end

  describe "error mapping" do
    test "a missing release state still reads as not_found" do
      assert File.read!(@source) =~ ~S|ErrorMessage.not_found("release state not found")|,
             "ansible.deploy prints this message when a release has never been recorded"
    end

    test "other failures keep the aws-failure wording and a :reason detail" do
      source = File.read!(@source)

      assert source =~ ~s("aws failure"), "non-404 failures kept the aws failure message"
      assert source =~ ":reason", "non-404 failures carried the raw reason in details"
    end

    test "writes still answer {:ok, :uploaded}" do
      assert File.read!(@source) =~ "{:ok, :uploaded}",
             "set_current_release/3 and append_to_release_history/3 return {:ok, :uploaded}"
    end
  end
end
