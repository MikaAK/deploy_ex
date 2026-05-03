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

  describe "commit_and_push/5" do
    test "creates new branch from base_sha, stages files, force-with-lease push" do
      Process.put(:cmds, [])

      shell = fn cmd, _dir, _opts ->
        Process.put(:cmds, [cmd | Process.get(:cmds)])

        cond do
          cmd =~ "git checkout -B" -> {:ok, ""}
          cmd =~ "git add" -> {:ok, ""}
          cmd =~ "git commit" -> {:ok, ""}
          cmd =~ "git push" -> {:ok, ""}
          cmd =~ "git rev-parse HEAD" -> {:ok, "newsha1234567890\n"}
        end
      end

      result =
        GitOperations.commit_and_push(
          "/repo",
          "qa/cfx_web-canary",
          ["apps/cfx_web/config/prod.exs"],
          "qa: rewrite host config for cfx_web",
          shell: shell,
          create_new?: true,
          base_sha: "deadbeef"
        )

      assert {:ok, "newsha1234567890"} = result

      cmds = Enum.reverse(Process.get(:cmds))
      assert Enum.any?(cmds, &(&1 =~ "git checkout -B qa/cfx_web-canary deadbeef"))
      assert Enum.any?(cmds, &(&1 =~ "git add"))
      assert Enum.any?(cmds, &(&1 =~ "git push --force-with-lease -u origin qa/cfx_web-canary"))
    end

    test "regular push for reused branch (no checkout, no force)" do
      shell = fn cmd, _dir, _opts ->
        cond do
          cmd =~ "git add" ->
            {:ok, ""}

          cmd =~ "git commit" ->
            {:ok, ""}

          cmd =~ "git push" ->
            refute cmd =~ "force"
            refute cmd =~ "checkout"
            {:ok, ""}

          cmd =~ "git rev-parse HEAD" ->
            {:ok, "abc\n"}
        end
      end

      assert {:ok, "abc"} =
               GitOperations.commit_and_push(
                 "/repo",
                 "qa-existing",
                 ["foo.exs"],
                 "msg",
                 shell: shell,
                 create_new?: false
               )
    end

    test "stages only the listed files" do
      Process.put(:add_cmd, nil)

      shell = fn cmd, _dir, _opts ->
        if cmd =~ "git add" do
          Process.put(:add_cmd, cmd)
        end

        cond do
          cmd =~ "git rev-parse HEAD" -> {:ok, "x"}
          true -> {:ok, ""}
        end
      end

      _ =
        GitOperations.commit_and_push(
          "/repo",
          "b",
          ["a.exs", "b.exs"],
          "m",
          shell: shell,
          create_new?: false
        )

      add_cmd = Process.get(:add_cmd)
      assert add_cmd =~ "a.exs"
      assert add_cmd =~ "b.exs"
      refute add_cmd =~ "git add -A"
      refute add_cmd =~ "git add ."
    end
  end

  describe "revert_and_push/2" do
    test "runs git revert HEAD --no-edit && git push" do
      Process.put(:cmds, [])

      shell = fn cmd, _dir, _opts ->
        Process.put(:cmds, [cmd | Process.get(:cmds)])
        {:ok, ""}
      end

      assert :ok = GitOperations.revert_and_push("/repo", shell: shell)

      cmds = Enum.reverse(Process.get(:cmds))
      assert Enum.any?(cmds, &(&1 === "git revert HEAD --no-edit"))
      assert Enum.any?(cmds, &(&1 === "git push"))
    end
  end

  describe "delete_remote_branch/3" do
    test "runs git push origin --delete <branch>" do
      shell = fn cmd, _dir, _opts ->
        assert cmd === "git push origin --delete qa/cfx_web-canary"
        {:ok, ""}
      end

      assert :ok = GitOperations.delete_remote_branch("/repo", "qa/cfx_web-canary", shell: shell)
    end
  end
end
