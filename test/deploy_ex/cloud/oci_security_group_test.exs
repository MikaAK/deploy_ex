defmodule DeployEx.Cloud.OciSecurityGroupTest do
  use ExUnit.Case, async: true

  alias DeployEx.Cloud.OciSecurityGroup

  @compartment "ocid1.compartment.oc1..test"
  @nsg_id "ocid1.networksecuritygroup.oc1.ap-seoul-1.test"

  # Same seam OciObjectStoreTest uses: Process.put keeps the captured command per-test-PID, so
  # the suite stays async without a registry or an ETS table.
  defp stub(output) do
    [
      run_fn: fn command, _cwd ->
        Process.put(:last_command, command)

        case output do
          {:error, _} = error -> error
          stdout -> {:ok, stdout}
        end
      end
    ]
  end

  defp last_command, do: Process.get(:last_command)

  defp cli_failure(output) do
    {:error,
     ErrorMessage.internal_server_error("oci exited 1", %{output: output, code: 1, command: "oci"})}
  end

  describe "Cloud.Security conformance" do
    test "declares the behaviour" do
      assert DeployEx.Cloud.Security in (OciSecurityGroup.module_info(:attributes)[:behaviour] || [])
    end

    test "exports every callback the behaviour declares" do
      Code.ensure_loaded!(OciSecurityGroup)

      missing =
        DeployEx.Cloud.Security.behaviour_info(:callbacks)
        |> Enum.reject(fn {name, arity} -> function_exported?(OciSecurityGroup, name, arity) end)

      assert missing === [], "OciSecurityGroup is missing callbacks: #{inspect(missing)}"
    end

    test "the OCI descriptor resolves security to this module" do
      assert DeployEx.Cloud.capability(:security, provider: :oci) === {:ok, OciSecurityGroup}
    end
  end

  describe "authorize_ingress/3" do
    test "adds an ingress rule scoped to the given cidr and port 22" do
      assert OciSecurityGroup.authorize_ingress(@nsg_id, "203.0.113.5/32", stub("")) === :ok

      assert last_command() =~ "network nsg rules add"
      assert last_command() =~ "--nsg-id '#{@nsg_id}'"
      assert last_command() =~ ~s("direction":"INGRESS")
      assert last_command() =~ ~s("protocol":"6")
      assert last_command() =~ ~s("source":"203.0.113.5/32")
      assert last_command() =~ ~s("sourceType":"CIDR_BLOCK")
      assert last_command() =~ ~s("min":22)
      assert last_command() =~ ~s("max":22)
    end

    # PIN: adding a rule preserves existing rules. add_rule_command must never read the
    # current rule set and write a merged array back — it sends exactly the one new rule, which
    # is what makes the underlying `oci network nsg rules add` call additive rather than a
    # replace. A regression toward "read all, append, send the whole array" would still pass the
    # command-shape assertions above but fail this one.
    test "sends exactly one rule — it never reads or rewrites the existing set" do
      OciSecurityGroup.authorize_ingress(@nsg_id, "203.0.113.5/32", stub(""))

      [_prefix, rules_json] = String.split(last_command(), "--security-rules ", parts: 2)
      decoded = rules_json |> String.trim("'") |> Jason.decode!()

      assert length(decoded) === 1
    end

    test "a CLI failure surfaces as an ErrorMessage, not :ok" do
      assert {:error, %ErrorMessage{}} =
               OciSecurityGroup.authorize_ingress(@nsg_id, "203.0.113.5/32", stub(cli_failure("boom")))
    end
  end

  describe "revoke_ingress/3" do
    @two_rules ~s({"data": [
      {"id": "RULE1", "protocol": "6", "source": "203.0.113.5/32", "source-type": "CIDR_BLOCK",
       "tcp-options": {"destination-port-range": {"min": 22, "max": 22}}},
      {"id": "RULE2", "protocol": "6", "source": "198.51.100.9/32", "source-type": "CIDR_BLOCK",
       "tcp-options": {"destination-port-range": {"min": 22, "max": 22}}}
    ]})

    # PIN: revoking removes only the matching rule. Proves the removal targets RULE1's id and
    # never touches RULE2, which sits in the same NSG for a different CIDR.
    test "removes only the rule matching the cidr, by id" do
      assert OciSecurityGroup.revoke_ingress(@nsg_id, "203.0.113.5/32", stub(@two_rules)) === :ok

      assert last_command() =~ "network nsg rules remove"
      assert last_command() =~ ~s(["RULE1"])
      refute last_command() =~ "RULE2"
    end

    # PIN: revoking a rule that is not present is not an error — required for
    # `mix deploy_ex.ssh.authorize -r` to be safely re-runnable.
    test "a cidr with no matching rule is a no-op :ok, not an error" do
      rules = String.replace(@two_rules, "203.0.113.5/32", "192.0.2.1/32")

      assert OciSecurityGroup.revoke_ingress(@nsg_id, "203.0.113.5/32", stub(rules)) === :ok
      refute last_command() =~ "remove"
    end

    test "an empty rule list is a no-op :ok, not an error" do
      assert OciSecurityGroup.revoke_ingress(@nsg_id, "203.0.113.5/32", stub("")) === :ok
    end

    test "a rule on a different port is not a match even with the same source" do
      rules = ~s({"data": [
        {"id": "RULE3", "protocol": "6", "source": "203.0.113.5/32", "source-type": "CIDR_BLOCK",
         "tcp-options": {"destination-port-range": {"min": 80, "max": 80}}}
      ]})

      assert OciSecurityGroup.revoke_ingress(@nsg_id, "203.0.113.5/32", stub(rules)) === :ok
      refute last_command() =~ "remove"
    end

    test "listing fails loudly rather than silently no-op'ing" do
      assert {:error, %ErrorMessage{}} =
               OciSecurityGroup.revoke_ingress(@nsg_id, "203.0.113.5/32", stub(cli_failure("boom")))
    end
  end

  describe "find_group/1 — explicit override" do
    test "an explicit security_group_id is validated with a live get, then returned" do
      opts = stub(~s({"data": {"id": "#{@nsg_id}"}})) ++ [security_group_id: @nsg_id]

      assert OciSecurityGroup.find_group(opts) === {:ok, @nsg_id}
      assert last_command() =~ "network nsg get --nsg-id '#{@nsg_id}'"
    end

    test "a bad override id surfaces the not_found the CLI reports, not a silent wrong id" do
      output = ~s(ServiceError:\n{"status": 404, "message": "not found"})
      opts = stub(cli_failure(output)) ++ [security_group_id: @nsg_id]

      assert {:error, %ErrorMessage{code: :not_found}} = OciSecurityGroup.find_group(opts)
    end
  end

  describe "find_group/1 — prefix search" do
    test "finds the nsg matching <project>-<environment>-nsg, ignoring others" do
      payload = ~s({"data": [
        {"display-name": "old-myapp-dev-nsg", "id": "ocid1.nsg.decoy"},
        {"display-name": "myapp-dev-nsg", "id": "#{@nsg_id}"}
      ]})

      opts = stub(payload) ++ [oci_compartment_id: @compartment, project_name: "myapp", environment: "dev"]

      assert OciSecurityGroup.find_group(opts) === {:ok, @nsg_id}
    end

    test "no match is a not_found naming the searched prefix" do
      payload = ~s({"data": [{"display-name": "other-app-dev-nsg", "id": "ocid1.nsg.other"}]})
      opts = stub(payload) ++ [oci_compartment_id: @compartment, project_name: "myapp", environment: "dev"]

      assert {:error, %ErrorMessage{code: :not_found} = error} = OciSecurityGroup.find_group(opts)
      assert error.message =~ "myapp-dev-nsg"
    end

    test "a missing compartment_id is a bad_request naming the config key, not a crash" do
      assert {:error, %ErrorMessage{code: :bad_request} = error} =
               OciSecurityGroup.find_group(stub(~s({"data": []})))

      assert error.message =~ "compartment_id"
    end
  end
end
