defmodule DeployExHelpers do
  @server_ssh_pem_path "./_build/.server-ssh"

  def project_apps, do: File.ls!(Mix.Project.get().project()[:apps_path])

  def release_apps_by_release_name do
    with {:ok, releases} <- fetch_mix_releases() do
      {:ok, Enum.map(releases, fn {key, opts} ->
        {key, opts[:applications]
          |> Keyword.keys
          |> Enum.map(&to_string/1)
          |> Enum.filter(&(&1 in DeployExHelpers.project_apps()))}
      end)}
    end
  end

  def project_name, do: Mix.Project.get() |> Module.split |> hd
  def underscored_project_name, do: Macro.underscore(project_name())
  def kebab_project_name, do: String.replace(underscored_project_name(), "_", "-")
  def title_case_project_name, do: DeployEx.Utils.upper_title_case(underscored_project_name())

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

  def find_project_name(app_params) do
    with {:ok, releases} <- fetch_mix_releases() do
      find_project_name(releases, app_params)
    end
  end

  def find_project_name(_releases, []) do
    {:error, ErrorMessage.bad_request("must supply a app name")}
  end

  def find_project_name(_releases, [_, _]) do
    {:error, ErrorMessage.bad_request("only one node is supported")}
  end

  def find_project_name(releases, [app_name]) do
    case releases |> Keyword.keys |> Enum.find(&(to_string(&1) =~ app_name)) do
      nil -> {:ok, app_name}
      app_name -> {:ok, to_string(app_name)}
    end
  end

  def run_ssh_command_with_return(terraform_directory, pem, app_name, command, opts) do
    with {:ok, pem_file_path} <- DeployEx.Terraform.find_pem_file(terraform_directory, pem),
         {:ok, instance_details} <- DeployEx.AwsMachine.find_instance_details(project_name(), app_name, opts) do
      pem_rsa_path = Path.join(@server_ssh_pem_path, "id_rsa")

      if not File.exists?(pem_rsa_path) do
        Mix.shell().info([:yellow, "Creating pemfolder at #{@server_ssh_pem_path}"])

        File.mkdir_p!(@server_ssh_pem_path)
        File.cp!(pem_file_path, pem_rsa_path)
      end

      res = instance_details
        |> prompt_for_instance_choice(true)
        |> Enum.map(fn ip_address ->
          Mix.shell().info([:yellow, "Running '#{command}' on #{ip_address}"])
          DeployEx.SSH.run_command(ip_address, opts[:port] || 22, pem_rsa_path, command)
        end)
        |> DeployEx.Utils.reduce_status_tuples

      with {:error, [error]} <- res do
        {:error, error}
      end
    end
  end

  def run_ssh_command(terraform_directory, pem, app_name, command, opts) do
    with {:ok, pem_file_path} <- DeployEx.Terraform.find_pem_file(terraform_directory, pem),
         {:ok, instance_details} <- DeployEx.AwsMachine.find_instance_details(project_name(), app_name, opts) do
      pem_rsa_path = Path.join(@server_ssh_pem_path, "id_rsa")

      if not File.exists?(pem_rsa_path) do
        Mix.shell().info([:yellow, "Creating pemfolder at #{@server_ssh_pem_path}"])

        File.mkdir_p!(@server_ssh_pem_path)
        File.cp!(pem_file_path, pem_rsa_path)
      end

      instance_details
        |> prompt_for_instance_choice(true)
        |> Enum.each(fn instance_ip ->
          Mix.shell().info([:yellow, "Running #{command} on #{instance_ip}"])
          DeployEx.SSH.run_command(instance_ip, opts[:port] || 22, @server_ssh_pem_path, command)
        end)
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

    value = prompt |> Mix.shell().prompt() |> String.trim()

    cond do
      value === "" -> prompt_for_choice(choices, select_all?)

      value === "a" -> choices

      String.to_integer(value) in Range.new(0, length(choices) - 1) ->
        value |> String.to_integer |> then(&[Enum.at(choices, &1)])

      true -> prompt_for_choice(choices, select_all?)
    end
  end

  def prompt_for_instance_choice(instance_details, select_all? \\ true) do
    ip_map = Map.new(instance_details, &{&1.name, &1.ipv6 || &1.ip})

    instance_details
      |> Enum.map(&(&1.name))
      |> DeployExHelpers.prompt_for_choice(select_all?)
      |> Enum.map(&ip_map[&1])
  end

  def ensure_ansible_installed do
    case System.cmd("which", ["ansible-playbook"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        Mix.shell().info([:yellow, "Ansible not found, installing..."])

        case System.cmd("pip3", ["install", "--user", "ansible", "boto3", "botocore"], stderr_to_stdout: true) do
          {_, 0} ->
            Mix.shell().info([:green, "✓ Ansible installed successfully"])
            :ok

          {error, _} ->
            Mix.shell().error("Failed to install ansible: #{error}")
            Mix.shell().info("Please install ansible manually: pip3 install ansible boto3 botocore")
            {:error, "Ansible installation failed"}
        end
    end
  end
end
