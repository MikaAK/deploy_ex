defmodule DeployExHelpers do
  def app_name, do: Mix.Project.get() |> Module.split |> hd
  def underscored_app_name, do: Macro.underscore(app_name())

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

  def write_template(template_path, output_path, variables, opts) do
    output_file = EEx.eval_file(template_path, assigns: variables)

    opts = if File.exists?(output_path) do
      [{:message, [:green, "* rewriting ", :reset, output_path]} | opts]
    else
      opts
    end

    DeployExHelpers.write_file(output_path, output_file, opts)
  end

  def write_file(file_path, contents, opts) do
    if opts[:message] do
      if opts[:force] || Mix.Generator.overwrite?(file_path, contents) do
        if not File.exists?(Path.dirname(file_path)) do
          File.mkdir_p!(Path.dirname(file_path))
        end

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
    string |> String.split(~r/_|-/) |> Enum.map_join(" ", &String.capitalize/1)
  end

  @ansible_flags [
    inventory: :string,
    limit: :string,
    extra_vars: :keep
  ]
  def to_ansible_args(args) do
    {ansible_opts, _extra_args, _invalid_args} =
      OptionParser.parse(args,
        aliases: [i: :inventory, l: :limit, e: :extra_vars],
        strict: @ansible_flags
      )

    ansible_opts
    |> OptionParser.to_argv(@ansible_flags)
    |> Enum.join(" ")
  end
  def run_command_with_input(command, directory) do
    port = Port.open({:spawn, command}, [
      :nouse_stdio,
      :exit_status,
      {:cd, directory}
    ])

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, code}} -> {:error, ErrorMessage.internal_server_error("couldn't run #{command}", %{code: code})}
    end
  end

  def fetch_mix_releases do
    case Mix.Project.get() do
      nil -> {:error, ErrorMessage.not_found("couldn't find mix project")}
      project -> {:ok, project.releases()}
    end
  end

  def find_pem_file(terraform_directory) do
    res = terraform_directory
      |> Path.join("*.pem")
      |> Path.wildcard()
      |> List.first

    if is_nil(res) do
      {:error, ErrorMessage.not_found("couldn't find pem file in #{terraform_directory}")}
    else
      {:ok, res}
    end
  end

  def filter_only_or_except(playbooks, only, except) do
    Enum.filter(playbooks, &filtered_with_only_or_except?(&1, only, except))
  end

  defp filtered_with_only_or_except?(playbook, only, nil) do
    filtered_with_only_or_except?(playbook, only, [])
  end

  defp filtered_with_only_or_except?(playbook, nil, except) do
    filtered_with_only_or_except?(playbook, [], except)
  end

  defp filtered_with_only_or_except?(playbook, only, except) when is_binary(except) do
    filtered_with_only_or_except?(playbook, only, [except])
  end

  defp filtered_with_only_or_except?(playbook, only, except) when is_binary(only) do
    filtered_with_only_or_except?(playbook, [only], except)
  end

  defp filtered_with_only_or_except?(_playbook, [], []) do
    true
  end

  defp filtered_with_only_or_except?(playbook, only, except) do
    only_given? = Enum.any?(only)
    except_given? = Enum.any?(except)

    cond do
      except_given? and only_given? ->
        raise to_string(IO.ANSI.format([
          :red,
          "Cannot specify both only and except arguments"
        ]))

      only_given? ->
        app_name = Path.basename(playbook)

        Enum.any?(only, &(app_name =~ &1))

      except_given? ->
        app_name = Path.basename(playbook)

        not Enum.any?(except, &(app_name =~ &1))
    end
  end

  def terraform_state(terraform_directory) do
    case System.shell("terraform state list", cd: Path.expand(terraform_directory)) do
      {output, 0} -> {:ok, output}

      {message, _} ->
        {:error, ErrorMessage.failed_dependency("terraform state list failed", %{message: message})}
    end
  end

  def terraform_instances(terraform_directory) do
    with {:ok, output} <- terraform_state(terraform_directory) do
      a = output
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/module.ec2_instance.*ec2_instance/))
        |> Enum.map(fn resource ->
          case Regex.run(
            ~r/module\.ec2_instance\["(.*?)"\]\.aws_instance\.ec2_instance\[(.*)\]/,
            resource
          ) do
            [_, node, num] -> {node, String.to_integer(num)}
            _ -> Mix.raise("Error decoding node numbers from resource: #{resource}")
          end
        end)
        |> then(&{:ok, &1})
    end
  end

  def terraform_instance_ips(terraform_directory) do
    case System.shell("terraform output --json", cd: Path.expand(terraform_directory)) do
      {output, 0} ->
        {:ok, parse_terraform_output_to_ips(output)}

      {message, _} ->
        {:error, ErrorMessage.failed_dependency("terraform output failed", %{message: message})}
    end
  end

  defp parse_terraform_output_to_ips(output) do
    case Jason.decode!(output) do
      %{"public_ips" => %{"value" => values}} -> values
      _ -> []
    end
  end
end
