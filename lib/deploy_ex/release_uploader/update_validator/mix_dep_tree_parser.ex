defmodule DeployEx.ReleaseUploader.UpdateValidator.MixDepsTreeParser do
  def dep_connected?(app_dep_tree, app_name, dep_name) do
    dep_name in Keyword.get(app_dep_tree, app_name, [])
  end

  def load_app_dep_tree do
    case System.shell("mix deps.tree --format plain") do
      {output, 0} -> {:ok, parse_deps_tree(output)}

      {output, code} -> {:error, ErrorMessage.failed_dependency(
        "couldn't run mix deps.tree",
        %{output: output, code: code}
      )}
    end
  end

  def parse_deps_tree(cmd_output) do
    cmd_output
      |> String.trim_trailing("\n")
      |> String.split("==>")
      |> tl
      |> Enum.map(&(&1 |> String.split("\n") |> parse_project_deps))
  end

  defp parse_project_deps(project_deps) do
    project_name = project_deps |> hd |> String.trim
    project_deps = project_deps
      |> Enum.filter(&(&1 =~ ~r/^(\||`)--/))
      |> Enum.flat_map(fn x ->
        (Regex.run(~r/^(\||`)-- (?<dep_name>[a-z0-9_]+) /, x, capture: [:dep_name])) || []
      end)


    {project_name, project_deps}
  end
end
