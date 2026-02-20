defmodule DeployEx.ReleaseUploader.RedeployConfigTest do
  use ExUnit.Case, async: true

  alias DeployEx.ReleaseUploader.RedeployConfig

  describe "&from_keyword/1" do
    test "returns empty map for nil" do
      assert RedeployConfig.from_keyword(nil) === %{}
    end

    test "parses whitelist string patterns into regexes" do
      config = RedeployConfig.from_keyword([
        my_app: [whitelist: ["apps/my_app/lib/my_app\\.ex"]]
      ])

      assert %{"my_app" => %RedeployConfig{whitelist: [%Regex{}], blacklist: nil}} = config
    end

    test "parses blacklist string patterns into regexes" do
      config = RedeployConfig.from_keyword([
        my_app: [blacklist: ["apps/my_app/test/.*"]]
      ])

      assert %{"my_app" => %RedeployConfig{whitelist: nil, blacklist: [%Regex{}]}} = config
    end

    test "accepts pre-compiled Regex sigils" do
      config = RedeployConfig.from_keyword([
        my_app: [whitelist: [~r/apps\/my_app\/lib\/.*/]]
      ])

      assert %{"my_app" => %RedeployConfig{whitelist: [%Regex{}]}} = config
    end

    test "parses multiple apps" do
      config = RedeployConfig.from_keyword([
        app_a: [whitelist: ["apps/app_a/lib/.*"]],
        app_b: [blacklist: ["apps/app_b/test/.*"]]
      ])

      assert Map.has_key?(config, "app_a")
      assert Map.has_key?(config, "app_b")
      assert config["app_a"].whitelist !== nil
      assert config["app_b"].blacklist !== nil
    end

    test "sets nil for empty pattern lists" do
      config = RedeployConfig.from_keyword([my_app: [whitelist: [], blacklist: []]])

      assert config["my_app"].whitelist === nil
      assert config["my_app"].blacklist === nil
    end
  end

  describe "&filter_file_diffs/3" do
    test "returns unfiltered diffs when no config for app" do
      file_diffs = ["apps/my_app/lib/my_app.ex", "config/config.exs"]
      config = %{}

      assert RedeployConfig.filter_file_diffs(file_diffs, "my_app", config) === file_diffs
    end

    test "returns unfiltered diffs when redeploy_config is nil" do
      file_diffs = ["apps/my_app/lib/my_app.ex", "config/config.exs"]

      assert RedeployConfig.filter_file_diffs(file_diffs, "my_app", nil) === file_diffs
    end

    test "whitelist keeps only matching files" do
      file_diffs = [
        "apps/my_app/lib/my_app.ex",
        "apps/my_app/lib/my_app/worker.ex",
        "config/config.exs",
        "mix.exs"
      ]

      config = RedeployConfig.from_keyword([
        my_app: [whitelist: ["apps/my_app/lib/my_app\\.ex$"]]
      ])

      result = RedeployConfig.filter_file_diffs(file_diffs, "my_app", config)

      assert result === ["apps/my_app/lib/my_app.ex"]
    end

    test "whitelist with multiple patterns keeps files matching any pattern" do
      file_diffs = [
        "apps/my_app/lib/my_app.ex",
        "apps/my_app/lib/my_app/worker.ex",
        "config/config.exs",
        "mix.exs"
      ]

      config = RedeployConfig.from_keyword([
        my_app: [whitelist: [
          "apps/my_app/lib/my_app\\.ex$",
          "^config/"
        ]]
      ])

      result = RedeployConfig.filter_file_diffs(file_diffs, "my_app", config)

      assert result === ["apps/my_app/lib/my_app.ex", "config/config.exs"]
    end

    test "blacklist removes matching files" do
      file_diffs = [
        "apps/my_app/lib/my_app.ex",
        "apps/my_app/test/my_app_test.exs",
        "config/config.exs"
      ]

      config = RedeployConfig.from_keyword([
        my_app: [blacklist: ["apps/my_app/test/"]]
      ])

      result = RedeployConfig.filter_file_diffs(file_diffs, "my_app", config)

      assert result === ["apps/my_app/lib/my_app.ex", "config/config.exs"]
    end

    test "blacklist with multiple patterns removes files matching any pattern" do
      file_diffs = [
        "apps/my_app/lib/my_app.ex",
        "apps/my_app/test/my_app_test.exs",
        "README.md",
        "config/config.exs"
      ]

      config = RedeployConfig.from_keyword([
        my_app: [blacklist: [
          "apps/my_app/test/",
          "\\.md$"
        ]]
      ])

      result = RedeployConfig.filter_file_diffs(file_diffs, "my_app", config)

      assert result === ["apps/my_app/lib/my_app.ex", "config/config.exs"]
    end

    test "filters only apply to the matching app" do
      file_diffs = [
        "apps/app_a/lib/app_a.ex",
        "apps/app_b/lib/app_b.ex",
        "config/config.exs"
      ]

      config = RedeployConfig.from_keyword([
        app_a: [whitelist: ["apps/app_a/"]]
      ])

      assert RedeployConfig.filter_file_diffs(file_diffs, "app_a", config) === [
        "apps/app_a/lib/app_a.ex"
      ]

      assert RedeployConfig.filter_file_diffs(file_diffs, "app_b", config) === file_diffs
    end
  end

  describe "&has_whitelist?/2" do
    test "returns true when app has a whitelist" do
      config = RedeployConfig.from_keyword([
        my_app: [whitelist: ["apps/my_app/lib/.*"]]
      ])

      assert RedeployConfig.has_whitelist?("my_app", config)
    end

    test "returns false when app has no whitelist" do
      config = RedeployConfig.from_keyword([
        my_app: [blacklist: ["apps/my_app/test/.*"]]
      ])

      refute RedeployConfig.has_whitelist?("my_app", config)
    end

    test "returns false when app is not in config" do
      refute RedeployConfig.has_whitelist?("unknown_app", %{})
    end

    test "returns false when config is nil" do
      refute RedeployConfig.has_whitelist?("my_app", nil)
    end
  end
end
