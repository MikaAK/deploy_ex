defmodule DeployEx.AwsInfrastructureTest do
  use ExUnit.Case, async: true

  alias DeployEx.AwsInfrastructure

  describe "find_iam_instance_profile/1" do
    test "returns expected profile name based on resource group" do
      assert {:ok, "my-project-instance-profile"} ===
               AwsInfrastructure.find_iam_instance_profile(resource_group: "My_Project")

      assert {:ok, "test-backend-instance-profile"} ===
               AwsInfrastructure.find_iam_instance_profile(resource_group: "Test Backend")

      assert {:ok, "simple-instance-profile"} ===
               AwsInfrastructure.find_iam_instance_profile(resource_group: "Simple")
    end
  end

  describe "parse_subnets_response/1" do
    test "parses multiple subnets" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeSubnetsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <subnetSet>
          <item>
            <subnetId>subnet-abc123</subnetId>
            <vpcId>vpc-123</vpcId>
          </item>
          <item>
            <subnetId>subnet-def456</subnetId>
            <vpcId>vpc-123</vpcId>
          </item>
        </subnetSet>
      </DescribeSubnetsResponse>
      """

      assert {:ok, ["subnet-abc123", "subnet-def456"]} === AwsInfrastructure.parse_subnets_response(xml)
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

      assert {:ok, ["subnet-single"]} === AwsInfrastructure.parse_subnets_response(xml)
    end

    test "returns error for empty subnet set" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeSubnetsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <subnetSet/>
      </DescribeSubnetsResponse>
      """

      assert {:error, %ErrorMessage{code: :not_found}} = AwsInfrastructure.parse_subnets_response(xml)
    end
  end

  describe "parse_key_pairs_response/2" do
    test "parses key pair from list" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeKeyPairsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <keySet>
          <item>
            <keyName>my-project-key-pair</keyName>
            <keyFingerprint>abc123</keyFingerprint>
          </item>
          <item>
            <keyName>other-key-pair</keyName>
            <keyFingerprint>def456</keyFingerprint>
          </item>
        </keySet>
      </DescribeKeyPairsResponse>
      """

      assert {:ok, "my-project-key-pair"} === AwsInfrastructure.parse_key_pairs_response(xml, "my-project-key-pair")
    end

    test "parses single key pair" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeKeyPairsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <keySet>
          <item>
            <keyName>single-key</keyName>
            <keyFingerprint>abc123</keyFingerprint>
          </item>
        </keySet>
      </DescribeKeyPairsResponse>
      """

      assert {:ok, "single-key"} === AwsInfrastructure.parse_key_pairs_response(xml, "single-key")
    end

    test "returns error when key pair not found in list" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeKeyPairsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <keySet>
          <item>
            <keyName>other-key</keyName>
            <keyFingerprint>abc123</keyFingerprint>
          </item>
          <item>
            <keyName>another-key</keyName>
            <keyFingerprint>def456</keyFingerprint>
          </item>
        </keySet>
      </DescribeKeyPairsResponse>
      """

      assert {:error, %ErrorMessage{code: :not_found, message: "key pair my-key not found"}} =
               AwsInfrastructure.parse_key_pairs_response(xml, "my-key")
    end

    test "returns error for empty key set" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DescribeKeyPairsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
        <keySet/>
      </DescribeKeyPairsResponse>
      """

      assert {:error, %ErrorMessage{code: :not_found}} = AwsInfrastructure.parse_key_pairs_response(xml, "my-key")
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
end
