defmodule DeployEx.AwsSecurityGroupTest do
  use ExUnit.Case, async: true

  alias DeployEx.AwsSecurityGroup

  @opts [security_group_id: "sg-test", region: "us-west-2"]

  defp describe_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <DescribeSecurityGroupsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
      <securityGroupInfo>
        <item>
          <groupId>sg-test</groupId>
          <groupName>cfx-prod-sg</groupName>
          <vpcId>vpc-test</vpcId>
        </item>
      </securityGroupInfo>
    </DescribeSecurityGroupsResponse>
    """
  end

  describe "find_security_group/1" do
    test "resolves the group from a 200 response" do
      body = describe_xml()
      request_fn = fn _operation, _opts -> {:ok, %{body: body, status_code: 200}} end

      assert {:ok, %{id: "sg-test", name: "cfx-prod-sg", vpc_id: "vpc-test"}} =
               AwsSecurityGroup.find_security_group([{:request_fn, request_fn} | @opts])
    end

    test "a transport error (bare atom, the Hackney shape) returns an error instead of raising" do
      request_fn = fn _operation, _opts -> {:error, :eaddrnotavail} end

      assert {:error, %ErrorMessage{code: :failed_dependency} = error} =
               AwsSecurityGroup.find_security_group([{:request_fn, request_fn} | @opts])

      assert error.details.error =~ "eaddrnotavail"
      assert is_binary(ErrorMessage.to_string(error))
    end

    test "a transport error (the Req.TransportError struct shape) returns an error instead of raising" do
      request_fn = fn _operation, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end

      assert {:error, %ErrorMessage{code: :failed_dependency} = error} =
               AwsSecurityGroup.find_security_group([{:request_fn, request_fn} | @opts])

      assert error.details.error =~ "econnrefused"
      assert is_binary(ErrorMessage.to_string(error))
    end

    test "an AWS http error still maps to its own status code, not the transport catch-all" do
      request_fn = fn _operation, _opts ->
        {:error, {:http_error, 403, %{body: "<Response><Errors/></Response>"}}}
      end

      assert {:error, %ErrorMessage{code: :forbidden}} =
               AwsSecurityGroup.find_security_group([{:request_fn, request_fn} | @opts])
    end

    test "a group the response does not contain is reported as not found" do
      body = describe_xml()
      request_fn = fn _operation, _opts -> {:ok, %{body: body, status_code: 200}} end

      assert {:error, %ErrorMessage{code: :not_found}} =
               AwsSecurityGroup.find_security_group(
                 security_group_id: "sg-missing",
                 region: "us-west-2",
                 request_fn: request_fn
               )
    end
  end
end
