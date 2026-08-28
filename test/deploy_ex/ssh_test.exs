defmodule DeployEx.SSHTest do
  use ExUnit.Case, async: true

  alias DeployEx.SSH

  @rsa_pem """
  -----BEGIN RSA PRIVATE KEY-----
  MIIEowIBAAKCAQEAtest
  -----END RSA PRIVATE KEY-----
  """

  @openssh_ed25519_pem """
  -----BEGIN OPENSSH PRIVATE KEY-----
  b3BlbnNzaC1rZXktdjEAAAAAtest
  -----END OPENSSH PRIVATE KEY-----
  """

  describe "connect_options/2 — pure :ssh.connect options builder (LT-OCI review-fix)" do
    test "carries the given user as a charlist under :user" do
      opts = SSH.connect_options("1.2.3.4", "admin", "/tmp/key_dir")

      assert opts[:user] === ~c"admin"
    end

    test "resolves a non-default ssh user (e.g. OCI's ubuntu)" do
      opts = SSH.connect_options("1.2.3.4", "ubuntu", "/tmp/key_dir")

      assert opts[:user] === ~c"ubuntu"
    end

    test "carries the given key dir as a charlist under :user_dir" do
      opts = SSH.connect_options("1.2.3.4", "admin", "/tmp/some_key_dir")

      assert opts[:user_dir] === ~c"/tmp/some_key_dir"
    end
  end

  describe "identity_filename/1 (LT-D12: pem loading for arbitrary filenames)" do
    test "classifies a traditional RSA PEM as id_rsa" do
      assert SSH.identity_filename(@rsa_pem) === "id_rsa"
    end

    test "classifies an OpenSSH-format key (AWS ed25519 export) as id_ed25519" do
      assert SSH.identity_filename(@openssh_ed25519_pem) === "id_ed25519"
    end
  end

  describe "prepare_identity_dir/1 (LT-D12: standard-name staging for :ssh_file)" do
    setup do
      tmp_pem = Path.join(System.tmp_dir!(), "ssh_test_#{System.unique_integer([:positive])}.pem")
      on_exit(fn -> File.rm(tmp_pem) end)
      %{tmp_pem: tmp_pem}
    end

    test "stages an RSA pem under id_rsa with owner-only permissions", %{tmp_pem: tmp_pem} do
      File.write!(tmp_pem, @rsa_pem)

      assert {:ok, key_dir} = SSH.prepare_identity_dir(tmp_pem)
      on_exit(fn -> File.rm_rf(key_dir) end)

      identity_path = Path.join(key_dir, "id_rsa")
      assert File.read!(identity_path) === @rsa_pem
      assert {:ok, %File.Stat{mode: mode}} = File.stat(identity_path)
      assert Bitwise.band(mode, 0o777) === 0o600
    end

    test "stages an ed25519 (OpenSSH-format) pem under id_ed25519, arbitrary source filename", %{tmp_pem: tmp_pem} do
      File.write!(tmp_pem, @openssh_ed25519_pem)

      assert {:ok, key_dir} = SSH.prepare_identity_dir(tmp_pem)
      on_exit(fn -> File.rm_rf(key_dir) end)

      assert File.exists?(Path.join(key_dir, "id_ed25519"))
      refute File.exists?(Path.join(key_dir, "id_rsa"))
    end

    test "propagates a read error for a missing pem file" do
      assert {:error, :enoent} = SSH.prepare_identity_dir("/tmp/does-not-exist-#{System.unique_integer([:positive])}.pem")
    end
  end
end
