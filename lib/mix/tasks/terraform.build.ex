defmodule Mix.Tasks.Terraform.Build do
  use Mix.Task

  @shortdoc "Deploys to terraform resources using ansible"
  @moduledoc """
  Deploys to ansible
  """

  @terraform_file Path.expand("../../deploys/terraform/variables.tf")

  if not File.exists?(@terraform_file) do
    raise "Terraform file doesn't exist at #{@terraform_file}"
  end

  def run(args) do
    terraform_output = LearnElixir.MixProject.releases()
      |> Keyword.keys
      |> Enum.map_join(",\n\n", &(&1 |> to_string |> generate_terraform_output))

    opts = parse_args(args)

    write_to_terraform(terraform_output, opts)
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit],
      switches: [
        force: :boolean,
        quiet: :boolean
      ]
    )

    opts
  end

  defp generate_terraform_output(release_name) do
    """
        #{release_name} = {
          environment = "prod"
          name = "#{title_case(release_name)}"
        }
    """
  end

  defp title_case(string) do
    string |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp write_to_terraform(terraform_output, opts) do
    new_terraform_file = @terraform_file |> File.read! |> inject_terraform_contents(terraform_output)

    if opts[:force] || Mix.Generator.overwrite?(@terraform_file, new_terraform_file) do
      File.write!(@terraform_file, new_terraform_file)

      if !opts[:quiet] do
        Mix.shell().info([:green, "* injecting ", :reset, @terraform_file])
      end
    end
  end

  defp inject_terraform_contents(current_file, terraform_output) do
    current_file = String.split(current_file, "\n")
    project_variable_idx = Enum.find_index(
      current_file,
      &(&1 =~ "variable \"learn_elixir_project\"")
    ) + 4 # 4 is the number of newlines till the default key
    {start_of_file, project_variable} = Enum.split(current_file, project_variable_idx + 1)

    Enum.join(start_of_file ++ String.split(terraform_output, "\n") ++ Enum.take(project_variable, -3), "\n")
  end
end
