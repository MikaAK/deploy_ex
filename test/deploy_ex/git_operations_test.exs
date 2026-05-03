defmodule DeployEx.GitOperationsTest do
  use ExUnit.Case, async: true

  alias DeployEx.GitOperations

  describe "resolve_qa_branch/5" do
    test "reuses current branch when it matches qa/" do
      shell = fn "git rev-parse --abbrev-ref HEAD", _dir, _opts -> {:ok, "qa/foo\n"} end

      assert {:reuse_current, "qa/foo"} =
               GitOperations.resolve_qa_branch("/repo", "cfx_web", "canary", "abc1234567",
                 shell: shell
               )
    end

    test "reuses current branch when it matches qa-" do
      shell = fn _cmd, _dir, _opts -> {:ok, "qa-experimental"} end

      assert {:reuse_current, "qa-experimental"} =
               GitOperations.resolve_qa_branch("/repo", "cfx_web", nil, "deadbeef",
                 shell: shell
               )
    end

    test "creates new branch with --tag when not on a qa branch" do
      shell = fn _cmd, _dir, _opts -> {:ok, "main\n"} end

      assert {:create_new, "qa/cfx_web-canary"} =
               GitOperations.resolve_qa_branch("/repo", "cfx_web", "canary", "abc1234567",
                 shell: shell
               )
    end

    test "creates new branch with short sha when no --tag" do
      shell = fn _cmd, _dir, _opts -> {:ok, "main"} end

      assert {:create_new, "qa/cfx_web-abc1234"} =
               GitOperations.resolve_qa_branch("/repo", "cfx_web", nil, "abc1234567",
                 shell: shell
               )
    end
  end
end
