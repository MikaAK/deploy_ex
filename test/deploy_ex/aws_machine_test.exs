defmodule DeployEx.AwsMachineTest do
  @moduledoc """
  Behavioural tests for the LT-OCI S1 seam additions to `DeployEx.AwsMachine`:
  `run_instance/2` (neutral spec -> EC2 RunInstances params) and `await_running/2`
  (wraps `wait_for_started/3` without reimplementing its poll loop).
  """

  use ExUnit.Case, async: true

  alias DeployEx.AwsMachine
  alias DeployEx.Cloud.Instance

  describe "run_instance/2 — neutral spec to EC2 RunInstances params (LT-OCI S1)" do
    defp neutral_spec do
      %{
        name: "K6-Runner-test-1",
        instance_type: "t3.small",
        user_data: "#!/bin/bash\necho hi\n",
        tags: [{:Name, "K6-Runner-test-1"}, {:Group, "My Backend"}, {:K6Runner, "true"}],
        network: %{
          key_name: "my-key",
          subnet_id: "subnet-123",
          security_group_id: "sg-123",
          ami_id: "ami-123",
          iam_instance_profile: "profile-name"
        }
      }
    end

    defp run_instances_response(instance_id) do
      "<RunInstancesResponse><instancesSet><item>" <>
        "<instanceId>#{instance_id}</instanceId>" <>
        "</item></instancesSet></RunInstancesResponse>"
    end

    test "translates the neutral spec into the exact EC2 params AWS expects" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: run_instances_response("i-abc123")}}
      end

      assert {:ok, %Instance{id: "i-abc123"}} =
               AwsMachine.run_instance(neutral_spec(), request_fn: request_fn)

      assert_received {:ec2_request, %ExAws.Operation.Query{params: params}}

      assert params === %{
               "Action" => "RunInstances",
               "IamInstanceProfile.Name" => "profile-name",
               "ImageId" => "ami-123",
               "InstanceType" => "t3.small",
               "KeyName" => "my-key",
               "MaxCount" => 1,
               "MinCount" => 1,
               "NetworkInterface.1.AssociatePublicIpAddress" => "true",
               "NetworkInterface.1.DeviceIndex" => "0",
               "NetworkInterface.1.SecurityGroupId.1" => "sg-123",
               "NetworkInterface.1.SubnetId" => "subnet-123",
               "TagSpecification.1.ResourceType" => "instance",
               "TagSpecification.1.Tag.1.Key" => "Name",
               "TagSpecification.1.Tag.1.Value" => "K6-Runner-test-1",
               "TagSpecification.1.Tag.2.Key" => "Group",
               "TagSpecification.1.Tag.2.Value" => "My Backend",
               "TagSpecification.1.Tag.3.Key" => "K6Runner",
               "TagSpecification.1.Tag.3.Value" => "true",
               "UserData" => Base.encode64(neutral_spec().user_data),
               "Version" => "2016-11-15"
             }
    end

    test "requests against the given region rather than the configured default" do
      request_fn = fn request, config ->
        send(self(), {:ec2_request, request, config})
        {:ok, %{body: run_instances_response("i-region-test")}}
      end

      AwsMachine.run_instance(neutral_spec(), request_fn: request_fn, region: "eu-west-1")

      assert_received {:ec2_request, _request, config}
      assert config[:region] === "eu-west-1"
    end

    test "maps an AWS http error to an ErrorMessage instead of raising" do
      request_fn = fn _request, _config ->
        {:error, {:http_error, 400, %{body: "boom"}}}
      end

      assert {:error, %ErrorMessage{code: :bad_request}} =
               AwsMachine.run_instance(neutral_spec(), request_fn: request_fn)
    end
  end

  describe "terminate_instance/2 — LT-OCI S1" do
    test "sends the exact EC2 TerminateInstances params for the given instance id" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: "<TerminateInstancesResponse></TerminateInstancesResponse>"}}
      end

      assert :ok = AwsMachine.terminate_instance("i-terminate-1", request_fn: request_fn)

      assert_received {:ec2_request, %ExAws.Operation.Query{action: :terminate_instances, params: params}}
      assert params["InstanceId.1"] === "i-terminate-1"
    end

    test "maps an AWS http error to an ErrorMessage instead of raising" do
      request_fn = fn _request, _config ->
        {:error, {:http_error, 400, %{body: "boom"}}}
      end

      assert {:error, %ErrorMessage{code: :bad_request}} =
               AwsMachine.terminate_instance("i-terminate-2", request_fn: request_fn)
    end
  end

  describe "await_running/2 — wraps wait_for_started (LT-OCI S1)" do
    test "delegates to the injected wait function with the resolved region and retries" do
      wait_fn = fn region, instance_ids, retries ->
        send(self(), {:waited, region, instance_ids, retries})
        :ok
      end

      assert AwsMachine.await_running(["i-1"],
               region: "us-east-1",
               retries: 3,
               wait_for_started_fn: wait_fn
             ) === :ok

      assert_received {:waited, "us-east-1", ["i-1"], 3}
    end

    test "defaults region to the configured region and retries to 10 when opts omit them" do
      wait_fn = fn region, instance_ids, retries ->
        send(self(), {:waited, region, instance_ids, retries})
        :ok
      end

      AwsMachine.await_running(["i-1"], wait_for_started_fn: wait_fn)

      assert_received {:waited, region, ["i-1"], 10}
      assert region === DeployEx.Config.aws_region()
    end

    test "propagates an error from the wait function unchanged" do
      error = ErrorMessage.failed_dependency("instance never started", %{instance_ids: ["i-1"]})
      wait_fn = fn _region, _instance_ids, _retries -> {:error, error} end

      assert AwsMachine.await_running(["i-1"], wait_for_started_fn: wait_fn) === {:error, error}
    end
  end
end
