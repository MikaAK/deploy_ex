defmodule DeployEx.AwsMachineTest do
  @moduledoc """
  Behavioural tests for the LT-OCI S1 seam additions to `DeployEx.AwsMachine`:
  `run_instance/2` (neutral spec -> EC2 RunInstances params) and `await_running/2`
  (wraps `wait_for_started/3` without reimplementing its poll loop).
  """

  use ExUnit.Case, async: true

  alias DeployEx.AwsMachine
  alias DeployEx.Cloud.Instance

  describe "describe_instance/2 — request_fn seam (LT-OCI review-fix)" do
    defp describe_instance_response(instance_id, state) do
      "<DescribeInstancesResponse><reservationSet><item><instancesSet><item>" <>
        "<instanceId>#{instance_id}</instanceId>" <>
        "<instanceState><name>#{state}</name></instanceState>" <>
        "</item></instancesSet></item></reservationSet></DescribeInstancesResponse>"
    end

    test "routes the DescribeInstances call through the injected request_fn, not the real ExAws.request" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: describe_instance_response("i-1", "running")}}
      end

      assert {:ok, %Instance{id: "i-1", state: "running"}} =
               AwsMachine.describe_instance("i-1", request_fn: request_fn)

      assert_received {:ec2_request, %ExAws.Operation.Query{action: :describe_instances}}
    end

    test "returns a not_found error when no instance matches, without hitting the real network" do
      request_fn = fn _request, _config ->
        {:ok, %{body: "<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>"}}
      end

      assert {:error, %ErrorMessage{code: :not_found}} =
               AwsMachine.describe_instance("i-missing", request_fn: request_fn)
    end

    test "does NOT forward arbitrary caller opts into the DescribeInstances request params (G1 credential-leak guard)" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: describe_instance_response("i-1", "running")}}
      end

      # A caller's whole opts keyword list often carries a pem file PATH (--pem), the resolved
      # :provider, --quiet, etc. Only :request_fn is a real seam here — everything else must be
      # whitelisted away before it reaches ExAws.EC2.describe_instances/1, or it becomes a real
      # EC2 API query parameter (e.g. "Pem" => "/secret/path/key.pem") that reaches AWS and
      # CloudTrail.
      AwsMachine.describe_instance("i-1",
        request_fn: request_fn,
        pem: "/secret/path/key.pem",
        quiet: true,
        provider: :oci
      )

      assert_received {:ec2_request, %ExAws.Operation.Query{params: params}}

      refute Map.has_key?(params, "Pem")
      refute Map.has_key?(params, "Quiet")
      refute Map.has_key?(params, "Provider")

      assert params === %{"Action" => "DescribeInstances", "Version" => "2016-11-15"}
    end
  end

  describe "find_instances_by_tags/2 — request_fn seam + no opts leak (LT-OCI review-fix cycle 3)" do
    test "routes the tag-filter query through the injected request_fn" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: "<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>"}}
      end

      assert {:ok, []} = AwsMachine.find_instances_by_tags([{"K6Runner", "true"}], request_fn: request_fn)

      assert_received {:ec2_request, %ExAws.Operation.Query{action: :describe_instances}}
    end

    test "does NOT forward arbitrary caller opts into the request params (same G1 leak class)" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: "<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>"}}
      end

      AwsMachine.find_instances_by_tags([{"K6Runner", "true"}],
        request_fn: request_fn,
        pem: "/secret/path/key.pem",
        quiet: true
      )

      assert_received {:ec2_request, %ExAws.Operation.Query{params: params}}
      refute Map.has_key?(params, "Pem")
      refute Map.has_key?(params, "Quiet")
    end
  end

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
