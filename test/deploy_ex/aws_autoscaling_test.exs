defmodule DeployEx.AwsAutoscalingTest do
  use ExUnit.Case, async: true

  alias DeployEx.AwsAutoscaling

  # Real AWS body for a missing group — it says "name not found - null", not "does not exist".
  @missing_asg_body """
  <ErrorResponse xmlns="http://autoscaling.amazonaws.com/doc/2011-01-01/">
    <Error>
      <Type>Sender</Type>
      <Code>ValidationError</Code>
      <Message>AutoScalingGroup name not found - null</Message>
    </Error>
    <RequestId>1aa2e3b2-a483-42d2-9dda-d7a8182ed6e1</RequestId>
  </ErrorResponse>
  """

  defp missing_asg(_operation, _opts), do: {:error, {:http_error, 400, %{body: @missing_asg_body}}}

  test "start_instance_refresh maps AWS's 'name not found' to :not_found" do
    assert {:error, %ErrorMessage{code: :not_found}} =
             AwsAutoscaling.start_instance_refresh("missing-asg-prod", %{}, request_fn: &missing_asg/2)
  end

  test "set_desired_capacity maps AWS's 'name not found' to :not_found" do
    assert {:error, %ErrorMessage{code: :not_found}} =
             AwsAutoscaling.set_desired_capacity("missing-asg-prod", 1, request_fn: &missing_asg/2)
  end
end
