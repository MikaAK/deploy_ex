defmodule DeployEx.Cloud.PaginationTest do
  @moduledoc """
  Behavioural tests for the paginators.

  Every fix here originally shipped with source-grep pins, which cannot fail when the loop is
  deleted. Every test here does: replacing the recursion with a single request makes it red.

  Responses are queued in the process dictionary — per-PID isolated, no setup or teardown, and no
  cache involved.
  """

  use ExUnit.Case, async: true

  alias DeployEx.Cloud.S3ObjectStore

  defp queue_responses(responses), do: Process.put(:responses, responses)

  defp next_response do
    [head | rest] = Process.get(:responses)
    Process.put(:responses, rest)
    Process.put(:call_count, (Process.get(:call_count) || 0) + 1)

    head
  end

  defp call_count, do: Process.get(:call_count) || 0

  # The marker rides in the request struct's params, not in the config keyword list — config
  # carries only region and credentials.
  defp recording_request_fn do
    fn request, _config ->
      marker = request |> Map.get(:params, %{}) |> Map.get("marker")
      Process.put(:markers, (Process.get(:markers) || []) ++ [marker])

      next_response()
    end
  end

  defp s3_page(keys, truncated, next_marker) do
    {:ok,
     %{
       body: %{
         contents: Enum.map(keys, &%{key: &1}),
         is_truncated: truncated,
         next_marker: next_marker
       }
     }}
  end

  defp ec2_page(instance_ids, next_token) do
    items =
      Enum.map_join(instance_ids, "", fn id ->
        "<item><instancesSet><item>" <>
          "<instanceId>#{id}</instanceId>" <>
          "<instanceState><name>running</name></instanceState>" <>
          "</item></instancesSet></item>"
      end)

    token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

    {:ok,
     %{
       body:
         "<DescribeInstancesResponse><reservationSet>#{items}</reservationSet>#{token}</DescribeInstancesResponse>"
     }}
  end

  defp ec2_subnets_page(subnets, next_token) do
    items =
      Enum.map_join(subnets, "", fn {subnet_id, az} ->
        "<item><subnetId>#{subnet_id}</subnetId><availabilityZone>#{az}</availabilityZone></item>"
      end)

    token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

    {:ok, %{body: "<DescribeSubnetsResponse><subnetSet>#{items}</subnetSet>#{token}</DescribeSubnetsResponse>"}}
  end

  defp ec2_instances_with_subnet_page(subnet_ids, next_token) do
    items =
      Enum.map_join(subnet_ids, "", fn subnet_id ->
        "<item><instancesSet><item><subnetId>#{subnet_id}</subnetId></item></instancesSet></item>"
      end)

    token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

    {:ok,
     %{body: "<DescribeInstancesResponse><reservationSet>#{items}</reservationSet>#{token}</DescribeInstancesResponse>"}}
  end

  defp ec2_images_page(images, next_token) do
    items =
      Enum.map_join(images, "", fn {image_id, creation_date} ->
        "<item><imageId>#{image_id}</imageId><creationDate>#{creation_date}</creationDate></item>"
      end)

    token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

    {:ok, %{body: "<DescribeImagesResponse><imagesSet>#{items}</imagesSet>#{token}</DescribeImagesResponse>"}}
  end

  defp iam_profiles_page(names, truncated, marker) do
    members = Enum.map_join(names, "", &"<member><InstanceProfileName>#{&1}</InstanceProfileName></member>")
    marker_xml = if marker, do: "<Marker>#{marker}</Marker>", else: ""

    {:ok,
     %{
       body:
         "<ListInstanceProfilesResponse><ListInstanceProfilesResult>" <>
           "<InstanceProfiles>#{members}</InstanceProfiles>" <>
           "<IsTruncated>#{truncated}</IsTruncated>#{marker_xml}" <>
           "</ListInstanceProfilesResult></ListInstanceProfilesResponse>"
     }}
  end

  describe "S3ObjectStore.list_objects/2 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([s3_page(["a", "b"], "true", "b"), s3_page(["c"], "false", "")])

      assert S3ObjectStore.list_objects("bucket",
               request_fn: recording_request_fn(),
               prefix: "p/"
             ) === {:ok, ["a", "b", "c"]}
    end

    test "terminates when is_truncated is the STRING \"false\", which is truthy in Elixir" do
      queue_responses([s3_page(["only"], "false", "")])

      assert S3ObjectStore.list_objects("bucket", request_fn: recording_request_fn()) ===
               {:ok, ["only"]}

      assert call_count() === 1, "a truthy string must not drive a second request"
    end

    test "advances the marker between pages instead of refetching page one" do
      queue_responses([s3_page(["a"], "true", "a"), s3_page(["b"], "false", "")])

      S3ObjectStore.list_objects("bucket", request_fn: recording_request_fn())

      assert Process.get(:markers) === [nil, "a"]
    end

    test "falls back to the last key when next_marker is empty" do
      queue_responses([s3_page(["k1", "k2"], "true", ""), s3_page([], "false", "")])

      S3ObjectStore.list_objects("bucket", request_fn: recording_request_fn())

      assert Process.get(:markers) === [nil, "k2"]
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([s3_page(["a"], "true", "a"), {:error, {:http_error, 500, %{body: "boom"}}}])

      assert {:error, %ErrorMessage{}} =
               S3ObjectStore.list_objects("bucket", request_fn: recording_request_fn())
    end
  end

  describe "AwsMachine.fetch_instances/2 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([ec2_page(["i-1", "i-2"], "TOKEN"), ec2_page(["i-3"], nil)])

      assert {:ok, instances} =
               DeployEx.AwsMachine.fetch_instances("us-east-1", request_fn: recording_request_fn())

      assert Enum.map(instances, & &1["instanceId"]) === ["i-1", "i-2", "i-3"]
    end

    test "terminates when no nextToken comes back" do
      queue_responses([ec2_page(["i-1"], nil)])

      assert {:ok, [_only]} =
               DeployEx.AwsMachine.fetch_instances("us-east-1", request_fn: recording_request_fn())

      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([ec2_page(["i-1"], "TOKEN"), {:error, {:http_error, 503, %{body: "nope"}}}])

      assert {:error, %ErrorMessage{}} =
               DeployEx.AwsMachine.fetch_instances("us-east-1", request_fn: recording_request_fn())
    end
  end

  describe "AwsInfrastructure.find_subnet_ids/1 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([
        ec2_subnets_page([{"subnet-a", "us-east-1a"}], "TOKEN"),
        ec2_subnets_page([{"subnet-b", "us-east-1b"}], nil)
      ])

      assert DeployEx.AwsInfrastructure.find_subnet_ids(vpc_id: "vpc-123", request_fn: recording_request_fn()) ===
               {:ok, ["subnet-a", "subnet-b"]}
    end

    test "terminates when no nextToken comes back" do
      queue_responses([ec2_subnets_page([{"subnet-a", "us-east-1a"}], nil)])

      assert {:ok, ["subnet-a"]} =
               DeployEx.AwsInfrastructure.find_subnet_ids(vpc_id: "vpc-123", request_fn: recording_request_fn())

      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([
        ec2_subnets_page([{"subnet-a", "us-east-1a"}], "TOKEN"),
        {:error, {:http_error, 500, %{body: "boom"}}}
      ])

      assert {:error, %ErrorMessage{}} =
               DeployEx.AwsInfrastructure.find_subnet_ids(vpc_id: "vpc-123", request_fn: recording_request_fn())
    end

    test "a page that filters to zero items but still carries a token keeps paginating" do
      queue_responses([
        ec2_subnets_page([], "TOKEN"),
        ec2_subnets_page([{"subnet-b", "us-east-1b"}], nil)
      ])

      assert DeployEx.AwsInfrastructure.find_subnet_ids(vpc_id: "vpc-123", request_fn: recording_request_fn()) ===
               {:ok, ["subnet-b"]}

      assert call_count() === 2
    end
  end

  describe "AwsInfrastructure.find_primary_subnet_id/2 pagination" do
    test "a truncated ballot would flip the winner without full pagination" do
      # page one alone would pick subnet-y (2 votes); the full ballot picks subnet-x (3 votes)
      queue_responses([
        ec2_instances_with_subnet_page(["subnet-y", "subnet-y"], "TOKEN"),
        ec2_instances_with_subnet_page(["subnet-x", "subnet-x", "subnet-x"], nil)
      ])

      assert DeployEx.AwsInfrastructure.find_primary_subnet_id("sg-123", request_fn: recording_request_fn()) ===
               {:ok, "subnet-x"}
    end

    test "terminates when no nextToken comes back" do
      queue_responses([ec2_instances_with_subnet_page(["subnet-x"], nil)])

      assert {:ok, "subnet-x"} =
               DeployEx.AwsInfrastructure.find_primary_subnet_id("sg-123", request_fn: recording_request_fn())

      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial vote" do
      queue_responses([
        ec2_instances_with_subnet_page(["subnet-x"], "TOKEN"),
        {:error, {:http_error, 500, %{body: "boom"}}}
      ])

      assert {:error, %ErrorMessage{}} =
               DeployEx.AwsInfrastructure.find_primary_subnet_id("sg-123", request_fn: recording_request_fn())
    end

    test "a page with no running instances on it but still carrying a token keeps paginating" do
      queue_responses([
        ec2_instances_with_subnet_page([], "TOKEN"),
        ec2_instances_with_subnet_page(["subnet-x"], nil)
      ])

      assert DeployEx.AwsInfrastructure.find_primary_subnet_id("sg-123", request_fn: recording_request_fn()) ===
               {:ok, "subnet-x"}

      assert call_count() === 2
    end
  end

  describe "AwsInfrastructure.find_latest_ami/1 pagination" do
    test "a truncated first page would pick a stale AMI without full pagination" do
      # page one alone has only the older AMI; the newer one only shows up on page two
      queue_responses([
        ec2_images_page([{"ami-old", "2024-06-01T00:00:00.000Z"}], "TOKEN"),
        ec2_images_page([{"ami-newer", "2025-01-01T00:00:00.000Z"}], nil)
      ])

      assert DeployEx.AwsInfrastructure.find_latest_ami(request_fn: recording_request_fn()) === {:ok, "ami-newer"}
    end

    test "terminates when no nextToken comes back" do
      queue_responses([ec2_images_page([{"ami-only", "2024-01-01T00:00:00.000Z"}], nil)])

      assert {:ok, "ami-only"} = DeployEx.AwsInfrastructure.find_latest_ami(request_fn: recording_request_fn())
      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial result" do
      queue_responses([
        ec2_images_page([{"ami-old", "2024-01-01T00:00:00.000Z"}], "TOKEN"),
        {:error, {:http_error, 500, %{body: "boom"}}}
      ])

      assert {:error, %ErrorMessage{}} = DeployEx.AwsInfrastructure.find_latest_ami(request_fn: recording_request_fn())
    end

    test "a page that filters to zero images but still carries a token keeps paginating" do
      queue_responses([
        ec2_images_page([], "TOKEN"),
        ec2_images_page([{"ami-only", "2024-01-01T00:00:00.000Z"}], nil)
      ])

      assert DeployEx.AwsInfrastructure.find_latest_ami(request_fn: recording_request_fn()) === {:ok, "ami-only"}
      assert call_count() === 2
    end
  end

  describe "AwsInfrastructure.find_iam_instance_profile/1 pagination" do
    test "concatenates every page rather than returning the first" do
      default_name = "deploy-ex-ec2-instance-profile-#{DeployEx.Config.env()}"

      queue_responses([
        iam_profiles_page(["other-profile"], "true", "TOKEN"),
        iam_profiles_page([default_name], "false", nil)
      ])

      assert DeployEx.AwsInfrastructure.find_iam_instance_profile(request_fn: recording_request_fn()) ===
               {:ok, default_name}
    end

    test "terminates when IsTruncated is the STRING \"false\", which is truthy in Elixir" do
      default_name = "deploy-ex-ec2-instance-profile-#{DeployEx.Config.env()}"
      queue_responses([iam_profiles_page([default_name], "false", nil)])

      assert DeployEx.AwsInfrastructure.find_iam_instance_profile(request_fn: recording_request_fn()) ===
               {:ok, default_name}

      assert call_count() === 1, "a truthy string must not drive a second request"
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([
        iam_profiles_page(["other-profile"], "true", "TOKEN"),
        {:error, {:http_error, 500, %{body: "boom"}}}
      ])

      assert {:error, %ErrorMessage{}} =
               DeployEx.AwsInfrastructure.find_iam_instance_profile(request_fn: recording_request_fn())
    end
  end
end
