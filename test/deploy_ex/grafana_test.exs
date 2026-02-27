defmodule DeployEx.GrafanaTest do
  use ExUnit.Case, async: true

  alias DeployEx.Grafana

  describe "wrap_dashboard_for_import/1" do
    test "wraps dashboard JSON with import metadata" do
      dashboard = %{
        "title" => "My Dashboard",
        "uid" => "abc123",
        "panels" => []
      }

      result = Grafana.wrap_dashboard_for_import(dashboard)

      assert result["overwrite"] === true
      assert result["folderId"] === 0
      assert result["dashboard"]["title"] === "My Dashboard"
      assert result["dashboard"]["uid"] === "abc123"
    end

    test "sets dashboard id to nil for import" do
      dashboard = %{
        "id" => 42,
        "title" => "Existing Dashboard",
        "panels" => []
      }

      result = Grafana.wrap_dashboard_for_import(dashboard)

      assert is_nil(result["dashboard"]["id"])
    end

    test "strips __inputs and __requires fields" do
      dashboard = %{
        "title" => "Downloaded Dashboard",
        "__inputs" => [%{"name" => "DS_PROMETHEUS", "type" => "datasource"}],
        "__requires" => [%{"type" => "grafana", "version" => "9.0.0"}],
        "panels" => []
      }

      result = Grafana.wrap_dashboard_for_import(dashboard)

      refute Map.has_key?(result["dashboard"], "__inputs")
      refute Map.has_key?(result["dashboard"], "__requires")
      assert result["dashboard"]["title"] === "Downloaded Dashboard"
    end

    test "handles dashboard with no id field" do
      dashboard = %{"title" => "No ID", "panels" => []}

      result = Grafana.wrap_dashboard_for_import(dashboard)

      assert is_nil(result["dashboard"]["id"])
      assert result["dashboard"]["title"] === "No ID"
    end
  end

  describe "find_grafana_node/1" do
    test "returns grafana_ip when provided as override" do
      assert {:ok, "10.0.0.1"} === Grafana.find_grafana_node(grafana_ip: "10.0.0.1")
    end

    test "returns ipv6 address when provided as override" do
      assert {:ok, "2600:1f18::1"} === Grafana.find_grafana_node(grafana_ip: "2600:1f18::1")
    end
  end
end
