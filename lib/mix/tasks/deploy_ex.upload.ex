defmodule Mix.Tasks.DeployEx.Upload do
  use Mix.Task

  @default_aws_region DeployEx.Config.aws_release_region()
  @default_aws_bucket DeployEx.Config.aws_release_bucket()

  @shortdoc "Uploads your release folder to Amazon S3"
  @moduledoc """
  Uploads your release to AWS S3 into a bucket

  This is organised by release and will store the last 10 releases
  by date/time, as well as marks them with the Github Sha. By doing this
  you can run `mix ansible.rollback <sha>` or `mix ansible.rollback` to rollback
  either to a specific sha, or to the last previous release

  After uploading your release, you can deploy it to all servers by calling
  `mix ansible.build`, before building make sure nodes are setup using `mix ansible.setup_nodes`

  ## Options

  - `aws-region` - Region for aws (default: `#{@default_aws_region}`)
  - `bucket` - Region for aws (default: `#{@default_aws_bucket}`)
  """

  def run(args) do

  end
end
