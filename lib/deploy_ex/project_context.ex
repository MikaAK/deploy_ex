defmodule DeployEx.ProjectContext do
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
      :umbrella ->
        Map.get(mix_project.apps_paths(), String.to_atom(app_name))

      :single_app ->
        File.cwd!()
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
end
