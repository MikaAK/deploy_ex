defmodule DeployExHelpers do
  @server_ssh_pem_path "./_build/.server-ssh"

  @ansible_flags [
    inventory: :string,
    limit: :string,
    extra_vars: :keep
  ]

  @terraform_flags [
    var_file: :string
  ]

  def app_name, do: Mix.Project.get() |> Module.split |> hd
  def underscored_app_name, do: Macro.underscore(app_name())
  def kebab_app_name, do: String.replace(underscored_app_name(), "_", "-")

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

  def to_terraform_args(args) do
    {terraform_opts, _extra_args, _invalid_args} =
      OptionParser.parse(args,
        strict: @terraform_flags
      )

    terraform_opts
    |> OptionParser.to_argv(@terraform_flags)
    |> Enum.join(" ")
  end

  def to_ansible_args(args) do
    {ansible_opts, _extra_args, _invalid_args} =
      OptionParser.parse(args,
        aliases: [i: :inventory, e: :extra_vars],
        strict: @ansible_flags
      )

    ansible_opts
    |> OptionParser.to_argv(@ansible_flags)
    |> Enum.map(fn part ->
      if part =~ " " do
        "'#{part}'"
      else
        part
      end
    end)
    |> Enum.join(" ")
  end

  def run_command(command, directory) do
    opts = [
      cd: directory,
      into: IO.binstream(:stdio, :line),
      stderr_to_stdout: true,
      env: %{"ANSIBLE_FORCE_COLOR" => "true"}
    ]

    case System.shell(command, opts) do
      {_, 0} -> :ok
      {error, code} -> {:error, ErrorMessage.internal_server_error("couldn't run #{command}", %{error: error, code: code})}
    end
  end

  def run_command_with_input(command, directory) do
    if root_user?() do
      Exexec.start_link(
        root: true,
        user: "root",
        limit_users: ["root"],
        env: [{"SHELL", System.get_env("SHELL", "/bin/bash")}]
      )
    else
      Exexec.start_link()
    end

    port = Port.open({:spawn, command}, [
      :nouse_stdio,
      :exit_status,
      {:cd, directory}
    ])

    Exexec.manage(port, [
      monitor: true,
      sync: true,
      stdin: true,
      pty: true,
      cd: directory,
      stderr: :stdout,
      stdout: fn _, _, c -> Enum.into([c], IO.stream(:stdio, :line)) end
    ])

    receive do
      {^port, {:exit_status, 0}} -> :ok

      {^port, {:exit_status, code}} ->
        {:error, ErrorMessage.internal_server_error("couldn't run #{command}", %{code: code})}
    end
  end

  def root_user?, do: current_os_user() === "root"

  def current_os_user do
    case System.shell("whoami", []) do
      {result, 0} -> String.trim(result)
      {reason, _} -> raise "Couldn't determine system user:\n\n    #{reason}"
    end
  end

  def fetch_mix_releases do
    case Mix.Project.get() do
      nil -> {:error, ErrorMessage.not_found("couldn't find mix project")}
      project ->
        if project.project()[:releases] do
          {:ok, project.project()[:releases]}
        else
          {:error, ErrorMessage.not_found("no release found for #{inspect project}")}
        end
    end
  end

  def fetch_mix_release_names do
    with {:ok, releases} <- fetch_mix_releases() do
      {:ok, Keyword.keys(releases)}
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
      output
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

  def terraform_security_group_id(terraform_directory) do
    terraform_state_show = "terraform state show 'module.app_security_group.module.sg.aws_security_group.this_name_prefix[0]'" <>
                           "| grep 'id.*sg-' " <>
                           "| awk '{print $3}' " <>
                           "| awk '{print substr($0, 2, length($0) - 2)}'"

    case System.shell(terraform_state_show, cd: Path.expand(terraform_directory)) do
      {output, 0} ->
        security_group_id = String.trim(output)

        if security_group_id === "" do
          {:error, ErrorMessage.not_found("couldn't pull out security group id from terraform")}
        else
          {:ok, security_group_id}
        end

      {message, _} ->
        {:error, ErrorMessage.failed_dependency("terraform output failed", %{message: message})}
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

  def prompt_for_choice(choices, select_all? \\ false)

  def prompt_for_choice([choice], _select_all?) do
    [choice]
  end

  def prompt_for_choice(choices, select_all?) do
    Enum.each(Enum.with_index(choices), fn {value, i} -> Mix.shell().info("#{i}) #{value}") end)

    prompt = "Make a selection between 0 and #{length(choices) - 1}"
    prompt = if select_all?, do: "#{prompt}, or type a to select all:", else: prompt

    value = String.trim(Mix.shell().prompt(prompt))
    valid_choices = Enum.map(0..(length(choices) - 1), &to_string/1)
    valid_choices = if select_all?, do: ["a" | valid_choices], else: valid_choices

    cond do
      value in valid_choices -> value |> String.to_integer |> then(&Enum.at(choices, &1))
      value === "a" -> choices
      true -> prompt_for_choice(choices, select_all?)
    end
  end

  def find_app_name(app_params) do
    with {:ok, releases} <- fetch_mix_releases() do
      find_app_name(releases, app_params)
    end
  end

  def find_app_name(_releases, []) do
    {:error, ErrorMessage.bad_request("must supply a app name")}
  end

  def find_app_name(_releases, [_, _]) do
    {:error, ErrorMessage.bad_request("only one node is supported")}
  end

  def find_app_name(releases, [app_name]) do
    case releases |> Keyword.keys |> Enum.find(&(to_string(&1) =~ app_name)) do
      nil -> {:ok, app_name}
      app_name -> {:ok, to_string(app_name)}
    end
  end

  def run_ssh_command(terraform_directory, app_name, port \\ 22, command) do
    with {:ok, pem_file_path} <- find_pem_file(terraform_directory),
         {:ok, instance_ips} <- find_terraform_instance_ips(terraform_directory, app_name) do
      pem_rsa_path = Path.join(@server_ssh_pem_path, "id_rsa")

      if not File.exists?(pem_rsa_path) do
        Mix.shell().info([:yellow, "Creating pemfolder at #{@server_ssh_pem_path}"])

        File.mkdir_p!(@server_ssh_pem_path)
        File.cp!(pem_file_path, pem_rsa_path)
      end

      Enum.each(instance_ips, fn instance_ip ->
        Mix.shell().info([:yellow, "Running #{command} on #{instance_ip}"])
        DeployEx.SSH.run_command(instance_ip, port, @server_ssh_pem_path, command)
      end)
    end
  end

  def find_terraform_instance_ips(terraform_directory, app_name) do
    with {:ok, instance_ips} <- terraform_instance_ips(terraform_directory) do
      case Enum.find_value(instance_ips, fn {key, values} -> if key =~ app_name, do: values end) do
        nil ->
          {:error, ErrorMessage.not_found(
            "no app names found with #{app_name}",
            %{app_names: Map.keys(instance_ips)}
          )}

        [ip] -> {:ok, [ip]}

        ips -> {:ok, prompt_for_choice(ips, true)}
      end
    end
  end
end
