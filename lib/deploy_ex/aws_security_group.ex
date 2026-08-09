defmodule DeployEx.AwsSecurityGroup do
  @moduledoc """
  AWS implementation of `DeployEx.Cloud.Security`.

  Owns the SSH ingress rules `mix deploy_ex.ssh.authorize` manages. The ingress calls used to
  live in `DeployEx.AwsIpWhitelister`; that module now delegates here so every EC2 call for
  this capability sits behind one behaviour.
  """

  @behaviour DeployEx.Cloud.Security

  @ssh_port 22

  @impl DeployEx.Cloud.Security
  def find_group(opts \\ []), do: find_security_group_id(opts)

  @impl DeployEx.Cloud.Security
  def authorize_ingress(security_group_id, cidr, opts \\ []) do
    security_group_id
    |> build_ingress_request(cidr, opts)
    |> ExAws.EC2.authorize_security_group_ingress()
    |> request_ingress_change(security_group_id, cidr, opts)
  end

  @impl DeployEx.Cloud.Security
  def revoke_ingress(security_group_id, cidr, opts \\ []) do
    security_group_id
    |> build_ingress_request(cidr, opts)
    |> ExAws.EC2.revoke_security_group_ingress()
    |> request_ingress_change(security_group_id, cidr, opts)
  end

  @doc """
  Turns an AWS ingress error body into an `ErrorMessage`.

  Public because it is the only pure part of the ingress path — the request itself needs a live
  account, this does not.
  """
  def classify_ingress_error(status_code, body, details) do
    message = body |> SweetXml.xpath(SweetXml.sigil_x("//Message/text()", [])) |> to_string()

    cond do
      message =~ "already exists" -> {:error, ErrorMessage.conflict(message, details)}
      message =~ "does not exist" -> {:error, ErrorMessage.not_found(message, details)}
      true -> {:error, build_http_error(status_code, message, details)}
    end
  end

  defp build_ingress_request(security_group_id, cidr, opts) do
    Keyword.merge(opts,
      group_id: security_group_id,
      cidr_ip: cidr,
      ip_protocol: "tcp",
      from_port: @ssh_port,
      to_port: @ssh_port
    )
  end

  defp request_ingress_change(request, security_group_id, cidr, opts) do
    region = opts[:region] || DeployEx.Config.aws_region()

    case ExAws.request(request, region: region) do
      {:ok, %{status_code: 200}} ->
        :ok

      {:error, {:http_error, status_code, %{body: body}}} ->
        classify_ingress_error(status_code, body, %{
          cidr: cidr,
          security_group_id: security_group_id
        })
    end
  end

  defp build_http_error(status_code, message, details) do
    %ErrorMessage{
      code: ErrorMessage.http_code_reason_atom(status_code),
      message: message,
      details: details
    }
  end

  def find_security_group(opts \\ []) do
    security_group_id = opts[:security_group_id] || DeployEx.Config.aws_security_group_id()

    if is_nil(security_group_id) do
      find_security_group_by_prefix(opts)
    else
      find_security_group_by_id(security_group_id, opts)
    end
  end

  defp find_security_group_by_id(security_group_id, opts) do
    region = opts[:region] || DeployEx.Config.aws_region()
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    with {:ok, security_groups} <- describe_security_groups(region, request_fn) do
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
    region = opts[:region] || DeployEx.Config.aws_region()
    project_name = opts[:project_name] || DeployEx.Config.aws_project_name()
    environment = opts[:environment] || DeployEx.Config.env()
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    sg_prefix = if DeployEx.Config.aws_names_include_env?() do
      base_name = project_name
        |> String.replace("-#{environment}", "")
        |> String.replace("_#{environment}", "")

      "#{base_name}-#{environment}-sg"
    else
      "#{project_name}-sg"
    end

    with {:ok, security_groups} <- describe_security_groups(region, request_fn) do
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

  # DescribeSecurityGroups caps a response and signals more via nextToken. A single request
  # silently truncates on an account with many security groups — same failure mode
  # AwsInfrastructure.fetch_subnets/5 guards against for DescribeSubnets.
  defp describe_security_groups(region, request_fn, next_token \\ nil, acc \\ []) do
    request_opts = maybe_put_next_token([], next_token)

    response =
      request_opts
      |> ExAws.EC2.describe_security_groups()
      |> request_fn.(region: region)

    case response do
      {:ok, %{body: body}} ->
        case XmlToMap.naive_map(body) do
          %{"DescribeSecurityGroupsResponse" => envelope} ->
            accumulated = acc ++ extract_items(envelope["securityGroupInfo"])

            case extract_next_token(envelope) do
              nil -> {:ok, accumulated}
              token -> describe_security_groups(region, request_fn, token, accumulated)
            end

          structure ->
            {:error, ErrorMessage.bad_request(
              "couldn't parse security groups response from aws",
              %{structure: structure}
            )}
        end

      {:error, {:http_error, status_code, %{body: body}}} ->
        {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
          "error fetching security groups from aws",
          %{error_body: body}
        ])}
    end
  end

  defp maybe_put_next_token(request_opts, nil), do: request_opts
  defp maybe_put_next_token(request_opts, next_token), do: Keyword.put(request_opts, :next_token, next_token)

  defp extract_items(nil), do: []
  defp extract_items(%{"item" => items}) when is_list(items), do: items
  defp extract_items(%{"item" => item}), do: [item]

  defp extract_next_token(envelope) do
    case Map.get(envelope, "nextToken") do
      token when is_binary(token) and token !== "" -> token
      _absent -> nil
    end
  end

end
