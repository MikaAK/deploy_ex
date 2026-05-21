defmodule DeployEx.GitHubActionsTest do
  use ExUnit.Case, async: true

  alias DeployEx.GitHubActions

  @happy_root Path.expand("../support/fixtures/workflows/happy", __DIR__)
  @ambiguous_root Path.expand("../support/fixtures/workflows/ambiguous", __DIR__)
  @no_deploy_root Path.expand("../support/fixtures/workflows/no_deploy", __DIR__)
  @branch_conditional_root Path.expand(
                             "../support/fixtures/workflows/branch_conditional",
                             __DIR__
                           )

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

  describe "find_build_workflow/2" do
    test "picks pipeline.yml when its sub-workflow runs deploy_ex.release for the qa branch" do
      result = GitHubActions.find_build_workflow(@happy_root, "qa/cfx_web-canary")

      assert {:ok,
              %{file: "cfx_pipeline.yml", job_id: "deploy-qa", steps_file: "deploy.yml"}} = result
    end

    test "returns :conflict when 2+ workflows match" do
      result = GitHubActions.find_build_workflow(@ambiguous_root, "qa/cfx_web-canary")
      assert {:error, %ErrorMessage{code: :conflict}} = result
    end

    test "returns :not_found when no workflow runs deploy_ex.release" do
      result = GitHubActions.find_build_workflow(@no_deploy_root, "qa-foo")
      assert {:error, %ErrorMessage{code: :not_found}} = result
    end

    test "branch-conditional: qa/ branch picks deploy-qa over deploy-main" do
      result = GitHubActions.find_build_workflow(@branch_conditional_root, "qa/theta_data_api")

      assert {:ok, %{file: "pipeline.yml", job_id: "deploy-qa", steps_file: "deploy.yml"}} ===
               result
    end

    test "branch-conditional: qa- branch picks deploy-qa over deploy-main" do
      result = GitHubActions.find_build_workflow(@branch_conditional_root, "qa-experimental")

      assert {:ok, %{file: "pipeline.yml", job_id: "deploy-qa", steps_file: "deploy.yml"}} ===
               result
    end

    test "branch-conditional: main branch picks deploy-main over deploy-qa" do
      result = GitHubActions.find_build_workflow(@branch_conditional_root, "main")

      assert {:ok, %{file: "pipeline.yml", job_id: "deploy-main", steps_file: "deploy.yml"}} ===
               result
    end
  end

  describe "ensure_authenticated/1" do
    test "returns :ok when gh auth status exits 0" do
      shell = fn "gh auth status", _dir, _opts -> {:ok, "Logged in to github.com as foo"} end
      assert :ok = GitHubActions.ensure_authenticated(shell: shell)
    end

    test "returns error with hint when gh auth status fails" do
      shell = fn "gh auth status", _dir, _opts ->
        {:error, ErrorMessage.internal_server_error("not logged in", %{})}
      end

      assert {:error, %ErrorMessage{code: :unauthorized, message: msg}} =
               GitHubActions.ensure_authenticated(shell: shell)

      assert msg =~ "gh auth login"
    end
  end

end
