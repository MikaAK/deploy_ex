defmodule Mix.Tasks.Terraform.Drop do
  use Mix.Task

  @shortdoc "Destroys all resources built by terraform"
  @moduledoc """
  Destroys all resources built by terraform
  """

  def run(_args) do
    DeployExHelpers.run_command_with_input("terraform destroy", "./deploys/terraform")
  end
end
