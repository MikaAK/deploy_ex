defmodule DeployEx.SSH do
  # :ssh_file (the default :ssh key_cb) only auto-loads identity files with
  # standard names (id_rsa, id_ed25519, ...) from user_dir — an arbitrarily
  # named pem (e.g. a downloaded AWS EC2 key pair) is silently never offered,
  # so publickey auth fails forever. Stage a copy of the pem under the
  # standard name in a private temp dir instead of pointing user_dir at the
  # real pem's directory.
  def connect_to_ssh(ip, port \\ 22, pem_file_path, user \\ "admin") do
    case prepare_identity_dir(pem_file_path) do
      {:ok, key_dir} ->
        try do
          :ssh.connect(to_charlist(ip), port, connect_options(ip, user, key_dir))
        after
          File.rm_rf(key_dir)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  `:ssh.connect/3` options for the given ip/user/key_dir. Pure and pinned directly by tests,
  separated from the identity-file staging IO above so a regression to a hardcoded ssh user
  shows up as a failing assertion on the options themselves.
  """
  def connect_options(ip, user, key_dir) do
    maybe_add_ipv6(ip, [
      {:user, to_charlist(user)},
      {:user_dir, to_charlist(key_dir)},
      {:auth_methods, ~c"publickey"},
      {:user_interaction, false},
      {:silently_accept_hosts, true}
    ])
  end

  @doc false
  def prepare_identity_dir(pem_file_path) do
    with {:ok, pem_content} <- File.read(pem_file_path) do
      key_dir = Path.join(System.tmp_dir!(), "deploy_ex_ssh_key_#{System.unique_integer([:positive])}")
      identity_path = Path.join(key_dir, identity_filename(pem_content))

      File.mkdir_p!(key_dir)
      File.chmod!(key_dir, 0o700)
      File.write!(identity_path, pem_content)
      File.chmod!(identity_path, 0o600)

      {:ok, key_dir}
    end
  end

  # ponytail: classifies by AWS's two pem export shapes (RSA-PEM vs OpenSSH);
  # extend if a consumer ever hands us an EC/DSA key.
  @doc false
  def identity_filename(pem_content) do
    if String.contains?(pem_content, "BEGIN OPENSSH PRIVATE KEY") do
      "id_ed25519"
    else
      "id_rsa"
    end
  end

  defp maybe_add_ipv6(ip_string, opts) do
    if detect_ip_version(ip_string) == :ipv6 do
      [:inet6 | opts]
    else
      opts
    end
  end

  defp detect_ip_version(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(to_charlist(ip_string)) do
      {:ok, {_, _, _, _}} ->
        :ipv4

      {:ok, {_, _, _, _, _, _, _, _}} ->
        :ipv6

      {:error, _reason} ->
        :invalid
    end
  end

  def run_command(ip, port \\ 22, pem_file_path, command, user \\ "admin") do
    case connect_to_ssh(ip, port, pem_file_path, user) do
      {:error, reason} -> {:error, ErrorMessage.bad_gateway("couldn't connect over ssh: #{reason}")}

      {:ok, conn} ->
        conn
          |> run_command(command)
          |> tap(fn _ -> :ssh.close(conn) end)
    end
  end

  def run_command(conn, command) do
    command
      |> String.split(" && ")
      |> Enum.reduce({:ok, ""}, fn
        _, {:error, _} = res -> res
        command, {:ok, acc} ->
          case run_session_command(conn, command) do
            {:ok, string} -> {:ok, acc <> string}
            {:error, e} -> {:error, e}
          end
      end)
  end

  defp run_session_command(conn, command) do
    {:ok, channel} = :ssh_connection.session_channel(conn, :infinity)

    tap(case :ssh_connection.exec(conn, channel, "sudo -u root #{command}", :timer.minutes(2)) do
      :success -> receive_message()

      {:error, reason} -> {:error, ErrorMessage.failed_dependency("ssh command failed", reason)}
    end, fn _ -> :ssh_connection.close(conn, channel) end)
  end

  def receive_message(return_message \\ "") do
    receive do
      {:ssh_cm, _pid, {:data, _cid, 1, data}} -> receive_message(return_message <> data)
      {:ssh_cm, _pid, {:data, _cid, 0, data}} -> receive_message(return_message <> data)
      {:ssh_cm, _pid, {:eof, _cid}} -> receive_message(return_message)
      {:ssh_cm, _pid, {:closed, _cid}} -> receive_message(return_message)

      {:ssh_cm, _pid, {:exit_status, _cid, 0}} -> {:ok, return_message}
      {:ssh_cm, _pid, {:exit_status, _cid, code}} ->
        {:error, ErrorMessage.failed_dependency("return from command failed with code #{code}", %{results: return_message})}

      unhandled ->
        IO.puts("Unhandled Message: ")
        IO.inspect(unhandled)
    after
      :timer.seconds(30) -> {:error, ErrorMessage.failed_dependency("no return from command after 30 seconds")}
    end
  end

  @doc """
  Sets up an SSH tunnel through a jump server.
  Returns :ok or {:error, reason}
  """
  def setup_ssh_tunnel(jump_server_ip, target_host, target_port, local_port, pem_file) do
    abs_pem_file = Path.expand(pem_file)
    args = [
      "-i", abs_pem_file,
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-f", "-N",
      "-L", "#{local_port}:#{target_host}:#{target_port}",
      "admin@#{jump_server_ip}"
    ]

    case System.cmd("ssh", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _code} ->
        Mix.shell().error(output)
        {:error, "Failed to setup SSH tunnel: #{output}"}
    end
  end

  @doc """
  Finds an available local port for tunneling.
  Returns {:ok, port_number} or {:error, reason}
  """
  def find_available_port do
    case :gen_tcp.listen(0, []) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}
      {:error, reason} ->
        {:error, ErrorMessage.internal_server_error("Failed to find available port", %{reason: reason})}
    end
  end

  @doc """
  Cleans up an SSH tunnel by killing the associated process.
  """
  def cleanup_tunnel(local_port) when is_integer(local_port) do
    System.cmd("pkill", ["-f", "ssh.*#{local_port}"])
    :ok
  end
  def cleanup_tunnel(_), do: :ok
end
