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
      _ -> {:error, :unsupported_platform}
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

  @spec ensure_installed(:terraform | :ansible) :: :ok | {:error, ErrorMessage.t()}
  def ensure_installed(:terraform) do
    iac_tool = DeployEx.Config.iac_tool()

    case System.find_executable(iac_tool) do
      nil ->
        case iac_tool do
          "terraform" -> install_tool(:terraform)
          "tofu" -> install_tool(:tofu)
          other -> {:error, ErrorMessage.bad_request("#{__MODULE__}: unsupported iac_tool #{inspect(other)}, expected \"terraform\" or \"tofu\"")}
        end

      _path -> :ok
    end
  end

  def ensure_installed(:ansible) do
    case System.find_executable("ansible-playbook") do
      nil -> install_tool(:ansible)
      _path -> :ok
    end
  end

  @doc false
  @spec install_command(atom(), atom() | {:error, :unsupported_platform}) ::
          {String.t(), String.t()} | {:error, ErrorMessage.t()}
  def install_command(tool, :windows) do
    {:error, ErrorMessage.bad_request("#{__MODULE__}: #{tool} is not supported on Windows natively, please use WSL")}
  end

  def install_command(_tool, {:error, :unsupported_platform}) do
    {:error, ErrorMessage.bad_request("#{__MODULE__}: unsupported platform, please install tools manually")}
  end

  # SECTION: macOS

  def install_command(:terraform, :macos), do: {"brew install terraform", "."}
  def install_command(:tofu, :macos), do: {"brew install opentofu", "."}
  def install_command(:ansible, :macos), do: {"brew install ansible", "."}

  # SECTION: Debian/Ubuntu

  def install_command(:terraform, :debian) do
    cmd = Enum.join([
      "wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list",
      "sudo apt-get update && sudo apt-get install -y terraform"
    ], " && ")

    {cmd, "."}
  end

  def install_command(:tofu, :debian) do
    cmd = Enum.join([
      "curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh",
      "chmod +x /tmp/install-opentofu.sh",
      "/tmp/install-opentofu.sh --install-method deb",
      "rm /tmp/install-opentofu.sh"
    ], " && ")

    {cmd, "."}
  end

  def install_command(:ansible, :debian) do
    {"pip3 install --user ansible boto3 botocore", "."}
  end

  # SECTION: Alpine

  def install_command(:terraform, :alpine) do
    {"apk add --no-cache terraform --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community", "."}
  end

  def install_command(:tofu, :alpine) do
    {"apk add --no-cache opentofu --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community", "."}
  end

  def install_command(:ansible, :alpine), do: {"apk add --no-cache ansible", "."}

  # SECTION: Amazon Linux

  def install_command(:terraform, :amazon_linux) do
    cmd = Enum.join([
      "sudo yum install -y yum-utils",
      "sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo",
      "sudo yum install -y terraform"
    ], " && ")

    {cmd, "."}
  end

  def install_command(:tofu, :amazon_linux) do
    cmd = Enum.join([
      "curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh",
      "chmod +x /tmp/install-opentofu.sh",
      "/tmp/install-opentofu.sh --install-method rpm",
      "rm /tmp/install-opentofu.sh"
    ], " && ")

    {cmd, "."}
  end

  def install_command(:ansible, :amazon_linux) do
    {"pip3 install --user ansible boto3 botocore", "."}
  end

  defp install_tool(tool) do
    platform = detect_platform()

    case install_command(tool, platform) do
      {:error, _} = error ->
        error

      {command, directory} ->
        Mix.shell().info([:yellow, "#{tool} not found, installing for #{platform}..."])

        case DeployEx.Utils.run_command_with_return(command, directory) do
          {:ok, _output} ->
            Mix.shell().info([:green, "#{tool} installed successfully"])
            :ok

          {:error, error} ->
            {:error, ErrorMessage.internal_server_error(
              "#{__MODULE__}: failed to install #{tool}, error: #{inspect(error)}"
            )}
        end
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
