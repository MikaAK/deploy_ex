defmodule DeployEx.PrivRendererTest do
  use ExUnit.Case, async: true

  alias DeployEx.PrivRenderer

  setup do
    on_exit(fn ->
      # Clean up any temp dirs left behind by failed tests
      :ok
    end)

    :ok
  end

  describe "render_to_temp/1" do
    test "returns {:ok, temp_dir} where temp_dir exists" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      assert File.exists?(temp_dir)
      assert File.dir?(temp_dir)
    end

    test "temp dir contains rendered terraform files without .eex extension" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      terraform_dir = Path.join(temp_dir, "terraform")
      assert File.dir?(terraform_dir)

      # Rendered files should exist without .eex
      assert File.exists?(Path.join(terraform_dir, "variables.tf"))
      assert File.exists?(Path.join(terraform_dir, "ec2.tf"))
      assert File.exists?(Path.join(terraform_dir, "providers.tf"))
      assert File.exists?(Path.join(terraform_dir, "key-pair-main.tf"))
      assert File.exists?(Path.join(terraform_dir, "outputs.tf"))
      assert File.exists?(Path.join(terraform_dir, "database.tf"))

      # No .eex files should remain
      eex_files = Path.join(terraform_dir, "*.eex") |> Path.wildcard()
      assert Enum.empty?(eex_files)
    end

    test "temp dir contains static terraform modules" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      modules_dir = Path.join(temp_dir, "terraform/modules")
      assert File.dir?(modules_dir)
      assert File.dir?(Path.join(modules_dir, "aws-instance"))
      assert File.exists?(Path.join(modules_dir, "aws-instance/main.tf"))
      assert File.dir?(Path.join(modules_dir, "aws-database"))
    end

    test "temp dir contains static terraform files" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      terraform_dir = Path.join(temp_dir, "terraform")
      assert File.exists?(Path.join(terraform_dir, "network.tf"))
      assert File.exists?(Path.join(terraform_dir, "bucket.tf"))
      assert File.exists?(Path.join(terraform_dir, "iam.tf"))
    end

    test "temp dir contains ansible roles" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      ansible_dir = Path.join(temp_dir, "ansible")
      assert File.dir?(ansible_dir)
      assert File.dir?(Path.join(ansible_dir, "roles"))
      assert File.dir?(Path.join(ansible_dir, "roles/elixir_runner"))
    end

    test "temp dir contains rendered ansible config files" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      ansible_dir = Path.join(temp_dir, "ansible")
      assert File.exists?(Path.join(ansible_dir, "ansible.cfg"))
      assert File.exists?(Path.join(ansible_dir, "aws_ec2.yaml"))
      assert File.exists?(Path.join(ansible_dir, "group_vars/all.yaml"))

      # No .eex files should remain in ansible root
      eex_files = Path.join(ansible_dir, "*.eex") |> Path.wildcard()
      assert Enum.empty?(eex_files)
    end

    test "rendered terraform files contain valid content" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      variables_content = Path.join(temp_dir, "terraform/variables.tf") |> File.read!()
      assert variables_content =~ "variable"
      assert variables_content =~ "environment"
    end

    test "rendered ansible config contains expected structure" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      config_content = Path.join(temp_dir, "ansible/ansible.cfg") |> File.read!()
      assert config_content =~ "[defaults]"
      assert config_content =~ "remote_user"
    end

    test "temp dir contains ansible setup playbooks" do
      assert {:ok, temp_dir} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      ansible_dir = Path.join(temp_dir, "ansible")
      assert File.dir?(Path.join(ansible_dir, "setup"))
    end

    test "each call creates a unique temp dir" do
      assert {:ok, dir1} = PrivRenderer.render_to_temp()
      assert {:ok, dir2} = PrivRenderer.render_to_temp()
      on_exit(fn -> File.rm_rf!(dir1); File.rm_rf!(dir2) end)

      refute dir1 === dir2
    end
  end
end
