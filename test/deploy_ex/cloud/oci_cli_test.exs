defmodule DeployEx.Cloud.OciCliTest do
  @moduledoc """
  Behavioural tests for `DeployEx.Cloud.OciCli` — LT-OCI S2 review-fix (SECURITY).

  `:auth`/`:profile`/`:region` interpolate directly into a shell command string
  (`OCI_CLI_AUTH=<auth> ... --profile <profile> --region <region>`); every test here proves
  the composed command quotes those values instead of executing a hostile payload — no test
  in this file ever runs a real shell, only inspects the string `:run_fn` captures.
  """

  use ExUnit.Case, async: true

  alias DeployEx.Cloud.OciCli

  defp capture_command(response \\ {:ok, "output"}) do
    fn command, _cwd ->
      send(self(), {:oci_command, command})
      response
    end
  end

  describe "build_command (via run/2) — shell injection guard" do
    test "a hostile :auth setting is quoted, not executed as a second shell command" do
      OciCli.run("os bucket list", oci_auth: "api_key; touch /tmp/PWNED", run_fn: capture_command())

      assert_received {:oci_command, command}
      assert command =~ "OCI_CLI_AUTH='api_key; touch /tmp/PWNED'"
      refute command =~ ~r/OCI_CLI_AUTH=api_key;/
    end

    test "a hostile :profile setting is quoted, not executed" do
      OciCli.run("os bucket list", oci_profile: "DEFAULT`touch /tmp/PWNED`", run_fn: capture_command())

      assert_received {:oci_command, command}
      assert command =~ "--profile 'DEFAULT`touch /tmp/PWNED`'"
    end

    test "a hostile :region setting is quoted, not executed" do
      OciCli.run("os bucket list", oci_region: "us-phoenix-1 && touch /tmp/PWNED", run_fn: capture_command())

      assert_received {:oci_command, command}
      assert command =~ "--region 'us-phoenix-1 && touch /tmp/PWNED'"
    end

    test "a value containing a single quote is escaped, not left to break out of quoting" do
      OciCli.run("os bucket list", oci_profile: "it's-a-profile", run_fn: capture_command())

      assert_received {:oci_command, command}
      assert command =~ "--profile 'it'\\''s-a-profile'"
    end

    test "the default auth (no override) is still quoted" do
      OciCli.run("os bucket list", run_fn: capture_command())

      assert_received {:oci_command, command}
      assert command =~ "OCI_CLI_AUTH='api_key'"
    end

    test "well-behaved settings still produce a working command (no functional regression)" do
      OciCli.run("os bucket list", oci_profile: "DEFAULT", oci_region: "us-phoenix-1", run_fn: capture_command())

      assert_received {:oci_command, command}
      assert command =~ "--profile 'DEFAULT'"
      assert command =~ "--region 'us-phoenix-1'"
      assert command =~ "oci os bucket list"
    end
  end
end
