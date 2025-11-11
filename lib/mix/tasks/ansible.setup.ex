defmodule Mix.Tasks.Ansible.Setup do
  use Mix.Task

  @ansible_default_path DeployEx.Config.ansible_folder_path()
  @default_setup_max_concurrency 4

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
  - `quiet` - Suppress output messages
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella(),
         :ok <- DeployExHelpers.ensure_ansible_installed() do
      opts = args
        |> parse_args
        |> Keyword.put_new(:directory, @ansible_default_path)
        |> Keyword.put_new(:parallel, @default_setup_max_concurrency)

      opts = opts
        |> Keyword.put(:only, Keyword.get_values(opts, :only))
        |> Keyword.put(:except, Keyword.get_values(opts, :except))

      ansible_args = DeployEx.Ansible.parse_args(args)

      DeployExHelpers.check_file_exists!(Path.join(opts[:directory], "aws_ec2.yaml"))
      relative_directory = String.replace(Path.absname(opts[:directory]), "#{File.cwd!()}/", "")

      opts[:directory]
        |> Path.join("setup/*.yaml")
        |> Path.wildcard
        |> Enum.map(&Path.relative_to(&1, relative_directory))
        |> DeployExHelpers.filter_only_or_except(opts[:only], opts[:except])
        |> Task.async_stream(fn setup_file ->
          DeployEx.Utils.run_command(
            "ansible-playbook #{setup_file} #{ansible_args}",
            opts[:directory]
          )
        end, max_concurrency: opts[:parallel], timeout: :timer.minutes(30))
        |> Stream.run

      Mix.shell().info([:green, "Finished setting up nodes"])
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory],
      switches: [
        directory: :string,
        only: :keep,
        except: :keep,
        force: :boolean,
        quiet: :boolean
      ]
    )

    opts
  end
end
