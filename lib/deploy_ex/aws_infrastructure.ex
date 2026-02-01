defmodule DeployEx.AwsInfrastructure do
  @moduledoc """
  Discover required infrastructure IDs directly from AWS APIs for QA node creation.

  This module follows the pattern established by `DeployEx.AwsSecurityGroup` which uses
  AWS APIs to find resources by naming conventions, avoiding terraform state dependency.
  """

  def find_subnet_ids(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    vpc_id = opts[:vpc_id]

    if is_nil(vpc_id) do
      {:error, ErrorMessage.bad_request("vpc_id is required to find subnets")}
    else
      ExAws.EC2.describe_subnets(filters: ["vpc-id": [vpc_id]])
      |> ExAws.request(region: region)
      |> handle_subnets_response(vpc_id)
    end
  end

  def find_key_pair_name(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    project_name = opts[:project_name] || DeployEx.Config.aws_project_name()
    key_pattern = ~r/^#{Regex.escape(project_name)}-.*key-pair/

    with {:ok, key_pairs} <- describe_key_pairs(region) do
      matching = key_pairs
        |> Enum.filter(fn kp ->
          name = kp["keyName"] || ""
          Regex.match?(key_pattern, name)
        end)
        |> Enum.sort_by(& &1["keyName"], :desc)
        |> List.first()

      case matching do
        nil ->
          available = Enum.map(key_pairs, & &1["keyName"])
          {:error, ErrorMessage.not_found("no key pair found matching pattern #{inspect(key_pattern)}", %{available: available})}
        kp ->
          {:ok, kp["keyName"]}
      end
    end
  end

  defp describe_key_pairs(region) do
    ExAws.EC2.describe_key_pairs()
    |> ExAws.request(region: region)
    |> handle_key_pairs_list_response()
  end

  def find_iam_instance_profile(opts \\ []) do
    project_name = opts[:project_name] || DeployEx.Config.aws_project_name()
    expected_name = "#{project_name}-instance-profile"
    {:ok, expected_name}
  end

  def find_vpc_id(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    ExAws.EC2.describe_vpcs(filters: ["tag:Group": [resource_group]])
    |> ExAws.request(region: region)
    |> handle_vpcs_response()
  end

  def find_latest_ami(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    ExAws.EC2.describe_images(
      owners: ["136693071363"],
      filters: [
        name: ["debian-13-*"],
        architecture: ["x86_64"],
        "virtualization-type": ["hvm"]
      ]
    )
    |> ExAws.request(region: region)
    |> handle_images_response()
  end

  def gather_infrastructure(opts \\ []) do
    with {:ok, security_group} <- DeployEx.AwsSecurityGroup.find_security_group(opts),
         {:ok, subnet_ids} <- find_subnet_ids(Keyword.put(opts, :vpc_id, security_group.vpc_id)),
         {:ok, key_pair_name} <- find_key_pair_name(opts),
         {:ok, ami_id} <- find_latest_ami(opts) do
      resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()
      iam_instance_profile = "#{kebab_case(resource_group)}-instance-profile"

      {:ok, %{
        security_group_id: security_group.id,
        vpc_id: security_group.vpc_id,
        subnet_id: List.first(subnet_ids),
        subnet_ids: subnet_ids,
        key_name: key_pair_name,
        iam_instance_profile: iam_instance_profile,
        ami_id: ami_id
      }}
    end
  end

  @doc false
  def parse_subnets_response(body, resource_group) when is_binary(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeSubnetsResponse" => %{"subnetSet" => %{"item" => items}}} when is_list(items) ->
        {:ok, Enum.map(items, & &1["subnetId"])}

      %{"DescribeSubnetsResponse" => %{"subnetSet" => %{"item" => item}}} ->
        {:ok, [item["subnetId"]]}

      %{"DescribeSubnetsResponse" => %{"subnetSet" => nil}} ->
        {:error, ErrorMessage.not_found("no subnets found in VPC '#{resource_group}'")}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse subnets response from aws",
          %{structure: structure}
        )}
    end
  end

  defp handle_subnets_response({:ok, %{body: body}}, resource_group), do: parse_subnets_response(body, resource_group)

  defp handle_subnets_response({:error, {:http_error, status_code, %{body: body}}}, _resource_group) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error fetching subnets from aws",
      %{error_body: body}
    ])}
  end


  defp handle_key_pairs_list_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeKeyPairsResponse" => %{"keySet" => %{"item" => items}}} when is_list(items) ->
        {:ok, items}

      %{"DescribeKeyPairsResponse" => %{"keySet" => %{"item" => item}}} ->
        {:ok, [item]}

      %{"DescribeKeyPairsResponse" => %{"keySet" => nil}} ->
        {:ok, []}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse key pairs response from aws",
          %{structure: structure}
        )}
    end
  end

  defp handle_key_pairs_list_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error fetching key pairs from aws",
      %{error_body: body}
    ])}
  end


  @doc false
  def parse_vpcs_response(body) when is_binary(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeVpcsResponse" => %{"vpcSet" => %{"item" => items}}} when is_list(items) ->
        {:ok, List.first(items)["vpcId"]}

      %{"DescribeVpcsResponse" => %{"vpcSet" => %{"item" => item}}} ->
        {:ok, item["vpcId"]}

      %{"DescribeVpcsResponse" => %{"vpcSet" => nil}} ->
        {:error, ErrorMessage.not_found("no VPCs found with the resource group tag")}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse VPCs response from aws",
          %{structure: structure}
        )}
    end
  end

  defp handle_vpcs_response({:ok, %{body: body}}), do: parse_vpcs_response(body)

  defp handle_vpcs_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error fetching VPCs from aws",
      %{error_body: body}
    ])}
  end

  @doc false
  def parse_images_response(body) when is_binary(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeImagesResponse" => %{"imagesSet" => %{"item" => items}}} when is_list(items) ->
        latest = items
        |> Enum.sort_by(& &1["creationDate"], :desc)
        |> List.first()

        {:ok, latest["imageId"]}

      %{"DescribeImagesResponse" => %{"imagesSet" => %{"item" => item}}} ->
        {:ok, item["imageId"]}

      %{"DescribeImagesResponse" => %{"imagesSet" => nil}} ->
        {:error, ErrorMessage.not_found("no debian-13 AMI found")}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse images response from aws",
          %{structure: structure}
        )}
    end
  end

  defp handle_images_response({:ok, %{body: body}}), do: parse_images_response(body)

  defp handle_images_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error fetching AMIs from aws",
      %{error_body: body}
    ])}
  end

  defp kebab_case(string) do
    string
    |> String.replace("_", "-")
    |> String.replace(" ", "-")
    |> String.downcase()
  end
end
