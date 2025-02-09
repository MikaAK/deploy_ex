defmodule DeployEx.SSH do
  def connect_to_ssh(ip, port \\ 22, key_directory, user \\ "admin") do
    :ssh.connect(String.to_charlist(ip), port,
      user: String.to_charlist(user),
      user_dir: String.to_charlist(key_directory)
    )
  end

  def run_command(ip, port \\ 22, key_directory, command) do
    case connect_to_ssh(ip, port, key_directory) do
      {:error, reason} -> ErrorMessage.bad_gateway("couldn't connect over ssh: #{reason}")

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
      "-f", "-N",
      "-L", "#{local_port}:#{target_host}:#{target_port}",
      "admin@#{jump_server_ip}"
    ]

    case System.cmd("ssh", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      error when is_list(error) ->
        error_string = List.to_string(error)
        Mix.shell().error(error_string)
        {:error, "Failed to setup SSH tunnel: #{error_string}"}
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
