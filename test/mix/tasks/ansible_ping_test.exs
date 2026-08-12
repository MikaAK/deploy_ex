defmodule Mix.Tasks.Ansible.PingTest do
  use ExUnit.Case, async: true

  # parse_args/1 is private — mirror the OptionParser config here.
  # Same pattern as ansible_setup_test.exs / ansible_deploy_test.exs.

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args, switches: [provider: :string])
    opts
  end

  describe "parse_args/1 option parsing" do
    test "--provider parses to opts[:provider]" do
      opts = parse_args(["--provider", "oci"])
      assert opts[:provider] === "oci"
    end

    test "opts[:provider] is nil when --provider not passed" do
      opts = parse_args([])
      assert is_nil(opts[:provider])
    end

    test "unrelated ansible passthrough flags do not raise" do
      opts = parse_args(["-i", "custom.yaml", "--limit", "webservers"])
      assert is_nil(opts[:provider])
    end
  end
end
