defmodule DeployEx.SystemDController do
  def restart_service(service_name) do
    join_commands([
      stop_service(service_name),
      "systemctl daemon-reload",
      start_service(service_name)
    ])
  end

  def start_service(service_name) do
    "systemctl start #{service_name}"
  end

  def stop_service(service_name) do
    "systemctl stop #{service_name}"
  end

  defp join_commands(commands), do: Enum.join(commands, " && ")
end
