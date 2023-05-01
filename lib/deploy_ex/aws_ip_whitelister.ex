defmodule DeployEx.AwsIpWhitelister do
  alias ExAws.EC2

  def authorize(security_group_id, ip_address) do
    EC2.authorize_security_group_ingress(
      group_id: security_group_id,
      cidr_ip: "#{ip_address}/32",
      ip_protocol: "tcp",
      from_port: 22,
      to_port: 22
    )
  end

  def deauthorize(security_group_id, ip_address) do
    EC2.revoke_security_group_ingress(
      group_id: security_group_id,
      cidr_ip: "#{ip_address}/32",
      ip_protocol: "tcp",
      from_port: 22,
      to_port: 22
    )
  end
end
