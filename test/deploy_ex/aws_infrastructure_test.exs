defmodule DeployEx.AwsInfrastructureTest do
  use ExUnit.Case, async: true

  alias DeployEx.AwsInfrastructure

  describe "find_iam_instance_profile/1" do
    # This test used to call find_iam_instance_profile/1 with no request_fn, which meant the
    # SUITE HIT THE REAL AWS IAM API — it failed with a list of actual profiles from whatever
    # account happened to be configured. Tests must not depend on a live account.
    test "an explicitly configured profile short-circuits the lookup entirely" do
      never_called = fn _operation, _opts -> flunk("should not have called AWS") end

      assert AwsInfrastructure.find_iam_instance_profile(
               iam_instance_profile: "preset-profile",
               request_fn: never_called
             ) === {:ok, "preset-profile"}
    end

    test "returns the environment default when AWS reports it exists" do
      default = "deploy-ex-ec2-instance-profile-#{DeployEx.Config.env()}"

      assert AwsInfrastructure.find_iam_instance_profile(
               request_fn: instance_profiles_response([default, "unrelated"])
             ) === {:ok, default}
    end

    test "reports what IS available when the default is absent, rather than a bare not_found" do
      assert {:error, %ErrorMessage{code: :not_found} = error} =
               AwsInfrastructure.find_iam_instance_profile(
                 request_fn: instance_profiles_response(["something-else"])
               )

      assert error.details.available === ["something-else"]
    end

    test "propagates a request error instead of crashing or silently falling through to live AWS" do
      failing_request = fn _operation, _opts ->
        {:error, {:http_error, 403, %{body: "boom"}}}
      end

      assert AwsInfrastructure.find_iam_instance_profile(request_fn: failing_request) ===
               {:error, ErrorMessage.forbidden("error fetching IAM instance profiles", %{error_body: "boom"})}
    end

    test "follows Marker across pages and accumulates profiles from every page" do
      request_fn = paginated_instance_profiles_response(["page-one-profile"], ["page-two-profile"])

      assert {:error, %ErrorMessage{code: :not_found} = error} =
               AwsInfrastructure.find_iam_instance_profile(request_fn: request_fn)

      assert error.details.available === ["page-one-profile", "page-two-profile"]

      assert_received {:list_instance_profiles_request, first_operation}
      assert_received {:list_instance_profiles_request, second_operation}

      refute Map.has_key?(first_operation.params, "Marker")
      assert second_operation.params["Marker"] === "marker-1"
    end
  end

  describe "parse_subnets_response/2" do
    test "sorts multiple subnets by availability zone" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeSubnetsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <subnetSet>
          <item>
            <subnetId>subnet-def456</subnetId>
            <vpcId>vpc-123</vpcId>
            <availabilityZone>us-east-1c</availabilityZone>
          </item>
          <item>
            <subnetId>subnet-abc123</subnetId>
            <vpcId>vpc-123</vpcId>
            <availabilityZone>us-east-1a</availabilityZone>
          </item>
        </subnetSet>
      </DescribeSubnetsResponse>
      """

      assert {:ok, ["subnet-abc123", "subnet-def456"]} === AwsInfrastructure.parse_subnets_response(xml, "vpc-123")
    end

    test "parses single subnet" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeSubnetsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <subnetSet>
          <item>
            <subnetId>subnet-single</subnetId>
            <vpcId>vpc-123</vpcId>
          </item>
        </subnetSet>
      </DescribeSubnetsResponse>
      """

      assert {:ok, ["subnet-single"]} === AwsInfrastructure.parse_subnets_response(xml, "vpc-123")
    end

    test "returns error for empty subnet set" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeSubnetsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <subnetSet/>
      </DescribeSubnetsResponse>
      """

      assert {:error, %ErrorMessage{code: :not_found}} = AwsInfrastructure.parse_subnets_response(xml, "vpc-123")
    end
  end

  describe "parse_primary_subnet_response/1" do
    test "picks the most common subnet across running instances" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <reservationSet>
          <item>
            <instancesSet>
              <item>
                <instanceId>i-aaa</instanceId>
                <subnetId>subnet-prod1a</subnetId>
              </item>
              <item>
                <instanceId>i-bbb</instanceId>
                <subnetId>subnet-prod1a</subnetId>
              </item>
            </instancesSet>
          </item>
          <item>
            <instancesSet>
              <item>
                <instanceId>i-ccc</instanceId>
                <subnetId>subnet-other1c</subnetId>
              </item>
            </instancesSet>
          </item>
        </reservationSet>
      </DescribeInstancesResponse>
      """

      assert {:ok, "subnet-prod1a"} === AwsInfrastructure.parse_primary_subnet_response(xml)
    end

    test "returns error when no instances are running" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <reservationSet/>
      </DescribeInstancesResponse>
      """

      assert {:error, %ErrorMessage{code: :not_found}} = AwsInfrastructure.parse_primary_subnet_response(xml)
    end
  end

  describe "find_key_pair_name/1" do
    # parse_key_pairs_response/2 was deleted when key-pair parsing moved inline, but its four
    # tests stayed and kept the suite red. These exercise the CURRENT public path instead.
    test "picks the newest matching key pair" do
      response = key_pairs_response(["my-project-AAA-key-pair", "my-project-ZZZ-key-pair"])

      assert AwsInfrastructure.find_key_pair_name(
               project_name: "my-project",
               request_fn: response
             ) === {:ok, "my-project-ZZZ-key-pair"}
    end

    test "parses a single-element key set, which AWS returns unwrapped" do
      assert AwsInfrastructure.find_key_pair_name(
               project_name: "my-project",
               request_fn: key_pairs_response(["my-project-solo-key-pair"])
             ) === {:ok, "my-project-solo-key-pair"}
    end

    test "ignores key pairs belonging to other projects" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               AwsInfrastructure.find_key_pair_name(
                 project_name: "my-project",
                 request_fn: key_pairs_response(["other-project-key-pair"])
               )
    end

    test "an empty key set is not_found, not a crash" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               AwsInfrastructure.find_key_pair_name(
                 project_name: "my-project",
                 request_fn: key_pairs_response([])
               )
    end
  end

  describe "parse_vpcs_response/1" do
    test "parses VPC from list (returns first)" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeVpcsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <vpcSet>
          <item>
            <vpcId>vpc-first</vpcId>
            <state>available</state>
          </item>
          <item>
            <vpcId>vpc-second</vpcId>
            <state>available</state>
          </item>
        </vpcSet>
      </DescribeVpcsResponse>
      """

      assert {:ok, "vpc-first"} === AwsInfrastructure.parse_vpcs_response(xml)
    end

    test "parses single VPC" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeVpcsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <vpcSet>
          <item>
            <vpcId>vpc-single</vpcId>
            <state>available</state>
          </item>
        </vpcSet>
      </DescribeVpcsResponse>
      """

      assert {:ok, "vpc-single"} === AwsInfrastructure.parse_vpcs_response(xml)
    end

    test "returns error for empty VPC set" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeVpcsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <vpcSet/>
      </DescribeVpcsResponse>
      """

      assert {:error, %ErrorMessage{code: :not_found}} = AwsInfrastructure.parse_vpcs_response(xml)
    end
  end

  describe "parse_images_response/1" do
    test "parses and returns latest AMI by creation date" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeImagesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <imagesSet>
          <item>
            <imageId>ami-older</imageId>
            <creationDate>2024-01-01T00:00:00.000Z</creationDate>
          </item>
          <item>
            <imageId>ami-newest</imageId>
            <creationDate>2024-06-15T00:00:00.000Z</creationDate>
          </item>
          <item>
            <imageId>ami-middle</imageId>
            <creationDate>2024-03-01T00:00:00.000Z</creationDate>
          </item>
        </imagesSet>
      </DescribeImagesResponse>
      """

      assert {:ok, "ami-newest"} === AwsInfrastructure.parse_images_response(xml)
    end

    test "parses single AMI" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeImagesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <imagesSet>
          <item>
            <imageId>ami-single</imageId>
            <creationDate>2024-01-01T00:00:00.000Z</creationDate>
          </item>
        </imagesSet>
      </DescribeImagesResponse>
      """

      assert {:ok, "ami-single"} === AwsInfrastructure.parse_images_response(xml)
    end

    test "returns error for empty images set" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeImagesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <imagesSet/>
      </DescribeImagesResponse>
      """

      assert {:error, %ErrorMessage{code: :not_found}} = AwsInfrastructure.parse_images_response(xml)
    end
  end

  defp instance_profiles_response(names) do
    profiles = Enum.map_join(names, "", &"<member><InstanceProfileName>#{&1}</InstanceProfileName></member>")

    body = """
    <ListInstanceProfilesResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
      <ListInstanceProfilesResult>
        <IsTruncated>false</IsTruncated>
        <InstanceProfiles>#{profiles}</InstanceProfiles>
      </ListInstanceProfilesResult>
    </ListInstanceProfilesResponse>
    """

    fn _operation, _opts -> {:ok, %{body: body}} end
  end

  # First call returns IsTruncated=true with a Marker; second call (the one carrying that
  # Marker as a request param) returns the remaining page with IsTruncated=false. Mirrors the
  # real API's response shape — IsTruncated is the STRING "false"/"true", not a boolean.
  defp paginated_instance_profiles_response(page_one_names, page_two_names) do
    page_one_body = instance_profiles_page_body(page_one_names, truncated: "true", marker: "marker-1")
    page_two_body = instance_profiles_page_body(page_two_names, truncated: "false", marker: nil)

    fn operation, _opts ->
      send(self(), {:list_instance_profiles_request, operation})

      if Map.has_key?(operation.params, "Marker") do
        {:ok, %{body: page_two_body}}
      else
        {:ok, %{body: page_one_body}}
      end
    end
  end

  defp instance_profiles_page_body(names, truncated: truncated, marker: marker) do
    profiles = Enum.map_join(names, "", &"<member><InstanceProfileName>#{&1}</InstanceProfileName></member>")
    marker_tag = if marker, do: "<Marker>#{marker}</Marker>", else: ""

    """
    <ListInstanceProfilesResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
      <ListInstanceProfilesResult>
        <IsTruncated>#{truncated}</IsTruncated>
        #{marker_tag}
        <InstanceProfiles>#{profiles}</InstanceProfiles>
      </ListInstanceProfilesResult>
    </ListInstanceProfilesResponse>
    """
  end

  defp key_pairs_response(key_names) do
    items = Enum.map_join(key_names, "", &"<item><keyName>#{&1}</keyName></item>")
    key_set = if Enum.empty?(key_names), do: "<keySet/>", else: "<keySet>#{items}</keySet>"

    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <DescribeKeyPairsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
      #{key_set}
    </DescribeKeyPairsResponse>
    """

    fn _operation, _opts -> {:ok, %{body: body}} end
  end
end
