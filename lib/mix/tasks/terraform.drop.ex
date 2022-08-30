defmodule Mix.Tasks.Terraform.Drop do
  use Mix.Task

  @shortdoc "Destroys all resources built by terraform"
  @moduledoc """
  Destroys all resources built by terraform
  """

  def run(_args) do
    System.shell("terraform destroy", cd: "./deploys/terraform", into: IO.stream())
  end
end
