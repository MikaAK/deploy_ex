defmodule DeployEx.ReleaseController do
  def list_releases(limit \\ 25) do
    "cat /srv/release_history.txt | tac | head -n #{limit}"
  end

  @doc """
  Returns the SSH command to read the current_release.txt file for the given app_name.
  """
  def current_release do
    "cat /srv/current_release.txt | tac"
  end
end
