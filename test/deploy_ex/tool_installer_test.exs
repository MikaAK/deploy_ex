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

  describe "ensure_installed/1" do
    test "returns :ok when terraform is already installed" do
      iac_tool = DeployEx.Config.iac_tool()

      if is_nil(System.find_executable(iac_tool)) do
        :ok
      else
        assert :ok === ToolInstaller.ensure_installed(:terraform)
      end
    end

    test "returns :ok when ansible is already installed" do
      if is_nil(System.find_executable("ansible-playbook")) do
        :ok
      else
        assert :ok === ToolInstaller.ensure_installed(:ansible)
      end
    end
  end

  describe "install_command/2" do
    test "returns brew command for terraform on macos" do
      assert {"brew install terraform", "."} === ToolInstaller.install_command(:terraform, :macos)
    end

    test "returns brew command for tofu on macos" do
      assert {"brew install opentofu", "."} === ToolInstaller.install_command(:tofu, :macos)
    end

    test "returns brew command for ansible on macos" do
      assert {"brew install ansible", "."} === ToolInstaller.install_command(:ansible, :macos)
    end

    test "returns pip3 command for ansible on debian" do
      assert {"pip3 install --user ansible boto3 botocore", "."} === ToolInstaller.install_command(:ansible, :debian)
    end

    test "returns pip3 command for ansible on amazon_linux" do
      assert {"pip3 install --user ansible boto3 botocore", "."} === ToolInstaller.install_command(:ansible, :amazon_linux)
    end

    test "returns apk command for ansible on alpine" do
      assert {"apk add --no-cache ansible", "."} === ToolInstaller.install_command(:ansible, :alpine)
    end

    test "returns apk command for terraform on alpine" do
      {cmd, _} = ToolInstaller.install_command(:terraform, :alpine)

      assert String.contains?(cmd, "apk add")
      assert String.contains?(cmd, "terraform")
    end

    test "returns error for any tool on windows" do
      assert {:error, _} = ToolInstaller.install_command(:terraform, :windows)
    end

    test "returns error for any tool on unsupported platform" do
      assert {:error, _} = ToolInstaller.install_command(:terraform, {:error, :unsupported_platform})
    end
  end
end
