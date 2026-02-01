defmodule DeployEx.ReleaseTracker do
  @release_state_prefix "release-state"

  def current_release_key(app_name) do
    "#{@release_state_prefix}/#{app_name}/current_release.txt"
  end

  def release_history_key(app_name) do
    "#{@release_state_prefix}/#{app_name}/release_history.txt"
  end

  def fetch_current_release(app_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.get_object(current_release_key(app_name))
    |> ExAws.request(region: region)
    |> handle_get_response()
  end

  def fetch_release_history(app_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    bucket
    |> ExAws.S3.get_object(release_history_key(app_name))
    |> ExAws.request(region: region)
    |> handle_get_response()
  end

  def set_current_release(app_name, release_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    with {:ok, _} <- append_to_release_history(app_name, release_name, opts) do
      bucket
      |> ExAws.S3.put_object(current_release_key(app_name), "#{release_name}\n")
      |> ExAws.request(region: region)
      |> handle_put_response()
    end
  end

  def append_to_release_history(app_name, release_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    bucket = opts[:bucket] || DeployEx.Config.aws_release_bucket()

    existing_history = case fetch_release_history(app_name, opts) do
      {:ok, history} -> history
      {:error, _} -> ""
    end

    new_history = "#{String.trim(existing_history)}\n#{release_name}\n"
      |> String.trim_leading("\n")

    bucket
    |> ExAws.S3.put_object(release_history_key(app_name), new_history)
    |> ExAws.request(region: region)
    |> handle_put_response()
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

  defp handle_get_response({:ok, %{body: body}}), do: {:ok, String.trim(body)}

  defp handle_get_response({:error, {:http_error, 404, _}}) do
    {:error, ErrorMessage.not_found("release state not found")}
  end

  defp handle_get_response({:error, {:http_error, status, reason}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["aws failure", %{reason: reason}])}
  end

  defp handle_get_response({:error, error}) when is_binary(error) do
    {:error, ErrorMessage.failed_dependency("aws failure: #{error}")}
  end

  defp handle_put_response({:ok, _}), do: {:ok, :uploaded}

  defp handle_put_response({:error, {:http_error, status, reason}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["aws failure", %{reason: reason}])}
  end

  defp handle_put_response({:error, error}) when is_binary(error) do
    {:error, ErrorMessage.failed_dependency("aws failure: #{error}")}
  end
end
