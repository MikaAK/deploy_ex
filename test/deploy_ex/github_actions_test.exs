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

  describe "find_run_id/4" do
    test "returns the run_id from gh run list output" do
      shell = fn cmd, _dir, _opts ->
        assert cmd =~ "gh run list"
        assert cmd =~ "--branch=qa/cfx_web-canary"
        assert cmd =~ "--commit=abc1234"
        assert cmd =~ "--workflow=pipeline.yml"
        {:ok, ~s([{"databaseId":12345,"status":"in_progress","conclusion":null,"name":"Pipeline"}])}
      end

      assert {:ok, 12345} =
               GitHubActions.find_run_id("qa/cfx_web-canary", "abc1234", "pipeline.yml",
                 shell: shell,
                 retry_interval_ms: 0,
                 retry_max: 1
               )
    end

    test "retries while no run is found, succeeds on second attempt" do
      counter = :counters.new(1, [])

      shell = fn _cmd, _dir, _opts ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) === 1 do
          {:ok, "[]"}
        else
          {:ok, ~s([{"databaseId":99,"status":"queued","conclusion":null,"name":"P"}])}
        end
      end

      assert {:ok, 99} =
               GitHubActions.find_run_id("b", "s", "w.yml",
                 shell: shell,
                 retry_interval_ms: 0,
                 retry_max: 5
               )
    end

    test "returns :not_found after retry budget exhausted" do
      shell = fn _cmd, _dir, _opts -> {:ok, "[]"} end

      assert {:error, %ErrorMessage{code: :not_found}} =
               GitHubActions.find_run_id("b", "s", "w.yml",
                 shell: shell,
                 retry_interval_ms: 0,
                 retry_max: 3
               )
    end
  end

  describe "wait_for_run/3" do
    @successful_run %{
      "status" => "completed",
      "conclusion" => "success",
      "jobs" => [
        %{"name" => "deploy-qa", "status" => "completed", "conclusion" => "success"}
      ]
    }

    @target_failed_run %{
      "status" => "completed",
      "conclusion" => "failure",
      "jobs" => [
        %{"name" => "deploy-qa", "status" => "completed", "conclusion" => "failure"}
      ]
    }

    @dep_failed_run %{
      "status" => "in_progress",
      "conclusion" => nil,
      "jobs" => [
        %{"name" => "mix-compile-prod", "status" => "completed", "conclusion" => "failure"},
        %{"name" => "deploy-qa", "status" => "queued", "conclusion" => nil}
      ]
    }

    test "returns {:ok, run} when target job conclusion is success" do
      shell = fn _cmd, _dir, _opts -> {:ok, Jason.encode!(@successful_run)} end

      assert {:ok, _run} =
               GitHubActions.wait_for_run(123, "deploy-qa",
                 shell: shell,
                 poll_interval_ms: 0,
                 timeout_ms: 1_000
               )
    end

    test "returns :build_failed when target job conclusion is failure" do
      shell = fn _cmd, _dir, _opts -> {:ok, Jason.encode!(@target_failed_run)} end

      assert {:error, :build_failed} =
               GitHubActions.wait_for_run(123, "deploy-qa",
                 shell: shell,
                 poll_interval_ms: 0,
                 timeout_ms: 1_000
               )
    end

    test "aborts early when a non-target job fails (dep would skip target)" do
      shell = fn _cmd, _dir, _opts -> {:ok, Jason.encode!(@dep_failed_run)} end

      assert {:error, :build_failed} =
               GitHubActions.wait_for_run(123, "deploy-qa",
                 shell: shell,
                 poll_interval_ms: 0,
                 timeout_ms: 1_000
               )
    end

    test "returns :timeout when timeout_ms exceeded" do
      shell = fn _cmd, _dir, _opts ->
        {:ok, Jason.encode!(%{"status" => "in_progress", "conclusion" => nil, "jobs" => []})}
      end

      assert {:error, :timeout} =
               GitHubActions.wait_for_run(123, "deploy-qa",
                 shell: shell,
                 poll_interval_ms: 1,
                 timeout_ms: 5
               )
    end
  end
end
