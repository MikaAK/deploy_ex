defmodule DeployEx.AwsSecurityGroupTest do
  use ExUnit.Case, async: true

  alias DeployEx.AwsSecurityGroup

  describe "Cloud.Security conformance" do
    test "declares the behaviour" do
      assert DeployEx.Cloud.Security in (AwsSecurityGroup.module_info(:attributes)[:behaviour] || [])
    end

    test "exports every callback the behaviour declares" do
      Code.ensure_loaded!(AwsSecurityGroup)

      missing =
        DeployEx.Cloud.Security.behaviour_info(:callbacks)
        |> Enum.reject(fn {name, arity} ->
          function_exported?(AwsSecurityGroup, name, arity)
        end)

      assert missing === [], "AwsSecurityGroup is missing callbacks: #{inspect(missing)}"
    end

    test "the AWS descriptor resolves security to this module" do
      assert DeployEx.Cloud.capability(:security) === {:ok, AwsSecurityGroup}
    end
  end

  describe "classify_ingress_error/3" do
    test "maps an already-exists body to a conflict" do
      body = "<Response><Errors><Error><Message>the rule already exists</Message></Error></Errors></Response>"

      assert {:error, %ErrorMessage{code: :conflict}} =
               AwsSecurityGroup.classify_ingress_error(400, body, %{})
    end

    test "maps a does-not-exist body to not_found" do
      body = "<Response><Errors><Error><Message>the rule does not exist</Message></Error></Errors></Response>"

      assert {:error, %ErrorMessage{code: :not_found}} =
               AwsSecurityGroup.classify_ingress_error(400, body, %{})
    end

    test "falls back to the http code for any other message" do
      body = "<Response><Errors><Error><Message>something else broke</Message></Error></Errors></Response>"

      assert {:error, %ErrorMessage{message: "something else broke"}} =
               AwsSecurityGroup.classify_ingress_error(403, body, %{})
    end

    test "carries the supplied details through" do
      body = "<Response><Errors><Error><Message>nope</Message></Error></Errors></Response>"
      details = %{security_group_id: "sg-123", cidr: "1.2.3.4/32"}

      assert {:error, %ErrorMessage{details: ^details}} =
               AwsSecurityGroup.classify_ingress_error(400, body, details)
    end
  end

  describe "AwsIpWhitelister compatibility" do
    test "keeps its public API so its two task call sites are untouched" do
      Code.ensure_loaded!(DeployEx.AwsIpWhitelister)

      assert function_exported?(DeployEx.AwsIpWhitelister, :authorize, 3)
      assert function_exported?(DeployEx.AwsIpWhitelister, :deauthorize, 3)
    end

    test "holds no ExAws calls of its own — they moved into AwsSecurityGroup" do
      source = File.read!("lib/deploy_ex/aws_ip_whitelister.ex")

      refute source =~ "ExAws.",
             "aws_ip_whitelister.ex must hold zero ExAws calls after P0.2 absorbs them"
    end
  end
end
