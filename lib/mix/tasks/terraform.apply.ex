defmodule Mix.Tasks.Terraform.Apply do
  use Mix.Task

  @shortdoc "Deploys to terraform resources using ansible"
  @moduledoc """
  Deploys to ansible
  """

  def run(_args) do
    System.shell("terraform apply", cd: "./deploys/terraform", into: IO.stream())
  end
end
