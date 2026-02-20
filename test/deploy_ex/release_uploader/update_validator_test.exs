defmodule DeployEx.ReleaseUploader.UpdateValidatorTest do
  use ExUnit.Case, async: true

  alias DeployEx.ReleaseUploader.{RedeployConfig, UpdateValidator}

  defp build_state(app_name, opts) do
    %DeployEx.ReleaseUploader.State{
      app_name: opts[:release_name] || app_name,
      local_file: "./_build/#{app_name}-0.1.0.tar.gz",
      sha: opts[:sha] || "abc1234",
      last_sha: opts[:last_sha] || "def5678",
      release_apps: opts[:release_apps] || [app_name],
      redeploy_config: opts[:redeploy_config] || %{}
    }
  end

  describe "filter_changed/5 with whitelist redeploy_config" do
    test "only triggers redeploy when whitelisted files change" do
      redeploy_config = RedeployConfig.from_keyword([
        my_app: [whitelist: ["apps/my_app/lib/my_app\\.ex$"]]
      ])

      state = build_state("my_app",
        sha: "abc1234",
        last_sha: "def5678",
        redeploy_config: redeploy_config
      )

      file_diffs_by_sha_tuple = %{
        {"abc1234", "def5678"} => [
          "apps/my_app/lib/my_app.ex",
          "apps/my_app/lib/my_app/worker.ex"
        ]
      }

      {:ok, changed} = UpdateValidator.filter_changed(
        [],
        [state],
        file_diffs_by_sha_tuple,
        %{},
        %{"my_app" => []}
      )

      assert length(changed) === 1
    end

    test "does not trigger redeploy when only non-whitelisted files change" do
      redeploy_config = RedeployConfig.from_keyword([
        my_app: [whitelist: ["apps/my_app/lib/my_app\\.ex$"]]
      ])

      state = build_state("my_app",
        sha: "abc1234",
        last_sha: "def5678",
        redeploy_config: redeploy_config
      )

      file_diffs_by_sha_tuple = %{
        {"abc1234", "def5678"} => [
          "apps/my_app/lib/my_app/worker.ex",
          "apps/my_app/lib/my_app/server.ex"
        ]
      }

      {:ok, changed} = UpdateValidator.filter_changed(
        [],
        [state],
        file_diffs_by_sha_tuple,
        %{},
        %{"my_app" => []}
      )

      assert Enum.empty?(changed)
    end

    test "whitelist skips dependency change detection" do
      redeploy_config = RedeployConfig.from_keyword([
        my_app: [whitelist: ["apps/my_app/lib/my_app\\.ex$"]]
      ])

      state = build_state("my_app",
        sha: "abc1234",
        last_sha: "def5678",
        redeploy_config: redeploy_config
      )

      file_diffs_by_sha_tuple = %{
        {"abc1234", "def5678"} => ["mix.lock"]
      }

      dep_changes_by_sha_tuple = %{
        {"abc1234", "def5678"} => ["phoenix"]
      }

      app_dep_tree = %{"my_app" => ["phoenix"]}

      {:ok, changed} = UpdateValidator.filter_changed(
        [],
        [state],
        file_diffs_by_sha_tuple,
        dep_changes_by_sha_tuple,
        app_dep_tree
      )

      assert Enum.empty?(changed)
    end
  end

  describe "filter_changed/5 with blacklist redeploy_config" do
    test "does not trigger redeploy when only blacklisted files change" do
      redeploy_config = RedeployConfig.from_keyword([
        my_app: [blacklist: ["apps/my_app/test/"]]
      ])

      state = build_state("my_app",
        sha: "abc1234",
        last_sha: "def5678",
        redeploy_config: redeploy_config
      )

      file_diffs_by_sha_tuple = %{
        {"abc1234", "def5678"} => [
          "apps/my_app/test/my_app_test.exs"
        ]
      }

      {:ok, changed} = UpdateValidator.filter_changed(
        [],
        [state],
        file_diffs_by_sha_tuple,
        %{},
        %{"my_app" => []}
      )

      assert Enum.empty?(changed)
    end

    test "triggers redeploy when non-blacklisted files also change" do
      redeploy_config = RedeployConfig.from_keyword([
        my_app: [blacklist: ["apps/my_app/test/"]]
      ])

      state = build_state("my_app",
        sha: "abc1234",
        last_sha: "def5678",
        redeploy_config: redeploy_config
      )

      file_diffs_by_sha_tuple = %{
        {"abc1234", "def5678"} => [
          "apps/my_app/lib/my_app.ex",
          "apps/my_app/test/my_app_test.exs"
        ]
      }

      {:ok, changed} = UpdateValidator.filter_changed(
        [],
        [state],
        file_diffs_by_sha_tuple,
        %{},
        %{"my_app" => []}
      )

      assert length(changed) === 1
    end

    test "blacklist still allows dependency changes to trigger redeploy" do
      redeploy_config = RedeployConfig.from_keyword([
        my_app: [blacklist: ["apps/my_app/test/"]]
      ])

      state = build_state("my_app",
        sha: "abc1234",
        last_sha: "def5678",
        redeploy_config: redeploy_config
      )

      file_diffs_by_sha_tuple = %{
        {"abc1234", "def5678"} => ["mix.lock"]
      }

      dep_changes_by_sha_tuple = %{
        {"abc1234", "def5678"} => ["phoenix"]
      }

      app_dep_tree = %{"my_app" => ["phoenix"]}

      {:ok, changed} = UpdateValidator.filter_changed(
        [],
        [state],
        file_diffs_by_sha_tuple,
        dep_changes_by_sha_tuple,
        app_dep_tree
      )

      assert length(changed) === 1
    end
  end

  describe "filter_changed/5 without redeploy_config" do
    test "normal behavior when no redeploy_config is set" do
      state = build_state("my_app",
        sha: "abc1234",
        last_sha: "def5678"
      )

      file_diffs_by_sha_tuple = %{
        {"abc1234", "def5678"} => ["apps/my_app/lib/my_app.ex"]
      }

      {:ok, changed} = UpdateValidator.filter_changed(
        [],
        [state],
        file_diffs_by_sha_tuple,
        %{},
        %{"my_app" => []}
      )

      assert length(changed) === 1
    end
  end

  describe "filter_changed/5 with multi-app release" do
    test "whitelist on one app does not affect other apps in the release" do
      redeploy_config = RedeployConfig.from_keyword([
        app_service: [whitelist: ["apps/app_service/lib/app_service\\.ex$"]]
      ])

      state = build_state("app_web",
        sha: "abc1234",
        last_sha: "def5678",
        release_apps: ["app_web", "app_service"],
        redeploy_config: redeploy_config
      )

      file_diffs_by_sha_tuple = %{
        {"abc1234", "def5678"} => [
          "apps/app_web/lib/app_web/router.ex"
        ]
      }

      {:ok, changed} = UpdateValidator.filter_changed(
        [],
        [state],
        file_diffs_by_sha_tuple,
        %{},
        %{"app_web" => [], "app_service" => []}
      )

      assert length(changed) === 1
    end
  end
end
