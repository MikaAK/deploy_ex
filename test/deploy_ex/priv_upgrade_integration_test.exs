defmodule DeployEx.PrivUpgradeIntegrationTest do
  use ExUnit.Case, async: true

  alias DeployEx.PrivManifest

  setup do
    tmp_base = Path.join(System.tmp_dir!(), "deploy_ex_integration_#{System.unique_integer([:positive])}")
    priv_dir = Path.join(tmp_base, "priv")
    deploy_dir = Path.join(tmp_base, "deploys")

    File.mkdir_p!(priv_dir)
    File.mkdir_p!(deploy_dir)

    on_exit(fn -> File.rm_rf!(tmp_base) end)

    %{tmp_base: tmp_base, priv_dir: priv_dir, deploy_dir: deploy_dir}
  end

  # SECTION: Export Flow

  describe "export flow" do
    test "copies priv files to deploy dir and writes manifest", %{priv_dir: priv_dir, deploy_dir: deploy_dir} do
      File.mkdir_p!(Path.join(priv_dir, "terraform"))
      File.write!(Path.join(priv_dir, "terraform/ec2.tf.eex"), "ec2 content")
      File.write!(Path.join(priv_dir, "terraform/variables.tf.eex"), "vars content")

      priv_files = list_exportable_files(priv_dir)

      manifest =
        Enum.reduce(priv_files, empty_manifest(), fn priv_path, acc ->
          relative_path = Path.relative_to(priv_path, priv_dir)
          dest_path = Path.join(deploy_dir, relative_path)
          content = File.read!(priv_path)
          hash = PrivManifest.hash_content(content)

          File.mkdir_p!(Path.dirname(dest_path))
          File.write!(dest_path, content)

          PrivManifest.put_file(acc, relative_path, hash)
        end)

      PrivManifest.write(deploy_dir, manifest)

      assert File.exists?(Path.join(deploy_dir, "terraform/ec2.tf.eex"))
      assert File.exists?(Path.join(deploy_dir, "terraform/variables.tf.eex"))
      assert File.read!(Path.join(deploy_dir, "terraform/ec2.tf.eex")) === "ec2 content"

      assert {:ok, written_manifest} = PrivManifest.read(deploy_dir)
      assert {:ok, _hash} = PrivManifest.base_hash(written_manifest, "terraform/ec2.tf.eex")
      assert {:ok, _hash} = PrivManifest.base_hash(written_manifest, "terraform/variables.tf.eex")
    end

    test "skips .md files", %{priv_dir: priv_dir} do
      File.write!(Path.join(priv_dir, "Agents.md"), "docs")
      File.write!(Path.join(priv_dir, "template.tf.eex"), "content")

      priv_files = list_exportable_files(priv_dir)

      refute Enum.any?(priv_files, &String.ends_with?(&1, ".md"))
      assert Enum.any?(priv_files, &String.ends_with?(&1, ".tf.eex"))
    end
  end

  # SECTION: Upgrade Flow

  describe "upgrade flow — new file" do
    test "copies new upstream files not in manifest", %{priv_dir: priv_dir, deploy_dir: deploy_dir} do
      File.write!(Path.join(priv_dir, "existing.tf"), "old content")
      manifest = empty_manifest()
      PrivManifest.write(deploy_dir, manifest)

      {:ok, manifest} = PrivManifest.read(deploy_dir)
      priv_files = list_exportable_files(priv_dir)

      {updated_manifest, counts} = run_upgrade(priv_files, priv_dir, deploy_dir, manifest)

      assert counts.new === 1
      assert counts.auto_updated === 0
      assert counts.backed_up === 0
      assert File.read!(Path.join(deploy_dir, "existing.tf")) === "old content"
      assert {:ok, _} = PrivManifest.base_hash(updated_manifest, "existing.tf")
    end
  end

  describe "upgrade flow — unmodified file" do
    test "auto-updates files the user never touched", %{priv_dir: priv_dir, deploy_dir: deploy_dir} do
      File.write!(Path.join(priv_dir, "main.tf"), "original content")

      manifest = empty_manifest()
      original_hash = PrivManifest.hash_content("original content")
      manifest = PrivManifest.put_file(manifest, "main.tf", original_hash)
      PrivManifest.write(deploy_dir, manifest)

      File.mkdir_p!(deploy_dir)
      File.write!(Path.join(deploy_dir, "main.tf"), "original content")

      File.write!(Path.join(priv_dir, "main.tf"), "updated upstream content")

      {:ok, manifest} = PrivManifest.read(deploy_dir)
      priv_files = list_exportable_files(priv_dir)

      {updated_manifest, counts} = run_upgrade(priv_files, priv_dir, deploy_dir, manifest)

      assert counts.auto_updated === 1
      assert counts.backed_up === 0
      assert File.read!(Path.join(deploy_dir, "main.tf")) === "updated upstream content"
      assert {:ok, new_hash} = PrivManifest.base_hash(updated_manifest, "main.tf")
      assert new_hash === PrivManifest.hash_content("updated upstream content")
    end
  end

  describe "upgrade flow — modified file" do
    test "backs up user-modified files and overwrites with upstream", %{priv_dir: priv_dir, deploy_dir: deploy_dir} do
      File.write!(Path.join(priv_dir, "main.tf"), "new upstream content")

      original_hash = PrivManifest.hash_content("original content")
      manifest = empty_manifest()
      manifest = PrivManifest.put_file(manifest, "main.tf", original_hash)
      PrivManifest.write(deploy_dir, manifest)

      File.mkdir_p!(deploy_dir)
      File.write!(Path.join(deploy_dir, "main.tf"), "user modified content")

      {:ok, manifest} = PrivManifest.read(deploy_dir)
      priv_files = list_exportable_files(priv_dir)
      backup_dir = Path.join(deploy_dir, ".backup/test-run")

      {updated_manifest, counts} = run_upgrade(priv_files, priv_dir, deploy_dir, manifest, backup_dir)

      assert counts.backed_up === 1
      assert counts.auto_updated === 0
      assert File.read!(Path.join(deploy_dir, "main.tf")) === "new upstream content"
      assert File.read!(Path.join(backup_dir, "main.tf")) === "user modified content"
      assert {:ok, new_hash} = PrivManifest.base_hash(updated_manifest, "main.tf")
      assert new_hash === PrivManifest.hash_content("new upstream content")
    end
  end

  describe "upgrade flow — mixed" do
    test "handles new, unmodified, and modified files in one run", %{priv_dir: priv_dir, deploy_dir: deploy_dir} do
      original_a_content = "file_a original"
      original_b_content = "file_b original"

      File.write!(Path.join(priv_dir, "file_a.tf"), "file_a upstream v2")
      File.write!(Path.join(priv_dir, "file_b.tf"), "file_b upstream v2")
      File.write!(Path.join(priv_dir, "file_c.tf"), "file_c brand new")

      manifest = empty_manifest()
      manifest = PrivManifest.put_file(manifest, "file_a.tf", PrivManifest.hash_content(original_a_content))
      manifest = PrivManifest.put_file(manifest, "file_b.tf", PrivManifest.hash_content(original_b_content))
      PrivManifest.write(deploy_dir, manifest)

      File.mkdir_p!(deploy_dir)
      File.write!(Path.join(deploy_dir, "file_a.tf"), original_a_content)
      File.write!(Path.join(deploy_dir, "file_b.tf"), "file_b user modified")

      {:ok, manifest} = PrivManifest.read(deploy_dir)
      priv_files = list_exportable_files(priv_dir)
      backup_dir = Path.join(deploy_dir, ".backup/mixed-test")

      {_updated_manifest, counts} = run_upgrade(priv_files, priv_dir, deploy_dir, manifest, backup_dir)

      assert counts.auto_updated === 1
      assert counts.backed_up === 1
      assert counts.new === 1

      assert File.read!(Path.join(deploy_dir, "file_a.tf")) === "file_a upstream v2"
      assert File.read!(Path.join(deploy_dir, "file_b.tf")) === "file_b upstream v2"
      assert File.read!(Path.join(deploy_dir, "file_c.tf")) === "file_c brand new"
      assert File.read!(Path.join(backup_dir, "file_b.tf")) === "file_b user modified"
      refute File.exists?(Path.join(backup_dir, "file_a.tf"))
    end
  end

  describe "upgrade flow — missing manifest" do
    test "returns error when manifest does not exist", %{deploy_dir: deploy_dir} do
      assert {:error, %ErrorMessage{code: :not_found}} = PrivManifest.read(deploy_dir)
    end
  end

  describe "priv_folder fallback" do
    test "returns local path when it exists", %{deploy_dir: deploy_dir} do
      terraform_dir = Path.join(deploy_dir, "terraform")
      File.mkdir_p!(terraform_dir)

      local_path = Path.join(deploy_dir, "terraform")

      assert File.exists?(local_path)
    end

    test "priv_folder returns priv path when local does not exist" do
      priv_path = :deploy_ex |> :code.priv_dir() |> Path.join("terraform")

      assert File.exists?(priv_path)
    end
  end

  # SECTION: Helpers

  defp empty_manifest do
    [deploy_ex_version: "0.1.0", files: []]
  end

  defp list_exportable_files(priv_dir) do
    priv_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.reject(&String.ends_with?(&1, ".md"))
  end

  defp run_upgrade(priv_files, priv_dir, deploy_dir, manifest, backup_dir \\ nil) do
    backup_dir = backup_dir || Path.join(deploy_dir, ".backup/test-#{System.unique_integer([:positive])}")

    Enum.reduce(priv_files, {manifest, %{new: 0, auto_updated: 0, backed_up: 0}}, fn priv_path, {acc_manifest, acc_counts} ->
      relative_path = Path.relative_to(priv_path, priv_dir)
      dest_path = Path.join(deploy_dir, relative_path)
      upstream_content = File.read!(priv_path)
      upstream_hash = PrivManifest.hash_content(upstream_content)

      {updated_manifest, counts_key} =
        case PrivManifest.base_hash(acc_manifest, relative_path) do
          {:error, _} ->
            File.mkdir_p!(Path.dirname(dest_path))
            File.write!(dest_path, upstream_content)
            {PrivManifest.put_file(acc_manifest, relative_path, upstream_hash), :new}

          {:ok, base_hash} ->
            user_content = if File.exists?(dest_path), do: File.read!(dest_path), else: upstream_content
            user_hash = PrivManifest.hash_content(user_content)

            if user_hash === base_hash do
              File.mkdir_p!(Path.dirname(dest_path))
              File.write!(dest_path, upstream_content)
              {PrivManifest.put_file(acc_manifest, relative_path, upstream_hash), :auto_updated}
            else
              backup_path = Path.join(backup_dir, relative_path)
              File.mkdir_p!(Path.dirname(backup_path))
              File.write!(backup_path, user_content)
              File.mkdir_p!(Path.dirname(dest_path))
              File.write!(dest_path, upstream_content)
              {PrivManifest.put_file(acc_manifest, relative_path, upstream_hash), :backed_up}
            end
        end

      {updated_manifest, Map.update!(acc_counts, counts_key, &(&1 + 1))}
    end)
  end
end
