defmodule DeployEx.GitHubActionsTest do
  use ExUnit.Case, async: true

  alias DeployEx.GitHubActions

  @fixtures_root Path.expand("../support/fixtures/workflows", __DIR__)

  describe "branch_glob_match?/2" do
    test "matches qa/cfx_web-canary against qa/**" do
      assert GitHubActions.branch_glob_match?("qa/**", "qa/cfx_web-canary")
    end

    test "matches qa-experimental against qa-**" do
      assert GitHubActions.branch_glob_match?("qa-**", "qa-experimental")
    end

    test "matches main against main" do
      assert GitHubActions.branch_glob_match?("main", "main")
    end

    test "does not match qa/foo against main" do
      refute GitHubActions.branch_glob_match?("main", "qa/foo")
    end

    test "does not match qa-foo against qa/**" do
      refute GitHubActions.branch_glob_match?("qa/**", "qa-foo")
    end
  end
end
