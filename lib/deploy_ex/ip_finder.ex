defmodule DeployEx.IpFinder do
  @ip_find_base_url "http://whatismyip.akamai.com"

  def current_ip do
    with {:ok, %{body: body}} <- Req.get(@ip_find_base_url) do
      {:ok, body}
    end
  end
end
