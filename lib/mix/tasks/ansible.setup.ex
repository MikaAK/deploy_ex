defmodule Mix.Tasks.Ansible.Setup do
  use Mix.Task

  @ansible_default_path DeployEx.Config.ansible_folder_path()
  @default_setup_max_concurrency 4

  @shortdoc "Setups ansible hosts called once upon node creation"
  @moduledoc """
  Setups ansible hosts called once upon node creation

  This will Load awscli, python, pip and more onto your node, do
  a bunch of VM tuning to support BEAM and better TCP traffic as well
  as setup log rotation and s3 crash_dump upload & server removal

  Finally it'll load your release onto each node and sets it up
  in a SystemD task

  ## Options
  - `directory` - Set ansible directory
  - `parallel` - Sets amount of parallel setups to do at once
  - `only` -  Specify specific apps to setup
  - `except` - Specify apps to not setup
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      opts = args
        |> parse_args
        |> Keyword.put_new(:directory, @ansible_default_path)
        |> Keyword.put_new(:parallel, @default_setup_max_concurrency)

      opts = opts
        |> Keyword.put(:only, Keyword.get_values(opts, :only))
        |> Keyword.put(:except, Keyword.get_values(opts, :except))

      ansible_args = DeployExHelpers.to_ansible_args(args)

      DeployExHelpers.check_file_exists!(Path.join(opts[:directory], "aws_ec2.yaml"))
      relative_directory = String.replace(Path.absname(opts[:directory]), "#{File.cwd!()}/", "")

      opts[:directory]
        |> Path.join("setup/*.yaml")
        |> Path.wildcard
        |> Enum.map(&Path.relative_to(&1, relative_directory))
        |> DeployExHelpers.filter_only_or_except(opts[:only], opts[:except])
        |> Task.async_stream(fn setup_file ->
          DeployExHelpers.run_command_with_input(
            "ansible-playbook  #{setup_file} #{ansible_args}", 
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

