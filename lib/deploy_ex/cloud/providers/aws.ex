defmodule DeployEx.Cloud.Providers.Aws do
  @moduledoc """
  Descriptor for AWS, the default provider.

  `object_store` is intentionally absent from `capabilities/0` until `S3ObjectStore`
  exists. Pointing the slot at a module that has not been written would be a dangling
  reference that only fails at call time; omitting it yields an honest `:not_implemented`.
  """

  @behaviour DeployEx.Cloud.Provider

  @config_schema [*: [type: :any]]

  @impl DeployEx.Cloud.Provider
  def capabilities do
    %{
      machine: DeployEx.AwsMachine,
      object_store: DeployEx.Cloud.S3ObjectStore,
      infrastructure: DeployEx.AwsInfrastructure,
      security: DeployEx.AwsSecurityGroup
    }
  end

  @impl DeployEx.Cloud.Provider
  def config_schema, do: @config_schema

  @impl DeployEx.Cloud.Provider
  def backend_template, do: :s3

  @impl DeployEx.Cloud.Provider
  def completion_marker, do: :ci_tag

  @impl DeployEx.Cloud.Provider
  def inventory do
    %{
      strategy: :aws_ec2_plugin,
      template: "ansible/aws_ec2.yaml.eex",
      filename: "aws_ec2.yaml"
    }
  end

  @impl DeployEx.Cloud.Provider
  def default_ssh_user, do: "admin"

  @impl DeployEx.Cloud.Provider
  def cli_adapter, do: nil
end
