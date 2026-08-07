defmodule DeployEx.AwsIpWhitelister do
  @moduledoc """
  Whitelists a single IP for SSH on a security group.

  The EC2 calls now live in `DeployEx.AwsSecurityGroup`, which implements
  `DeployEx.Cloud.Security`. This module stays as the IP-shaped front door its Mix task call
  sites already use — it takes a bare address and widens it to a /32 CIDR.
  """

  alias DeployEx.AwsSecurityGroup

  def authorize(security_group_id, ip_address, opts \\ []) do
    AwsSecurityGroup.authorize_ingress(security_group_id, to_cidr(ip_address), opts)
  end

  def deauthorize(security_group_id, ip_address, opts \\ []) do
    AwsSecurityGroup.revoke_ingress(security_group_id, to_cidr(ip_address), opts)
  end

  defp to_cidr(ip_address), do: "#{ip_address}/32"
end
