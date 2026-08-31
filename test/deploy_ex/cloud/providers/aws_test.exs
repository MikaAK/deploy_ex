defmodule DeployEx.Cloud.Providers.AwsTest do
  use ExUnit.Case, async: true

  alias DeployEx.Cloud.Providers.Aws

  test "declares the descriptor behaviour" do
    assert DeployEx.Cloud.Provider in (Aws.module_info(:attributes)[:behaviour] || [])
  end

  test "capabilities point at the existing leaf modules" do
    assert Aws.capabilities() === %{
             machine: DeployEx.AwsMachine,
             object_store: DeployEx.Cloud.S3ObjectStore,
             infrastructure: DeployEx.AwsInfrastructure,
             security: DeployEx.AwsSecurityGroup
           }
  end

  test "every capability module actually exists" do
    for {_name, module} <- Aws.capabilities() do
      assert Code.ensure_loaded?(module), "#{inspect(module)} is a dangling reference"
    end
  end

  test "backend_template/0 is :s3" do
    assert Aws.backend_template() === :s3
  end

  test "completion_marker/0 is :ci_tag" do
    assert Aws.completion_marker() === :ci_tag
  end

  test "inventory/0 owns both the template path and the rendered filename" do
    assert Aws.inventory() === %{
             strategy: :aws_ec2_plugin,
             template: "ansible/aws_ec2.yaml.eex",
             filename: "aws_ec2.yaml"
           }
  end

  test "inventory template path resolves to a real file in priv" do
    priv_path = :deploy_ex |> :code.priv_dir() |> Path.join(Aws.inventory().template)

    assert File.exists?(priv_path), "descriptor points at a nonexistent template: #{priv_path}"
  end

  test "default_ssh_user/0 preserves today's ssh.ex hardcoded value" do
    assert Aws.default_ssh_user() === "admin"
  end

  test "cli_adapter/0 is nil — AWS goes through ExAws, not a CLI" do
    assert is_nil(Aws.cli_adapter())
  end

  describe "config_schema/0" do
    test "accepts today's full flat env plus an arbitrary unknown key" do
      env = Application.get_all_env(:deploy_ex) ++ [some_unknown_key_xyz: %{nested: 1}]

      assert {:ok, _} = NimbleOptions.validate(env, Aws.config_schema())
    end

    test "accepts legitimately nil values" do
      env = [aws_iam_instance_profile: nil, aws_security_group_id: nil, llm_provider: nil]

      assert {:ok, _} = NimbleOptions.validate(env, Aws.config_schema())
    end

    test "accepts an entirely empty env" do
      assert {:ok, _} = NimbleOptions.validate([], Aws.config_schema())
    end
  end
end
