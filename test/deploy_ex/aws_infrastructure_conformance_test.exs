defmodule DeployEx.AwsInfrastructureConformanceTest do
  use ExUnit.Case, async: true

  alias DeployEx.AwsInfrastructure

  test "declares the Cloud.Infrastructure behaviour" do
    behaviours = AwsInfrastructure.module_info(:attributes)[:behaviour] || []

    assert DeployEx.Cloud.Infrastructure in behaviours
  end

  test "exports every callback the behaviour declares" do
    Code.ensure_loaded!(AwsInfrastructure)

    missing =
      DeployEx.Cloud.Infrastructure.behaviour_info(:callbacks)
      |> Enum.reject(fn {name, arity} -> function_exported?(AwsInfrastructure, name, arity) end)

    assert missing === [], "AwsInfrastructure is missing callbacks: #{inspect(missing)}"
  end

  test "the AWS descriptor resolves infrastructure to this module" do
    assert DeployEx.Cloud.capability(:infrastructure) === {:ok, AwsInfrastructure}
  end

  test "keeps the public functions its existing call sites use" do
    Code.ensure_loaded!(AwsInfrastructure)

    for {name, arity} <- [
          find_subnet_ids: 1,
          find_key_pair_name: 1,
          find_iam_instance_profile: 1,
          find_vpc_id: 1,
          find_latest_ami: 1,
          gather_infrastructure: 1,
          find_primary_subnet_id: 2
        ] do
      assert function_exported?(AwsInfrastructure, name, arity),
             "AwsInfrastructure.#{name}/#{arity} disappeared"
    end
  end
end
