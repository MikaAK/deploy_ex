defmodule DeployEx.ReleaseController do
  def list_releases(limit \\ 25) do
    "cat /srv/release_history.txt | head -n #{limit}"
  end
end
