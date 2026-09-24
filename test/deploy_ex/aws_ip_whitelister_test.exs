defmodule DeployEx.AwsIpWhitelisterTest do
  use ExUnit.Case, async: true

  alias DeployEx.AwsIpWhitelister

  # Fixture helpers -----------------------------------------------------------------------

  defp ok_response do
    fn _operation, _opts -> {:ok, %{body: "<Response/>", status_code: 200}} end
  end

  defp security_group_xml(permissions_xml) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <DescribeSecurityGroupsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
      <securityGroupInfo>
        <item>
          <groupId>sg-test</groupId>
          #{permissions_xml}
        </item>
      </securityGroupInfo>
    </DescribeSecurityGroupsResponse>
    """
  end

  defp permission_present_xml(cidr) do
    """
    <ipPermissions>
      <item>
        <ipProtocol>tcp</ipProtocol>
        <fromPort>22</fromPort>
        <toPort>22</toPort>
        <ipRanges>
          <item><cidrIp>#{cidr}/32</cidrIp></item>
        </ipRanges>
      </item>
    </ipPermissions>
    """
  end

  defp permission_absent_xml, do: "<ipPermissions/>"

  defp describe_response(permissions_xml) do
    body = security_group_xml(permissions_xml)
    fn _operation, _opts -> {:ok, %{body: body, status_code: 200}} end
  end

  # authorize/3 and deauthorize/3 ----------------------------------------------------------

  describe "deauthorize/3" do
    test "returns :ok on a clean 200 response" do
      assert AwsIpWhitelister.deauthorize("sg-test", "1.2.3.4", request_fn: ok_response()) === :ok
    end

    test "a transport error (bare atom, the Hackney shape) returns {:error, %ErrorMessage{}} without raising" do
      failing = fn _operation, _opts -> {:error, :eaddrnotavail} end

      assert {:error, %ErrorMessage{code: :failed_dependency} = error} =
               AwsIpWhitelister.deauthorize("sg-test", "1.2.3.4", request_fn: failing)

      assert error.details.error =~ "eaddrnotavail"
      # Must be safely formattable — this is exactly the crash this fix eliminates.
      assert is_binary(ErrorMessage.to_string(error))
      assert is_binary(inspect(error))
    end

    test "a transport error (the Req.TransportError struct shape from the incident) does not crash" do
      failing = fn _operation, _opts -> {:error, %Req.TransportError{reason: :eaddrnotavail}} end

      assert {:error, %ErrorMessage{code: :failed_dependency} = error} =
               AwsIpWhitelister.deauthorize("sg-test", "1.2.3.4", request_fn: failing)

      assert is_binary(ErrorMessage.to_string(error))
    end

    test "a transient transport error is retried and succeeds on a later attempt" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      request_fn = fn _operation, _opts ->
        attempt = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

        if attempt < 3 do
          {:error, :econnrefused}
        else
          {:ok, %{body: "<Response/>", status_code: 200}}
        end
      end

      assert AwsIpWhitelister.deauthorize("sg-test", "1.2.3.4", request_fn: request_fn) === :ok
      assert Agent.get(calls, & &1) === 3
    end

    test "retries are bounded — a transient error that never clears still fails, not hangs" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      request_fn = fn _operation, _opts ->
        Agent.update(calls, &(&1 + 1))
        {:error, :eaddrnotavail}
      end

      assert {:error, %ErrorMessage{code: :failed_dependency}} =
               AwsIpWhitelister.deauthorize("sg-test", "1.2.3.4", request_fn: request_fn)

      assert Agent.get(calls, & &1) === 3
    end

    test "a non-transient error is not retried" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      request_fn = fn _operation, _opts ->
        Agent.update(calls, &(&1 + 1))
        {:error, :some_unexpected_reason}
      end

      assert {:error, %ErrorMessage{}} =
               AwsIpWhitelister.deauthorize("sg-test", "1.2.3.4", request_fn: request_fn)

      assert Agent.get(calls, & &1) === 1
    end

    test "an AWS 'does not exist' response maps to a not_found ErrorMessage" do
      body = """
      <Response><Errors><Error><Code>InvalidPermission.NotFound</Code>
      <Message>the rule does not exist</Message></Error></Errors></Response>
      """

      failing = fn _operation, _opts -> {:error, {:http_error, 400, %{body: body}}} end

      assert {:error, %ErrorMessage{code: :not_found}} =
               AwsIpWhitelister.deauthorize("sg-test", "1.2.3.4", request_fn: failing)
    end
  end

  describe "authorize/3" do
    test "returns :ok on a clean 200 response" do
      assert AwsIpWhitelister.authorize("sg-test", "1.2.3.4", request_fn: ok_response()) === :ok
    end

    test "an AWS 'already exists' response maps to a conflict ErrorMessage" do
      body = """
      <Response><Errors><Error><Code>InvalidPermission.Duplicate</Code>
      <Message>the rule already exists</Message></Error></Errors></Response>
      """

      failing = fn _operation, _opts -> {:error, {:http_error, 400, %{body: body}}} end

      assert {:error, %ErrorMessage{code: :conflict}} =
               AwsIpWhitelister.authorize("sg-test", "1.2.3.4", request_fn: failing)
    end
  end

  # verify_revoked/3 and verify_authorized/3 ------------------------------------------------

  describe "verify_revoked/3" do
    test "returns :ok once AWS confirms the port 22 rule is gone" do
      request_fn = describe_response(permission_absent_xml())

      assert AwsIpWhitelister.verify_revoked("sg-test", "1.2.3.4", request_fn: request_fn) === :ok
    end

    test "fails loudly with the manual fallback command when the rule is still present" do
      request_fn = describe_response(permission_present_xml("1.2.3.4"))

      assert {:error, %ErrorMessage{code: :failed_dependency} = error} =
               AwsIpWhitelister.verify_revoked("sg-test", "1.2.3.4", request_fn: request_fn)

      assert error.message =~ "sg-test"
      assert error.message =~ "1.2.3.4/32"
      assert error.message =~ "revoke-security-group-ingress"
      assert error.message =~ "--group-id sg-test"
      assert error.message =~ "--cidr 1.2.3.4/32"
    end

    test "propagates a describe failure instead of reporting success" do
      failing = fn _operation, _opts -> {:error, :econnreset} end

      assert {:error, %ErrorMessage{}} =
               AwsIpWhitelister.verify_revoked("sg-test", "1.2.3.4", request_fn: failing)
    end
  end

  describe "verify_authorized/3" do
    test "returns :ok once AWS confirms the port 22 rule is present" do
      request_fn = describe_response(permission_present_xml("1.2.3.4"))

      assert AwsIpWhitelister.verify_authorized("sg-test", "1.2.3.4", request_fn: request_fn) === :ok
    end

    test "fails loudly with the manual fallback command when the rule is still absent" do
      request_fn = describe_response(permission_absent_xml())

      assert {:error, %ErrorMessage{code: :failed_dependency} = error} =
               AwsIpWhitelister.verify_authorized("sg-test", "1.2.3.4", request_fn: request_fn)

      assert error.message =~ "sg-test"
      assert error.message =~ "1.2.3.4/32"
      assert error.message =~ "authorize-security-group-ingress"
      assert error.message =~ "--group-id sg-test"
      assert error.message =~ "--cidr 1.2.3.4/32"
    end

    test "ignores an unrelated CIDR's port 22 rule" do
      request_fn = describe_response(permission_present_xml("9.9.9.9"))

      assert {:error, %ErrorMessage{}} =
               AwsIpWhitelister.verify_authorized("sg-test", "1.2.3.4", request_fn: request_fn)
    end
  end

  # Response contract ----------------------------------------------------------------------
  #
  # Every public function returns `:ok`, `{:ok, boolean}` or `{:error, %ErrorMessage{}}`. A
  # response shape outside that contract used to be passed through untouched, which put an
  # `{:ok, map}` into the caller's `with :ok <- ...` and raised WithClauseError.

  describe "response contract" do
    test "a 2xx that is not 200 is reported as an error, not passed through" do
      odd = fn _operation, _opts -> {:ok, %{body: "", status_code: 204}} end

      assert {:error, %ErrorMessage{code: :failed_dependency} = error} =
               AwsIpWhitelister.authorize("sg-test", "1.2.3.4", request_fn: odd)

      assert error.details.response =~ "204"
    end

    test "a describe response that is not 200 is reported as an error, not passed through" do
      odd = fn _operation, _opts -> {:ok, %{body: "", status_code: 204}} end

      assert {:error, %ErrorMessage{code: :failed_dependency}} =
               AwsIpWhitelister.verify_authorized("sg-test", "1.2.3.4", request_fn: odd)
    end
  end
end
