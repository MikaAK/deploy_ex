defmodule Mix.Tasks.DeployEx.Test do
  use Mix.Task

  alias DeployEx.{ReleaseUploader, Config}

  @default_aws_region Config.aws_region()
  @default_aws_release_bucket Config.aws_release_bucket()

  @shortdoc "Runs mix.release for apps that have changed"
  @moduledoc """
  This command checks AWS S3 for the current releases and checks
  if there are any changes in git between the current branch and
  current release. If there are changes in direct app code,
  inner umbrella dependency code changes or dep changes in the mix.lock
  that are connected to your app, the release will run, otherwise it will
  ignore it

  This command also correctly detects phoenix applications, and if found will
  run `mix assets.deploy` in those apps

  ## Options

  - `force` - Force overwrite (alias: `f`)
  - `quiet` - Force overwrite (alias: `q`)
  - `only` - Only build release apps
  - `except` - Build release for apps except
  - `recompile` - Force recompile (alias: `r`)
  - `aws-region` - Region for aws (default: `#{@default_aws_region}`)
  - `aws-bucket` - Region for aws (default: `#{@default_aws_release_bucket}`)
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)

    opts = args
      |> parse_args
      |> Keyword.put_new(:aws_release_bucket, @default_aws_release_bucket)
      |> Keyword.put_new(:aws_region, @default_aws_region)

    opts = opts
      |> Keyword.put(:only, Keyword.get_values(opts, :only))
      |> Keyword.put(:except, Keyword.get_values(opts, :except))


    raise "TESTING ONLY"
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, r: :recompile],
      switches: [
        force: :boolean,
        quiet: :boolean,
        recompile: :boolean,
        aws_region: :string,
        aws_release_bucket: :string,
        only: :keep,
        except: :keep,
        all: :boolean
      ]
    )

    opts
  end

end
