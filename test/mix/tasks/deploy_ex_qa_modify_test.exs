defmodule Mix.Tasks.DeployEx.Qa.ModifyTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.DeployEx.Qa.Modify
  alias DeployEx.QaNode

  # The AWS/ansible side of qa.modify hits the network, so we drive only the
  # cert-reissue decision here with an injected `:recert_fn` fake (same `*_fn`
  # opts DI the repo already uses — see ToolInstaller `:consent_fn`). The fake
  # captures its call via a tagged message (per elixir-testing) so we can assert
  # exactly when it fires.

  describe "reissue_public_ip_cert_if_needed/3" do
    test "invokes recert when the IP changed and the node is in public-IP cert mode" do
      test_pid = self()
      node = %QaNode{app_name: "cfx_web", instance_id: "i-abc", use_public_ip_cert?: true, public_ip: "5.6.7.8"}

      recert_fn = fn passed_node, _opts ->
        send(test_pid, {:recert_called, passed_node})
        {:ok, passed_node}
      end

      assert {:ok, ^node} =
               Modify.reissue_public_ip_cert_if_needed(node, "1.2.3.4", quiet: true, recert_fn: recert_fn)

      assert_received {:recert_called, ^node}
    end

    test "does not invoke recert when the public IP is unchanged" do
      test_pid = self()
      node = %QaNode{app_name: "cfx_web", instance_id: "i-abc", use_public_ip_cert?: true, public_ip: "1.2.3.4"}

      recert_fn = fn passed_node, _opts ->
        send(test_pid, {:recert_called, passed_node})
        {:ok, passed_node}
      end

      assert {:ok, ^node} =
               Modify.reissue_public_ip_cert_if_needed(node, "1.2.3.4", quiet: true, recert_fn: recert_fn)

      refute_receive {:recert_called, _}, 50
    end

    test "does not invoke recert when the node is not in public-IP cert mode" do
      test_pid = self()
      node = %QaNode{app_name: "cfx_web", instance_id: "i-abc", use_public_ip_cert?: false, public_ip: "5.6.7.8"}

      recert_fn = fn passed_node, _opts ->
        send(test_pid, {:recert_called, passed_node})
        {:ok, passed_node}
      end

      assert {:ok, ^node} =
               Modify.reissue_public_ip_cert_if_needed(node, "1.2.3.4", quiet: true, recert_fn: recert_fn)

      refute_receive {:recert_called, _}, 50
    end

    test "propagates a recert failure as an error tuple" do
      node = %QaNode{app_name: "cfx_web", instance_id: "i-abc", use_public_ip_cert?: true, public_ip: "5.6.7.8"}
      error = ErrorMessage.failed_dependency("public-IP cert re-issue failed", %{})

      recert_fn = fn _node, _opts -> {:error, error} end

      assert {:error, ^error} =
               Modify.reissue_public_ip_cert_if_needed(node, "1.2.3.4", quiet: true, recert_fn: recert_fn)
    end
  end
end
