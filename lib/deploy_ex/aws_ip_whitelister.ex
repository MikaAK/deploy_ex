defmodule DeployEx.AwsIpWhitelister do
  alias ExAws.EC2

  def authorize(security_group_id, ip_address, opts \\ []) do
    opts
      |> Keyword.merge(
        group_id: security_group_id,
        cidr_ip: "#{ip_address}/32",
        ip_protocol: "tcp",
        from_port: 22,
        to_port: 22
      )
      |> EC2.authorize_security_group_ingress
      |> make_request(security_group_id, ip_address)
  end

  def deauthorize(security_group_id, ip_address, opts \\ []) do
    opts
      |> Keyword.merge(
        group_id: security_group_id,
        cidr_ip: "#{ip_address}/32",
        ip_protocol: "tcp",
        from_port: 22,
        to_port: 22
      )
      |> EC2.revoke_security_group_ingress
      |> make_request(security_group_id, ip_address)
  end

  defp make_request(request, security_group_id, ip_address) do
    case ExAws.request(request, region: DeployEx.Config.aws_region()) do
      {:ok, %{body: _, status_code: 200}} -> :ok

      {:error, {:http_error, code, %{body: body}}} ->
        message = body |> SweetXml.xpath(SweetXml.sigil_x"//Message/text()") |> to_string

        cond do
          message =~ "already exists" ->
            {:error, ErrorMessage.conflict(
              message,
              %{ip_address: ip_address, security_group_id: security_group_id
            })}

          message =~ "does not exist" ->
            {:error, ErrorMessage.not_found(
              message,
              %{ip_address: ip_address, security_group_id: security_group_id
            })}

          true ->
            {:error, %ErrorMessage{
              code: ErrorMessage.http_code_reason_atom(code),
              message: message,
              details: %{ip_address: ip_address, security_group_id: security_group_id}
            }}
        end
    end
  end
end
