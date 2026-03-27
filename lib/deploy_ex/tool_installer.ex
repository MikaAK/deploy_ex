defmodule DeployEx.ToolInstaller do
  @moduledoc """
  Detects the host platform and installs required tools (terraform/tofu, ansible)
  when they are missing. Supports macOS, Debian/Ubuntu, Alpine, and Amazon Linux.
  Windows is detected but returns an error pointing to WSL.
  """

  @os_release_path "/etc/os-release"

  @spec detect_platform() :: :macos | :debian | :alpine | :amazon_linux | :windows | {:error, :unsupported_platform}
  def detect_platform do
    case :os.type() do
      {:win32, _} -> :windows
      {:unix, :darwin} -> :macos
      {:unix, _} -> detect_linux_distro()
    end
  end

  @doc false
  @spec parse_os_release(String.t()) :: :debian | :alpine | :amazon_linux | {:error, :unsupported_platform}
  def parse_os_release(content) do
    lines = String.split(content, "\n")
    id = extract_field(lines, "ID")
    id_like = extract_field(lines, "ID_LIKE")

    cond do
      id in ["alpine"] -> :alpine
      id in ["amzn"] -> :amazon_linux
      id in ["debian", "ubuntu"] -> :debian
      String.contains?(id_like, "debian") -> :debian
      true -> {:error, :unsupported_platform}
    end
  end

  defp detect_linux_distro do
    if File.exists?(@os_release_path) do
      @os_release_path
      |> File.read!()
      |> parse_os_release()
    else
      {:error, :unsupported_platform}
    end
  end

  defp extract_field(lines, field_name) do
    prefix = "#{field_name}="

    lines
    |> Enum.find("", &String.starts_with?(&1, prefix))
    |> String.replace_prefix(prefix, "")
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.downcase()
  end
end
