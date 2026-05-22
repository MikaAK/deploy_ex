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
      id === "alpine" -> :alpine
      id === "amzn" -> :amazon_linux
      id in ["debian", "ubuntu"] -> :debian
      String.contains?(id_like, "debian") -> :debian
      true -> {:error, :unsupported_platform}
    end
  end

  @doc """
  Ensures the given tool is installed on the host, prompting the user for
  consent before running the install command.

  ## Options

    * `:consent_fn` - 2-arity function `fn tool, info -> boolean end`. Defaults
      to an interactive prompt via `Mix.shell().yes?/1`. The `info` map has
      `:platform` and `:command` keys. Override for testing or for callers
      that want to inject their own approval flow.

  Consent prompting is skipped (treated as approved) when the
  `DEPLOY_EX_AUTO_INSTALL` env var is set to `"true"`.
  """
  @spec ensure_installed(:terraform | :ansible | :gh, Keyword.t()) :: :ok | {:error, ErrorMessage.t()}
  def ensure_installed(tool, opts \\ [])

  def ensure_installed(:terraform, opts) do
    iac_tool = DeployEx.Config.iac_tool()

    case System.find_executable(iac_tool) do
      nil ->
        case iac_tool do
          "terraform" -> install_tool(:terraform, opts)
          "tofu" -> install_tool(:tofu, opts)
          other -> {:error, ErrorMessage.bad_request("#{__MODULE__}: unsupported iac_tool #{inspect(other)}, expected \"terraform\" or \"tofu\"")}
        end

      _path -> :ok
    end
  end

  def ensure_installed(:ansible, opts) do
    case System.find_executable("ansible-playbook") do
      nil -> install_tool(:ansible, opts)
      _path -> :ok
    end
  end

  def ensure_installed(:gh, opts) do
    case System.find_executable("gh") do
      nil -> install_tool(:gh, opts)
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
  def install_command(:gh, :macos), do: {"brew install gh", "."}

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

  def install_command(:gh, :debian) do
    cmd = Enum.join([
      "type -p curl >/dev/null || (sudo apt update && sudo apt install -y curl)",
      "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg",
      "sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null",
      "sudo apt update",
      "sudo apt install -y gh"
    ], " && ")

    {cmd, "."}
  end

  # SECTION: Alpine

  def install_command(:terraform, :alpine) do
    {"apk add --no-cache terraform --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community", "."}
  end

  def install_command(:tofu, :alpine) do
    {"apk add --no-cache opentofu --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community", "."}
  end

  def install_command(:ansible, :alpine), do: {"apk add --no-cache ansible", "."}
  def install_command(:gh, :alpine), do: {"sudo apk add --no-cache github-cli", "."}

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

  def install_command(:gh, :amazon_linux), do: {"sudo dnf install -y gh", "."}

  @doc false
  @spec install_tool(:terraform | :tofu | :ansible | :gh, Keyword.t()) :: :ok | {:error, ErrorMessage.t()}
  def install_tool(tool, opts \\ []) do
    platform = detect_platform()

    case install_command(tool, platform) do
      {:error, _} = error ->
        error

      {command, directory} ->
        consent_fn = Keyword.get(opts, :consent_fn, &default_consent?/2)

        if consent_fn.(tool, %{platform: platform, command: command}) do
          run_install_command(tool, command, directory)
        else
          {:error, ErrorMessage.bad_request(
            "#{__MODULE__}: #{tool} install declined by user, install it manually then retry"
          )}
        end
    end
  end

  defp run_install_command(tool, command, directory) do
    Mix.shell().info([:yellow, "Installing #{tool}..."])

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

  @doc false
  @spec default_consent?(atom(), %{platform: atom(), command: String.t()}) :: boolean()
  def default_consent?(tool, %{platform: platform, command: command}) do
    if auto_install?() do
      true
    else
      Mix.shell().info([:yellow, "\n#{tool} is not installed."])
      Mix.shell().info([:reset, "Detected platform: ", :bright, to_string(platform)])
      Mix.shell().info([:reset, "Install command: ", :bright, command])
      Mix.shell().yes?("Install #{tool} now?")
    end
  end

  @doc false
  def auto_install? do
    System.get_env("DEPLOY_EX_AUTO_INSTALL") === "true"
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
