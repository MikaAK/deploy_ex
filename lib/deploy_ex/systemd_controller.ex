defmodule DeployEx.SystemDController do
  def restart_service(service_name) do
    service_name = strip_env_suffix(service_name)

    join_commands([
      stop_service(service_name),
      "systemctl daemon-reload",
      start_service(service_name)
    ])
  end

  def start_service(service_name) do
    "systemctl start #{strip_env_suffix(service_name)}"
  end

  def stop_service(service_name) do
    "systemctl stop #{strip_env_suffix(service_name)}"
  end

  defp strip_env_suffix(service_name) do
    service_name
    |> String.replace(~r/_(prod|dev|staging|test)$/, "")
  end

  defp join_commands(commands), do: Enum.join(commands, " && ")
end
