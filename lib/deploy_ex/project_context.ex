defmodule DeployEx.ProjectContext do
  require Logger

  alias DeployEx.ReleaseUploader.RedeployConfig

  @spec type(module()) :: :umbrella | :single_app
  def type(mix_project \\ Mix.Project) do
    if mix_project.umbrella?(), do: :umbrella, else: :single_app
  end

  @spec apps(module()) :: [String.t()]
  def apps(mix_project \\ Mix.Project) do
    case type(mix_project) do
      :umbrella ->
        mix_project.apps_paths()
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.sort()

      :single_app ->
        [to_string(mix_project.get().project()[:app])]
    end
  end

  @spec app_path(String.t(), module()) :: String.t() | nil
  def app_path(app_name, mix_project \\ Mix.Project) do
    case type(mix_project) do
      :umbrella -> Map.get(mix_project.apps_paths(), String.to_atom(app_name))
      :single_app -> File.cwd!()
    end
  end

  @spec releases(module()) :: {:ok, keyword()} | {:error, ErrorMessage.t()}
  def releases(mix_project \\ Mix.Project) do
    project_module = mix_project.get()

    if is_nil(project_module) do
      {:error, ErrorMessage.not_found("couldn't find mix project")}
    else
      opts = project_module.project()

      cond do
        opts[:releases] ->
          {:ok, opts[:releases]}

        type(mix_project) === :single_app and opts[:app] ->
          app_name = opts[:app]
          {:ok, [{app_name, [applications: [{app_name, :permanent}]]}]}

        true ->
          {:error, ErrorMessage.not_found("no releases defined and could not infer app name")}
      end
    end
  end

  @spec redeploy_config(atom(), module()) ::
          {:ok, RedeployConfig.t()} | {:error, ErrorMessage.t()}
  def redeploy_config(release_name, mix_project \\ Mix.Project) do
    with {:ok, releases} <- releases(mix_project) do
      deploy_ex_opts = releases |> Keyword.get(release_name, []) |> Keyword.get(:deploy_ex, [])
      redeploy_opts = Keyword.get(deploy_ex_opts, :redeploy_config, [])

      config = %RedeployConfig{
        whitelist: redeploy_opts[:whitelist],
        blacklist: redeploy_opts[:blacklist]
      }

      {:ok, config}
    end
  end

  @doc """
  Discovers the Elixir module prefix for an OTP app by reading its source files.

  `Macro.camelize/1` is wrong for apps with acronyms (`cfx_web` becomes `CfxWeb`
  instead of `CFXWeb`). This function reads the actual module name from disk in
  priority order:

  1. `apps/<app>/lib/**/endpoint.ex` — Phoenix app
  2. `apps/<app>/lib/**/application.ex` — OTP application module
  3. `apps/<app>/lib/<app>.ex` — plain library with a top-level module

  Returns `{:error, %ErrorMessage{}}` if the app isn't in the project or no
  recognizable module file is found.
  """
  @spec module_prefix(String.t(), module()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}
  def module_prefix(app_name, mix_project \\ Mix.Project) do
    case app_path(app_name, mix_project) do
      nil ->
        {:error, ErrorMessage.not_found("app not found in project", %{app_name: app_name})}

      path ->
        discover_module_prefix_from_path(path, app_name)
    end
  end

  @doc """
  Like `module_prefix/2` but never fails — falls back to `Macro.camelize/1` with a
  warning log when discovery fails. Useful for callers that need a best-effort
  string and can tolerate a wrong prefix for acronym-containing apps.
  """
  @spec module_prefix_or_camelize(String.t(), module()) :: String.t()
  def module_prefix_or_camelize(app_name, mix_project \\ Mix.Project) do
    case module_prefix(app_name, mix_project) do
      {:ok, prefix} ->
        prefix

      {:error, error} ->
        Logger.warning(
          "#{__MODULE__}: module prefix discovery failed for #{inspect(app_name)}, " <>
            "falling back to Macro.camelize: #{inspect(error)}"
        )

        Macro.camelize(app_name)
    end
  end

  @spec check_valid_project(module()) :: :ok | {:error, ErrorMessage.t()}
  def check_valid_project(mix_project \\ Mix.Project) do
    project_module = mix_project.get()

    cond do
      is_nil(project_module) ->
        {:error, ErrorMessage.bad_request("could not find mix project")}

      mix_project.umbrella?() ->
        :ok

      project_module.project()[:app] ->
        :ok

      true ->
        {:error,
         ErrorMessage.bad_request(
           "could not determine apps for this project — ensure mix.exs defines :app or :releases"
         )}
    end
  end

  defp discover_module_prefix_from_path(app_path, app_name) do
    case Enum.find_value(module_source_patterns(), &find_prefix_in_source(&1, app_path, app_name)) do
      nil ->
        {:error,
         ErrorMessage.not_found("could not find Elixir module in app source", %{
           app_name: app_name,
           app_path: app_path
         })}

      prefix ->
        {:ok, prefix}
    end
  end

  defp module_source_patterns do
    [
      {"lib/**/endpoint.ex", ~r/defmodule\s+([\w.]+?)\.Endpoint\s+do/},
      {"lib/**/application.ex", ~r/defmodule\s+([\w.]+?)\.Application\s+do/},
      {"lib/<app>.ex", ~r/defmodule\s+([\w.]+?)\s+do/}
    ]
  end

  defp find_prefix_in_source({"lib/<app>.ex", regex}, app_path, app_name) do
    app_path |> Path.join("lib/#{app_name}.ex") |> extract_prefix(regex)
  end

  defp find_prefix_in_source({wildcard, regex}, app_path, _app_name) do
    app_path |> Path.join(wildcard) |> Path.wildcard() |> Enum.find_value(&extract_prefix(&1, regex))
  end

  defp extract_prefix(file_path, regex) do
    with true <- File.regular?(file_path),
         {:ok, content} <- File.read(file_path),
         [_, prefix] <- Regex.run(regex, content) do
      prefix
    else
      _ -> nil
    end
  end
end
