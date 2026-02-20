defmodule DeployEx.ReleaseUploader.RedeployConfig do
  defstruct [:whitelist, :blacklist]

  @type t :: %__MODULE__{
    whitelist: [Regex.t()] | nil,
    blacklist: [Regex.t()] | nil
  }

  @spec from_keyword(keyword() | nil) :: %{String.t() => t()}
  def from_keyword(nil), do: %{}
  def from_keyword(config) when is_list(config) do
    Map.new(config, fn {app_name, opts} ->
      {to_string(app_name), %__MODULE__{
        whitelist: compile_patterns(opts[:whitelist]),
        blacklist: compile_patterns(opts[:blacklist])
      }}
    end)
  end

  @spec filter_file_diffs([String.t()], String.t(), %{String.t() => t()}) :: [String.t()]
  def filter_file_diffs(file_diffs, app_name, redeploy_config) when is_map(redeploy_config) do
    case Map.get(redeploy_config, app_name) do
      nil -> file_diffs
      %__MODULE__{} = config -> apply_filters(file_diffs, config)
    end
  end

  def filter_file_diffs(file_diffs, _app_name, _redeploy_config), do: file_diffs

  @spec has_whitelist?(String.t(), %{String.t() => t()}) :: boolean()
  def has_whitelist?(app_name, redeploy_config) when is_map(redeploy_config) do
    case Map.get(redeploy_config, app_name) do
      %__MODULE__{whitelist: whitelist} when is_list(whitelist) -> true
      _ -> false
    end
  end

  def has_whitelist?(_app_name, _redeploy_config), do: false

  defp apply_filters(file_diffs, %__MODULE__{whitelist: whitelist, blacklist: blacklist}) do
    file_diffs
    |> maybe_apply_whitelist(whitelist)
    |> maybe_apply_blacklist(blacklist)
  end

  defp maybe_apply_whitelist(file_diffs, nil), do: file_diffs
  defp maybe_apply_whitelist(file_diffs, whitelist) do
    Enum.filter(file_diffs, fn file ->
      Enum.any?(whitelist, &Regex.match?(&1, file))
    end)
  end

  defp maybe_apply_blacklist(file_diffs, nil), do: file_diffs
  defp maybe_apply_blacklist(file_diffs, blacklist) do
    Enum.reject(file_diffs, fn file ->
      Enum.any?(blacklist, &Regex.match?(&1, file))
    end)
  end

  defp compile_patterns(nil), do: nil
  defp compile_patterns([]), do: nil
  defp compile_patterns(patterns) when is_list(patterns) do
    Enum.map(patterns, fn
      %Regex{} = regex -> regex
      pattern when is_binary(pattern) -> Regex.compile!(pattern)
    end)
  end
end
