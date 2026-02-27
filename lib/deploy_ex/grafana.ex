defmodule DeployEx.Grafana do
  @grafana_com_api_url "https://grafana.com/api/dashboards"
  @default_grafana_port 80
  @default_user "admin"
  @default_password "admin"

  @type install_result :: {:ok, %{title: String.t(), uid: String.t(), url: String.t()}} | {:error, ErrorMessage.t()}

  @spec find_grafana_node(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}
  def find_grafana_node(opts \\ []) do
    if opts[:grafana_ip] do
      {:ok, opts[:grafana_ip]}
    else
      resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

      with {:ok, instances} <- DeployEx.AwsMachine.fetch_instances_by_tag("Group", resource_group) do
        grafana_instance = Enum.find(instances, fn instance ->
          tags = extract_tags(instance)
          tags["MonitoringKey"] === "grafana_ui" and
            instance["instanceState"]["name"] in ["running", "pending"]
        end)

        if is_nil(grafana_instance) do
          {:error, ErrorMessage.not_found("no running Grafana node found with MonitoringKey 'grafana_ui'")}
        else
          ip = grafana_instance["ipv6Address"] || grafana_instance["ipAddress"]

          if is_nil(ip) do
            {:error, ErrorMessage.not_found("Grafana node found but has no IP address")}
          else
            {:ok, ip}
          end
        end
      end
    end
  end

  @spec download_dashboard(pos_integer() | String.t()) :: {:ok, map()} | {:error, ErrorMessage.t()}
  def download_dashboard(grafana_id) do
    url = "#{@grafana_com_api_url}/#{grafana_id}/revisions/latest/download"

    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, prepare_dashboard_for_import(body)}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, prepare_dashboard_for_import(decoded)}
          {:error, _} -> {:error, ErrorMessage.bad_request("failed to parse dashboard JSON from grafana.com")}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, ErrorMessage.bad_gateway("grafana.com returned status #{status} for dashboard #{grafana_id}")}

      {:error, exception} ->
        {:error, ErrorMessage.failed_dependency("failed to download dashboard from grafana.com", %{error: Exception.message(exception)})}
    end
  end

  @spec install_dashboard(map(), keyword()) :: install_result()
  def install_dashboard(dashboard_json, opts \\ []) do
    grafana_port = opts[:grafana_port] || @default_grafana_port
    terraform_directory = opts[:terraform_directory] || DeployEx.Config.terraform_folder_path()

    with {:ok, grafana_ip} <- find_grafana_node(opts),
         {:ok, pem_file} <- DeployEx.Terraform.find_pem_file(terraform_directory, opts[:pem]),
         {:ok, local_port} <- DeployEx.SSH.find_available_port(),
         :ok <- DeployEx.SSH.setup_ssh_tunnel(grafana_ip, "localhost", grafana_port, local_port, pem_file) do
      result = post_dashboard(dashboard_json, local_port, opts)
      DeployEx.SSH.cleanup_tunnel(local_port)

      case result do
        {:ok, response} ->
          {:ok, %{
            title: dashboard_json["title"] || "Unknown",
            uid: response["uid"],
            url: "http://#{grafana_ip}:#{grafana_port}/d/#{response["uid"]}"
          }}

        error ->
          error
      end
    end
  end

  @spec wrap_dashboard_for_import(map()) :: map()
  def wrap_dashboard_for_import(dashboard_json) do
    %{
      "dashboard" => prepare_dashboard_for_import(dashboard_json),
      "overwrite" => true,
      "folderId" => 0
    }
  end

  defp prepare_dashboard_for_import(dashboard_json) do
    dashboard_json
    |> Map.put("id", nil)
    |> Map.delete("__inputs")
    |> Map.delete("__requires")
  end

  defp post_dashboard(dashboard_json, local_port, opts) do
    user = opts[:user] || @default_user
    password = opts[:password] || @default_password
    url = "http://localhost:#{local_port}/api/dashboards/db"
    body = wrap_dashboard_for_import(dashboard_json)

    case Req.post(url, json: body, auth: {:basic, "#{user}:#{password}"}) do
      {:ok, %Req.Response{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: body}} ->
        message = if is_map(body), do: body["message"] || "unknown error", else: "unknown error"
        {:error, ErrorMessage.bad_gateway("Grafana API returned #{status}: #{message}")}

      {:error, exception} ->
        {:error, ErrorMessage.failed_dependency("failed to connect to Grafana API", %{error: Exception.message(exception)})}
    end
  end

  defp extract_tags(%{"tagSet" => %{"item" => items}}) when is_list(items) do
    Map.new(items, fn %{"key" => key, "value" => value} -> {key, value} end)
  end

  defp extract_tags(%{"tagSet" => %{"item" => %{"key" => key, "value" => value}}}) do
    %{key => value}
  end

  defp extract_tags(_), do: %{}
end
