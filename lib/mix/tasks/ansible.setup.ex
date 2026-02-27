defmodule Mix.Tasks.Ansible.Setup do
  use Mix.Task

  @ansible_default_path DeployEx.Config.ansible_folder_path()
  @setup_timeout :timer.minutes(30)
  @setup_max_concurrency 4

  @shortdoc "Initial setup and configuration of Ansible hosts"
  @moduledoc """
  Performs initial setup and configuration of Ansible hosts. This task should be run once
  when new nodes are created.

  The setup process includes:
  - Installing required system packages (awscli, python, pip)
  - Configuring VM settings for optimal BEAM and TCP performance
  - Setting up log rotation
  - Configuring S3 crash dump uploads
  - Setting up server cleanup on termination
  - Installing the application release as a SystemD service

  ## Example
  ```bash
  mix ansible.setup
  mix ansible.setup --only app1 --only app2
  mix ansible.setup --except app3
  ```

  ## Options
  - `directory` - Directory containing ansible playbooks (default: ./deploys/ansible)
  - `parallel` - Maximum number of concurrent setup operations (default: 4)
  - `only` - Only setup specified apps (can be used multiple times)
  - `except` - Skip setup for specified apps (can be used multiple times)
  - `include-qa` - Include QA nodes in setup (default: excluded)
  - `no-tui` - Disable TUI progress display
  - `quiet` - Suppress output messages
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- DeployExHelpers.ensure_ansible_installed() do
      opts = args
        |> parse_args
        |> Keyword.put_new(:directory, @ansible_default_path)
        |> Keyword.put_new(:parallel, @setup_max_concurrency)

      opts = opts
        |> Keyword.put(:only, Keyword.get_values(opts, :only))
        |> Keyword.put(:except, Keyword.get_values(opts, :except))

      ansible_args = args
        |> DeployEx.Ansible.parse_args()
        |> then(fn
          "" -> []
          arg -> [arg]
        end)

      DeployExHelpers.check_file_exists!(Path.join(opts[:directory], "aws_ec2.yaml"))

      DeployEx.TUI.setup_no_tui(opts)

      relative_directory = String.replace(Path.absname(opts[:directory]), "#{File.cwd!()}/", "")

      setup_files = opts[:directory]
        |> Path.join("setup/*.yaml")
        |> Path.wildcard
        |> Enum.map(&Path.relative_to(&1, relative_directory))
        |> DeployExHelpers.filter_only_or_except(opts[:only], opts[:except])

      if Enum.empty?(setup_files) do
        Mix.shell().info([:yellow, "Nothing to setup"])
      else
        run_fn = fn setup_file, line_callback ->
          command = build_setup_command(setup_file, ansible_args, opts)
          DeployEx.Utils.run_command_streaming(command, opts[:directory], line_callback)
        end

        res = DeployEx.TUI.DeployProgress.run(setup_files, run_fn,
          max_concurrency: opts[:parallel],
          timeout: @setup_timeout
        )

        case res do
          {:ok, _} -> :ok

          {:error, [head | tail]} ->
            Enum.each(tail, &Mix.shell().error(to_string(&1)))
            Mix.raise(to_string(head))

          {:error, error} ->
            Mix.raise(to_string(error))
        end
      end
    end
  end

  defp build_setup_command(setup_file, ansible_args, opts) do
    has_custom_limit = Enum.any?(ansible_args, &String.contains?(&1, "--limit"))
    qa_limit = if opts[:include_qa] === true or has_custom_limit, do: [], else: ["--limit", "'!qa_true'"]

    (["ansible-playbook", setup_file] ++ ansible_args ++ qa_limit)
    |> Enum.join(" ")
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory],
      switches: [
        directory: :string,
        only: :keep,
        except: :keep,
        force: :boolean,
        quiet: :boolean,
        parallel: :integer,
        include_qa: :boolean,
        no_tui: :boolean
      ]
    )

    opts
  end
end
