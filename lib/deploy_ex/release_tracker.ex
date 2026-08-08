defmodule DeployEx.ReleaseTracker do
  @moduledoc """
  Tracks which release is current for an app, and the history of what came before it.

  Both live at fixed keys in the release container, read and written through the
  provider-neutral `DeployEx.Cloud.S3ObjectStore`. Nothing here lists the container, so there
  is no pagination surface to truncate.
  """

  alias DeployEx.Cloud.S3ObjectStore

  @release_state_prefix "release-state"

  def current_release_key(app_name, opts \\ []) do
    "#{release_state_prefix(opts)}/#{app_name}/current_release.txt"
  end

  def release_history_key(app_name, opts \\ []) do
    "#{release_state_prefix(opts)}/#{app_name}/release_history.txt"
  end

  def fetch_current_release(app_name, opts \\ []) do
    app_name
    |> current_release_key(opts)
    |> fetch_release_state(opts)
  end

  def fetch_release_history(app_name, opts \\ []) do
    app_name
    |> release_history_key(opts)
    |> fetch_release_state(opts)
  end

  def set_current_release(app_name, release_name, opts \\ []) do
    with {:ok, _} <- append_to_release_history(app_name, release_name, opts) do
      app_name
      |> current_release_key(opts)
      |> put_release_state("#{release_name}\n", opts)
    end
  end

  def append_to_release_history(app_name, release_name, opts \\ []) do
    existing_history = case fetch_release_history(app_name, opts) do
      {:ok, history} -> history
      {:error, _} -> ""
    end

    new_history = "#{String.trim(existing_history)}\n#{release_name}\n"
      |> String.trim_leading("\n")

    app_name
    |> release_history_key(opts)
    |> put_release_state(new_history, opts)
  end

  def list_release_history(app_name, limit \\ 25, opts \\ []) do
    with {:ok, history} <- fetch_release_history(app_name, opts) do
      releases = history
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.take(limit)

      {:ok, releases}
    end
  end

  defp fetch_release_state(key, opts) do
    case S3ObjectStore.get_object(bucket(opts), key, region: region(opts)) do
      {:ok, body} -> {:ok, String.trim(body)}
      {:error, error} -> {:error, translate_error(error)}
    end
  end

  defp put_release_state(key, body, opts) do
    case S3ObjectStore.put_object(bucket(opts), key, body, region: region(opts)) do
      :ok -> {:ok, :uploaded}
      {:error, error} -> {:error, translate_error(error)}
    end
  end

  defp translate_error(%ErrorMessage{code: :not_found}) do
    ErrorMessage.not_found("release state not found")
  end

  defp translate_error(%ErrorMessage{code: code, message: message, details: details}) do
    %ErrorMessage{code: code, message: "aws failure", details: reason_details(details, message)}
  end

  defp reason_details(details, message) when is_map(details) do
    details |> Map.delete(:message) |> Map.put(:reason, message)
  end

  defp reason_details(_details, message), do: %{reason: message}

  defp bucket(opts), do: opts[:bucket] || DeployEx.Config.aws_release_bucket()

  defp region(opts), do: opts[:region] || DeployEx.Config.aws_region()

  defp release_state_prefix(opts) when is_map(opts) do
    release_state_prefix(Map.to_list(opts))
  end

  defp release_state_prefix(opts) when is_list(opts) do
    case Keyword.get(opts, :release_state_prefix) do
      prefix when is_binary(prefix) and prefix !== "" -> prefix
      _ -> build_release_state_prefix(opts)
    end
  end

  defp build_release_state_prefix(opts) do
    release_prefix = case Keyword.get(opts, :release_prefix) do
      prefix when is_binary(prefix) and prefix !== "" -> prefix
      _ -> if Keyword.get(opts, :qa_release) === true, do: "qa", else: nil
    end

    case release_prefix do
      nil -> @release_state_prefix
      "" -> @release_state_prefix
      prefix -> "#{@release_state_prefix}/#{prefix}"
    end
  end
end
