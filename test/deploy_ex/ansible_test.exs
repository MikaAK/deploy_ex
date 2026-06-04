defmodule DeployEx.AnsibleTest do
  use ExUnit.Case, async: true

  alias DeployEx.Ansible

  describe "parse_args/1" do
    test "forwards --tags" do
      assert "--tags thetadata_terminal" === Ansible.parse_args(["--tags", "thetadata_terminal"])
    end

    test "forwards -t alias as --tags" do
      assert "--tags thetadata_terminal" === Ansible.parse_args(["-t", "thetadata_terminal"])
    end

    test "forwards --skip-tags" do
      assert "--skip-tags save_ami" === Ansible.parse_args(["--skip-tags", "save_ami"])
    end

    test "forwards --limit alongside --tags" do
      assert "--limit i-0abc* --tags thetadata_terminal" ===
               Ansible.parse_args(["--limit", "i-0abc*", "--tags", "thetadata_terminal"])
    end

    test "drops unknown flags" do
      assert "--tags thetadata_terminal" ===
               Ansible.parse_args(["--unknown", "x", "--tags", "thetadata_terminal"])
    end
  end
end
