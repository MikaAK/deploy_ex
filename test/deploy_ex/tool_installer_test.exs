defmodule DeployEx.ToolInstallerTest do
  use ExUnit.Case, async: true

  alias DeployEx.ToolInstaller

  describe "detect_platform/0" do
    test "returns a known platform atom on this machine" do
      result = ToolInstaller.detect_platform()

      assert result in [:macos, :debian, :alpine, :amazon_linux, :windows]
    end
  end

  describe "parse_os_release/1" do
    test "detects debian from ID" do
      content = """
      ID=debian
      VERSION_ID="12"
      """

      assert :debian === ToolInstaller.parse_os_release(content)
    end

    test "detects ubuntu via ID" do
      content = """
      ID=ubuntu
      ID_LIKE=debian
      VERSION_ID="22.04"
      """

      assert :debian === ToolInstaller.parse_os_release(content)
    end

    test "detects alpine from ID" do
      content = """
      ID=alpine
      VERSION_ID=3.19.0
      """

      assert :alpine === ToolInstaller.parse_os_release(content)
    end

    test "detects amazon linux from ID" do
      content = """
      ID="amzn"
      VERSION_ID="2023"
      """

      assert :amazon_linux === ToolInstaller.parse_os_release(content)
    end

    test "detects debian from ID_LIKE when ID is unknown" do
      content = """
      ID=linuxmint
      ID_LIKE="ubuntu debian"
      """

      assert :debian === ToolInstaller.parse_os_release(content)
    end

    test "returns error for unknown distribution" do
      content = """
      ID=nixos
      VERSION_ID="23.11"
      """

      assert {:error, :unsupported_platform} === ToolInstaller.parse_os_release(content)
    end

    test "returns error for empty content" do
      assert {:error, :unsupported_platform} === ToolInstaller.parse_os_release("")
    end
  end
end
