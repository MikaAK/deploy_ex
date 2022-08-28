defmodule DeployExHelpers do
  def app_name, do: Mix.Project.get() |> Module.split |> hd
  def underscored_app_name, do: Macro.underscore(app_name)

  def check_in_umbrella do
    if Mix.Project.umbrella?() do
      :ok
    else
      {:error, ErrorMessage.bad_request("must be in umbrella root")}
    end
  end

  def priv_file(priv_subdirectory) do
    :deploy_ex
      |> :code.priv_dir
      |> Path.join(priv_subdirectory)
  end

  def write_file(file_path, contents, opts) do
    if opts[:message] do
      if opts[:force] || Mix.Generator.overwrite?(file_path, contents) do
        File.write!(file_path, contents)

        if !opts[:quiet] do
          Mix.shell().info(opts[:message])
        end
      end
    else
      Mix.Generator.create_file(file_path, contents, opts)
    end
  end

  def check_file_exists!(file_path) do
    if !File.exists?(file_path) do
      raise to_string(IO.ANSI.format([
        :red, "Cannot find ",
        :bright, "#{file_path}", :reset
      ]))
    end
  end

  def upper_title_case(string) do
    string |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
  end
end
