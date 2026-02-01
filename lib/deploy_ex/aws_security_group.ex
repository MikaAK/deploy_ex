defmodule DeployEx.AwsSecurityGroup do
  def find_security_group(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    project_name = opts[:project_name] || DeployEx.Config.aws_project_name()
    sg_prefix = "#{project_name}-sg"

    with {:ok, security_groups} <- describe_security_groups(region) do
      matching = security_groups
        |> Enum.filter(fn sg ->
          name = sg["groupName"] || ""
          String.starts_with?(name, sg_prefix) or name === sg_prefix
        end)
        |> Enum.sort_by(& &1["groupName"], :desc)
        |> List.first()

      case matching do
        nil ->
          available = security_groups
            |> Enum.map(& &1["groupName"])
            |> Enum.filter(& &1)
            |> Enum.reject(&(&1 === "default"))
          {:error, ErrorMessage.not_found("no security group found matching prefix #{sg_prefix}", %{available: available})}
        sg ->
          {:ok, %{id: sg["groupId"], vpc_id: sg["vpcId"], name: sg["groupName"]}}
      end
    end
  end

  def find_security_group_id(opts \\ []) do
    with {:ok, sg} <- find_security_group(opts) do
      {:ok, sg.id}
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

end
