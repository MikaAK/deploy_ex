defmodule DeployEx.AwsSecurityGroup do
  def find_security_group(opts \\ []) do
    security_group_id = opts[:security_group_id] || DeployEx.Config.aws_security_group_id()

    if is_nil(security_group_id) do
      find_security_group_by_prefix(opts)
    else
      find_security_group_by_id(security_group_id, opts)
    end
  end

  defp find_security_group_by_id(security_group_id, opts) do
    with {:ok, security_groups} <- describe_security_groups(opts) do
      matching = Enum.find(security_groups, fn sg ->
        sg["groupId"] === security_group_id or
          sg["groupName"] === security_group_id or
          String.starts_with?(sg["groupName"] || "", security_group_id)
      end)

      case matching do
        nil ->
          {:error, ErrorMessage.not_found(
            "security group #{security_group_id} not found",
            %{security_group_id: security_group_id}
          )}

        sg ->
          {:ok, %{id: sg["groupId"], vpc_id: sg["vpcId"], name: sg["groupName"]}}
      end
    end
  end

  defp find_security_group_by_prefix(opts) do
    project_name = opts[:project_name] || DeployEx.Config.aws_project_name()
    environment = opts[:environment] || DeployEx.Config.env()

    sg_prefix = if DeployEx.Config.aws_names_include_env?() do
      base_name = project_name
        |> String.replace("-#{environment}", "")
        |> String.replace("_#{environment}", "")

      "#{base_name}-#{environment}-sg"
    else
      "#{project_name}-sg"
    end

    with {:ok, security_groups} <- describe_security_groups(opts) do
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

  defp describe_security_groups(opts) do
    request_fn = opts[:request_fn] || (&ExAws.request/2)
    region = opts[:region] || DeployEx.Config.aws_region()

    ExAws.EC2.describe_security_groups()
    |> request_fn.(region: region)
    |> handle_response()
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

  # Covers everything ExAws can hand back that is not an AWS HTTP error response — a transport
  # failure like `:eaddrnotavail` (bare atom, Hackney) or `%Req.TransportError{}` (Req). Mirrors
  # DeployEx.AwsIpWhitelister.handle_response/2; without it this call raises FunctionClauseError
  # before the whitelister's own handling is ever reached. inspect/1 is deliberate: the term is
  # arbitrary and may not implement String.Chars.
  defp handle_response(response) do
    {:error, ErrorMessage.failed_dependency(
      "error fetching security groups from aws",
      %{error: inspect(response)}
    )}
  end
end
