defmodule DeployEx.ReleaseController do
  defdelegate fetch_current_release(app_name, opts \\ []), to: DeployEx.ReleaseTracker
  defdelegate list_release_history(app_name, limit \\ 25, opts \\ []), to: DeployEx.ReleaseTracker
  defdelegate set_current_release(app_name, release_name, opts \\ []), to: DeployEx.ReleaseTracker
end
