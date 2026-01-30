defmodule DeployEx.AwsSecurityGroup do
  def find_security_group_id(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()
    sg_name = "#{kebab_case(resource_group)}-sg"

    with {:ok, security_groups} <- describe_security_groups(region) do
      case Enum.find(security_groups, &(&1["groupName"] === sg_name)) do
        nil -> {:error, ErrorMessage.not_found("no security group found with name #{sg_name}")}
        sg -> {:ok, sg["groupId"]}
      end
    end
  end

  defp describe_security_groups(region) do
    ExAws.EC2.describe_security_groups()
    |> ex_aws_request(region)
    |> handle_response()
  end

  defp ex_aws_request(request_struct, nil) do
    ExAws.request(request_struct)
  end

  defp ex_aws_request(request_struct, region) do
    ExAws.request(request_struct, region: region)
  end

  defp handle_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error fetching security groups from aws",
      %{error_body: body}
    ])}
  end

  defp handle_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeSecurityGroupsResponse" => %{"securityGroupInfo" => %{"item" => items}}} when is_list(items) ->
        {:ok, items}

      %{"DescribeSecurityGroupsResponse" => %{"securityGroupInfo" => %{"item" => item}}} ->
        {:ok, [item]}

      %{"DescribeSecurityGroupsResponse" => %{"securityGroupInfo" => nil}} ->
        {:ok, []}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse security groups response from aws",
          %{structure: structure}
        )}
    end
  end

  defp kebab_case(string) do
    string
    |> String.replace("_", "-")
    |> String.downcase()
  end
end
