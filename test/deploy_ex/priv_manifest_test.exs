defmodule DeployEx.PrivManifestTest do
  use ExUnit.Case, async: true

  alias DeployEx.PrivManifest

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "deploy_ex_manifest_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "hash_content/1" do
    test "returns sha256 prefixed 64-char hex hash" do
      result = PrivManifest.hash_content("hello")

      assert String.starts_with?(result, "sha256:")
      assert String.length(result) === 71
    end

    test "same content returns same hash" do
      assert PrivManifest.hash_content("foo") === PrivManifest.hash_content("foo")
    end

    test "different content returns different hash" do
      refute PrivManifest.hash_content("foo") === PrivManifest.hash_content("bar")
    end
  end

  describe "put_file/3 and base_hash/2" do
    test "put_file adds a new file entry and base_hash retrieves it" do
      manifest = [deploy_ex_version: "0.1.0", files: []]

      updated = PrivManifest.put_file(manifest, "terraform/ec2.tf.eex", "sha256:abc")

      assert {:ok, "sha256:abc"} === PrivManifest.base_hash(updated, "terraform/ec2.tf.eex")
    end

    test "put_file updates existing file entry" do
      manifest = [deploy_ex_version: "0.1.0", files: []]
      manifest = PrivManifest.put_file(manifest, "terraform/ec2.tf.eex", "sha256:abc")
      manifest = PrivManifest.put_file(manifest, "terraform/ec2.tf.eex", "sha256:def")

      assert {:ok, "sha256:def"} === PrivManifest.base_hash(manifest, "terraform/ec2.tf.eex")
    end

    test "put_file preserves other entries when updating" do
      manifest = [deploy_ex_version: "0.1.0", files: []]
      manifest = PrivManifest.put_file(manifest, "terraform/ec2.tf.eex", "sha256:abc")
      manifest = PrivManifest.put_file(manifest, "ansible/ansible.cfg.eex", "sha256:xyz")
      manifest = PrivManifest.put_file(manifest, "terraform/ec2.tf.eex", "sha256:def")

      assert {:ok, "sha256:xyz"} === PrivManifest.base_hash(manifest, "ansible/ansible.cfg.eex")
    end

    test "base_hash returns error for unknown path" do
      manifest = [deploy_ex_version: "0.1.0", files: []]

      assert {:error, %ErrorMessage{}} = PrivManifest.base_hash(manifest, "unknown/path.tf")
    end
  end

  describe "write/2 and read/1" do
    test "round-trips manifest through file", %{tmp_dir: tmp_dir} do
      manifest = [deploy_ex_version: "0.1.0", files: []]
      manifest = PrivManifest.put_file(manifest, "terraform/ec2.tf.eex", "sha256:abc123")

      :ok = PrivManifest.write(tmp_dir, manifest)
      assert {:ok, read_manifest} = PrivManifest.read(tmp_dir)

      assert Keyword.get(read_manifest, :deploy_ex_version) === "0.1.0"

      assert {:ok, "sha256:abc123"} ===
               PrivManifest.base_hash(read_manifest, "terraform/ec2.tf.eex")
    end

    test "written manifest file is valid Elixir source", %{tmp_dir: tmp_dir} do
      manifest = [deploy_ex_version: "0.1.0", files: []]
      :ok = PrivManifest.write(tmp_dir, manifest)

      manifest_path = Path.join(tmp_dir, ".deploy_ex_manifest.exs")
      assert {result, _} = Code.eval_file(manifest_path)
      assert is_list(result)
    end

    test "read returns error when manifest does not exist", %{tmp_dir: tmp_dir} do
      assert {:error, %ErrorMessage{}} = PrivManifest.read(Path.join(tmp_dir, "nonexistent"))
    end
  end
end
