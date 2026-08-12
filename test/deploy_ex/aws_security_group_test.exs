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

  describe "describe_security_groups/2 pagination (via find_security_group/1)" do
    defp queue_responses(responses), do: Process.put(:responses, responses)

    defp next_response do
      [head | rest] = Process.get(:responses)
      Process.put(:responses, rest)
      Process.put(:call_count, (Process.get(:call_count) || 0) + 1)
      head
    end

    defp call_count, do: Process.get(:call_count) || 0

    defp recording_request_fn do
      fn _request, _config -> next_response() end
    end

    defp sg_page(groups, next_token) do
      items =
        Enum.map_join(groups, "", fn {group_id, group_name} ->
          "<item><groupId>#{group_id}</groupId><groupName>#{group_name}</groupName>" <>
            "<vpcId>vpc-1</vpcId></item>"
        end)

      token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

      {:ok,
       %{
         body:
           "<DescribeSecurityGroupsResponse><securityGroupInfo>#{items}</securityGroupInfo>" <>
             "#{token}</DescribeSecurityGroupsResponse>"
       }}
    end

    test "a security group past page one is still found rather than reporting not_found" do
      queue_responses([
        sg_page([{"sg-other", "other-sg"}], "TOKEN"),
        sg_page([{"sg-mine", "myapp-sg"}], nil)
      ])

      assert AwsSecurityGroup.find_security_group(project_name: "myapp", request_fn: recording_request_fn()) ===
               {:ok, %{id: "sg-mine", vpc_id: "vpc-1", name: "myapp-sg"}}
    end

    test "terminates when no nextToken comes back" do
      queue_responses([sg_page([{"sg-mine", "myapp-sg"}], nil)])

      assert {:ok, %{id: "sg-mine"}} =
               AwsSecurityGroup.find_security_group(project_name: "myapp", request_fn: recording_request_fn())

      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial match" do
      queue_responses([
        sg_page([{"sg-other", "other-sg"}], "TOKEN"),
        {:error, {:http_error, 500, %{body: "boom"}}}
      ])

      assert {:error, %ErrorMessage{}} =
               AwsSecurityGroup.find_security_group(project_name: "myapp", request_fn: recording_request_fn())
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
