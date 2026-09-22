defmodule DeployEx.AwsIpWhitelister do
  alias ExAws.EC2

  @transient_reasons [:eaddrnotavail, :econnrefused, :econnreset, :etimedout, :timeout, :closed]
  @max_attempts 3
  @retry_backoff_ms 250

  def authorize(security_group_id, ip_address, opts \\ []) do
    {request_fn, region, aws_opts} = extract_request_opts(opts)

    aws_opts
      |> Keyword.merge(
        group_id: security_group_id,
        cidr_ip: "#{ip_address}/32",
        ip_protocol: "tcp",
        from_port: 22,
        to_port: 22
      )
      |> EC2.authorize_security_group_ingress
      |> request_with_retry(request_fn, region, build_context(security_group_id, ip_address))
      |> handle_mutation_response
  end

  def deauthorize(security_group_id, ip_address, opts \\ []) do
    {request_fn, region, aws_opts} = extract_request_opts(opts)

    aws_opts
      |> Keyword.merge(
        group_id: security_group_id,
        cidr_ip: "#{ip_address}/32",
        ip_protocol: "tcp",
        from_port: 22,
        to_port: 22
      )
      |> EC2.revoke_security_group_ingress
      |> request_with_retry(request_fn, region, build_context(security_group_id, ip_address))
      |> handle_mutation_response
  end

  @doc """
  Re-reads the security group from AWS and confirms `ip_address` no longer holds a port 22
  rule. A revoke must never be reported as successful just because the API call returned
  200 — this is what actually confirms the access is gone.
  """
  def verify_revoked(security_group_id, ip_address, opts \\ []) do
    case authorized?(security_group_id, ip_address, opts) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, verification_failed_error(:revoke, security_group_id, ip_address)}
      error -> error
    end
  end

  @doc """
  Re-reads the security group from AWS and confirms `ip_address` holds a port 22 rule.
  """
  def verify_authorized(security_group_id, ip_address, opts \\ []) do
    case authorized?(security_group_id, ip_address, opts) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, verification_failed_error(:authorize, security_group_id, ip_address)}
      error -> error
    end
  end

  defp authorized?(security_group_id, ip_address, opts) do
    {request_fn, region, _aws_opts} = extract_request_opts(opts)

    EC2.describe_security_groups(group_ids: [security_group_id])
      |> request_with_retry(request_fn, region, build_context(security_group_id, ip_address))
      |> handle_describe_response(ip_address)
  end

  defp build_context(security_group_id, ip_address) do
    %{security_group_id: security_group_id, ip_address: ip_address}
  end

  defp extract_request_opts(opts) do
    request_fn = opts[:request_fn] || (&ExAws.request/2)
    region = opts[:region] || DeployEx.Config.aws_region()
    aws_opts = Keyword.drop(opts, [:request_fn, :region])

    {request_fn, region, aws_opts}
  end

  # A few short, bounded retries for transient transport failures (connection pool exhaustion,
  # timeouts) — the kind of failure that let a revoke silently never reach AWS at all. Anything
  # else (an AWS-side HTTP error, or retries exhausted) falls through to handle_response/2.
  defp request_with_retry(request, request_fn, region, context, attempt \\ 1) do
    request
      |> request_fn.(region: region)
      |> retry_or_handle(request, request_fn, region, context, attempt)
  end

  defp retry_or_handle({:error, reason}, request, request_fn, region, context, attempt)
       when attempt < @max_attempts do
    if transient_error?(reason) do
      Process.sleep(@retry_backoff_ms)
      request_with_retry(request, request_fn, region, context, attempt + 1)
    else
      handle_response(reason, context)
    end
  end

  defp retry_or_handle({:error, reason}, _request, _request_fn, _region, context, _attempt) do
    handle_response(reason, context)
  end

  defp retry_or_handle(response, _request, _request_fn, _region, _context, _attempt), do: response

  defp transient_error?(%{reason: reason}), do: transient_error?(reason)
  defp transient_error?(reason) when reason in @transient_reasons, do: true
  defp transient_error?(_reason), do: false

  defp handle_mutation_response({:ok, %{body: _, status_code: 200}}), do: :ok
  defp handle_mutation_response(response), do: response

  defp handle_describe_response({:ok, %{body: body, status_code: 200}}, ip_address) do
    {:ok, cidr_rule_present?(body, ip_address)}
  end

  defp handle_describe_response(response, _ip_address), do: response

  defp handle_response({:http_error, code, %{body: body}}, context) do
    message = body |> SweetXml.xpath(SweetXml.sigil_x"//Message/text()") |> to_string

    cond do
      message =~ "already exists" ->
        {:error, ErrorMessage.conflict(message, context)}

      message =~ "does not exist" ->
        {:error, ErrorMessage.not_found(message, context)}

      true ->
        {:error, %ErrorMessage{
          code: ErrorMessage.http_code_reason_atom(code),
          message: message,
          details: context
        }}
    end
  end

  # Covers everything ExAws can hand back that isn't an AWS HTTP error response — a transport
  # failure like `:eaddrnotavail` (bare atom, Hackney) or `%Req.TransportError{}` (Req), once
  # retries are exhausted. inspect/1 is deliberate: this term is arbitrary and may not implement
  # String.Chars — a raw #{} interpolation of it is what produced the confusing crash this fixes.
  defp handle_response(reason, context) do
    details = Map.put(context, :error, inspect(reason))
    {:error, ErrorMessage.failed_dependency("AWS request failed", details)}
  end

  defp cidr_rule_present?(body, ip_address) do
    case XmlToMap.naive_map(body) do
      %{"DescribeSecurityGroupsResponse" => %{"securityGroupInfo" => %{"item" => security_group}}} ->
        security_group
          |> get_in(["ipPermissions", "item"])
          |> List.wrap()
          |> Enum.any?(&tcp_22_rule_matches?(&1, ip_address))

      _structure ->
        false
    end
  end

  defp tcp_22_rule_matches?(
         %{"ipProtocol" => "tcp", "fromPort" => "22", "toPort" => "22"} = permission,
         ip_address
       ) do
    permission
      |> get_in(["ipRanges", "item"])
      |> List.wrap()
      |> Enum.any?(&(&1["cidrIp"] === "#{ip_address}/32"))
  end

  defp tcp_22_rule_matches?(_permission, _ip_address), do: false

  defp verification_failed_error(:revoke, security_group_id, ip_address) do
    ErrorMessage.failed_dependency(
      "security group #{security_group_id} still allows SSH (port 22) from #{ip_address}/32 " <>
        "after revoke — AWS did not confirm removal, run this by hand:\n\n" <>
        manual_command("revoke-security-group-ingress", security_group_id, ip_address),
      %{security_group_id: security_group_id, ip_address: ip_address, action: :revoke}
    )
  end

  defp verification_failed_error(:authorize, security_group_id, ip_address) do
    ErrorMessage.failed_dependency(
      "security group #{security_group_id} does not allow SSH (port 22) from #{ip_address}/32 " <>
        "after authorize — AWS did not confirm the rule was added, run this by hand:\n\n" <>
        manual_command("authorize-security-group-ingress", security_group_id, ip_address),
      %{security_group_id: security_group_id, ip_address: ip_address, action: :authorize}
    )
  end

  defp manual_command(ec2_action, security_group_id, ip_address) do
    profile = System.get_env("AWS_PROFILE", "default")

    "  AWS_PROFILE=#{profile} aws ec2 #{ec2_action} \\\n" <>
      "    --group-id #{security_group_id} --protocol tcp --port 22 --cidr #{ip_address}/32"
  end
end
