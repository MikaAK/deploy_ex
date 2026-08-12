defmodule DeployEx.PrivRendererDeterminismTest do
  use ExUnit.Case, async: true

  alias DeployEx.PrivRenderer

  defp render(opts) do
    {:ok, dir} = PrivRenderer.render_to_temp(opts)
    on_exit(fn -> File.rm_rf!(dir) end)

    dir
  end

  defp read_rendered(dir, relative_path), do: File.read!(Path.join(dir, relative_path))

  test "pinned pem_app_name renders identical key-pair bytes" do
    one = render(pem_app_name: "pinned-abc")
    two = render(pem_app_name: "pinned-abc")

    assert read_rendered(one, "terraform/key-pair-main.tf") ===
             read_rendered(two, "terraform/key-pair-main.tf")
  end

  test "default pem_app_name stays random per render" do
    one = render([])
    two = render([])

    assert read_rendered(one, "terraform/key-pair-main.tf") !==
             read_rendered(two, "terraform/key-pair-main.tf")
  end

  test "different pinned pem_app_names render different key-pair bytes" do
    one = render(pem_app_name: "pinned-abc")
    two = render(pem_app_name: "other-xyz")

    assert read_rendered(one, "terraform/key-pair-main.tf") !==
             read_rendered(two, "terraform/key-pair-main.tf")
  end

  test "pinning pem_app_name does not change the database template" do
    pinned = render(pem_app_name: "pinned-abc")
    default = render([])

    assert read_rendered(pinned, "terraform/database.tf") ===
             read_rendered(default, "terraform/database.tf")
  end
end
