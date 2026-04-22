defmodule DeployEx.QaPlaybookTest do
  use ExUnit.Case, async: true

  alias DeployEx.{QaNode, QaPlaybook}

  describe "render_playbook/3" do
    test "setup kind imports ../setup/<app>.yaml with vars block" do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      yaml = QaPlaybook.render_playbook(qa_node, :setup, letsencrypt_use_public_ip: true)

      assert yaml =~ "import_playbook: ../setup/my_app.yaml"
      assert yaml =~ "vars:"
      assert yaml =~ "letsencrypt_use_public_ip: true"
    end

    test "deploy kind imports ../playbooks/<app>.yaml" do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      yaml = QaPlaybook.render_playbook(qa_node, :deploy, target_release_sha: "abc1234")

      assert yaml =~ "import_playbook: ../playbooks/my_app.yaml"
      assert yaml =~ "target_release_sha: \"abc1234\""
    end

    test "drops nil and empty-string vars from the rendered block" do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      yaml =
        QaPlaybook.render_playbook(qa_node, :setup,
          git_branch: nil,
          instance_tag: "",
          letsencrypt_use_public_ip: false
        )

      refute yaml =~ "git_branch"
      refute yaml =~ "instance_tag"
      assert yaml =~ "letsencrypt_use_public_ip: false"
    end

    test "booleans render unquoted; strings render quoted" do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      yaml =
        QaPlaybook.render_playbook(qa_node, :deploy,
          letsencrypt_use_public_ip: true,
          git_branch: "feat/my-branch"
        )

      assert yaml =~ "letsencrypt_use_public_ip: true"
      refute yaml =~ "letsencrypt_use_public_ip: \"true\""
      assert yaml =~ "git_branch: \"feat/my-branch\""
    end

    test "escapes embedded double quotes in string vars" do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      yaml = QaPlaybook.render_playbook(qa_node, :deploy, instance_tag: ~s(tag with "quotes"))

      assert yaml =~ ~s(instance_tag: "tag with \\"quotes\\"")
    end

    test "omits the vars block entirely when no vars remain after filtering" do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      yaml = QaPlaybook.render_playbook(qa_node, :setup, [])

      assert yaml =~ "import_playbook: ../setup/my_app.yaml"
      refute yaml =~ "vars:"
    end

    test "omits vars block when all provided vars are blank" do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      yaml = QaPlaybook.render_playbook(qa_node, :deploy, git_branch: nil, instance_tag: "")

      assert yaml =~ "import_playbook: ../playbooks/my_app.yaml"
      refute yaml =~ "vars:"
    end
  end

  describe "with_temp_playbook/5" do
    setup do
      dir = Path.join(System.tmp_dir!(), "deploy_ex_qa_playbook_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "writes the wrapper, invokes the callback with a relative path, and deletes it", %{dir: dir} do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      result =
        QaPlaybook.with_temp_playbook(qa_node, :setup, [git_branch: "main"], dir, fn rel_path ->
          abs_path = Path.join(dir, rel_path)
          assert File.exists?(abs_path)
          assert rel_path === ".qa_tmp/i-abc-setup.yml"
          contents = File.read!(abs_path)
          assert contents =~ "import_playbook: ../setup/my_app.yaml"
          :callback_returned
        end)

      assert result === :callback_returned
      refute File.exists?(Path.join(dir, ".qa_tmp/i-abc-setup.yml"))
    end

    test "creates .gitignore inside .qa_tmp the first time", %{dir: dir} do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-abc", target_sha: "sha"}

      QaPlaybook.with_temp_playbook(qa_node, :setup, [], dir, fn _ -> :ok end)

      gitignore = Path.join(dir, ".qa_tmp/.gitignore")
      assert File.exists?(gitignore)
      assert File.read!(gitignore) === "*\n!.gitignore\n"
    end

    test "deletes the wrapper even when the callback raises", %{dir: dir} do
      qa_node = %QaNode{app_name: "my_app", instance_id: "i-boom", target_sha: "sha"}

      assert_raise RuntimeError, "boom", fn ->
        QaPlaybook.with_temp_playbook(qa_node, :setup, [], dir, fn _ ->
          raise "boom"
        end)
      end

      refute File.exists?(Path.join(dir, ".qa_tmp/i-boom-setup.yml"))
    end
  end
end
