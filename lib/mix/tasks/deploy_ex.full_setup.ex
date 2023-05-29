defmodule Mix.Tasks.DeployEx.FullSetup do
  use Mix.Task

  @shortdoc "Runs all the commands to setup terraform and ansible"
  @moduledoc """
  Runs all the commands to setup terraform and ansible.
  It also initializes AWS and pings the nodes to confirm they work. Finally
  it will attempt to run `mix ansible.setup` as well to setup
  the nodes post successful ping

  ## Options
  - `auto-approve` - Skip asking for verification with terraform (alias: `y`)
  - `skip-deploy` - Skips deploy commands after pinging & setting up nodes with ansible (alias: `k`)
  - `auto_pull_aws` - Automatically pull aws key from host machine and loads it into remote machines (alias: `a`)
  """

  alias Mix.Tasks.{Ansible, Terraform}

  @pre_setup_commands [
    Terraform.Build,
    Terraform.Apply,
    Ansible.Build
  ]

  @post_setup_comands [
    Mix.Tasks.DeployEx.Upload,
    Ansible.Deploy
  ]

  @time_between_pre_post :timer.seconds(10)

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      case run_commands(@pre_setup_commands, args) do
        nil ->
          opts = parse_args(args)

          if !opts[:skip_setup] do
            Mix.shell().info([
              :green, "* sleeping for ", :reset,
              @time_between_pre_post |> div(1000) |> to_string,
              :green, " seconds to allow setup"
            ])

            Process.sleep(@time_between_pre_post)
          end

          ping_and_run_post_setup(args)

        e -> Mix.raise(e)
      end
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [k: :skip_deploy, p: :skip_setup],
      switches: [
        skip_setup: :boolean,
        skip_deploy: :boolean
      ]
    )

    opts
  end

  defp run_commands(commands, args) do
    Enum.find_value(commands, fn cmd_mod ->
      case cmd_mod.run(args) do
        :ok -> false
        {:error, _} = e -> e
      end
    end)
  end

  defp ping_and_run_post_setup(args) do
    opts = parse_args(args)

    with :ok <- Ansible.Ping.run(args),
         :ok <- run_setup(opts, args) do

      if !opts[:skip_deploy] do
        Mix.shell().info([
          :green, "* running post setup"
        ])

        run_commands(@post_setup_comands, args)
      end
    end
  end

  defp run_setup(opts, args) do
    if !opts[:skip_setup] do
      Mix.shell().info([
        :green, "* running instance setup"
      ])

      Ansible.Setup.run(args)
    end
  end
end


