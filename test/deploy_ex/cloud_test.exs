defmodule DeployEx.CloudTest do
  use ExUnit.Case, async: true

  alias DeployEx.Cloud

  describe "capability/2 — default provider" do
    test "resolves AWS capabilities through the descriptor" do
      assert Cloud.capability(:machine) === {:ok, DeployEx.AwsMachine}
      assert Cloud.capability(:infrastructure) === {:ok, DeployEx.AwsInfrastructure}
      assert Cloud.capability(:security) === {:ok, DeployEx.AwsSecurityGroup}
    end

    test "an unfilled AWS slot returns :not_implemented rather than nil" do
      assert {:error, %ErrorMessage{code: :not_implemented}} = Cloud.capability(:object_store)
    end
  end

  describe "capability/2 — explicit provider" do
    test "an OCI capability is honestly not implemented" do
      assert {:error, %ErrorMessage{code: :not_implemented}} =
               Cloud.capability(:machine, provider: :oci)
    end

    test "an unknown provider errors instead of raising KeyError" do
      assert {:error, %ErrorMessage{code: :not_implemented}} =
               Cloud.capability(:machine, provider: :gcp)
    end
  end

  describe "capability/2 — module injection seam (the put_env-free test seam)" do
    test "accepts a descriptor MODULE and resolves through it" do
      assert Cloud.capability(:machine, provider: DeployEx.Cloud.Providers.Aws) ===
               {:ok, DeployEx.AwsMachine}
    end

    test "a module descriptor lacking the capability reports :not_implemented" do
      assert {:error, %ErrorMessage{code: :not_implemented}} =
               Cloud.capability(:machine, provider: DeployEx.Cloud.Providers.Oci)
    end

    test "a module that is not a descriptor errors instead of raising" do
      assert {:error, %ErrorMessage{}} = Cloud.capability(:machine, provider: Enum)
    end
  end

  describe "validate_config/2 — pure arity, the seam that makes the permissive pin testable" do
    test ":aws accepts today's full flat env plus an arbitrary unknown key" do
      env = Application.get_all_env(:deploy_ex) ++ [totally_unknown_key_xyz: %{a: 1}]

      assert Cloud.validate_config(:aws, env) === :ok
    end

    test ":aws accepts legitimately nil values" do
      env = [aws_iam_instance_profile: nil, aws_security_group_id: nil, llm_provider: nil]

      assert Cloud.validate_config(:aws, env) === :ok
    end

    test ":aws accepts an empty env" do
      assert Cloud.validate_config(:aws, []) === :ok
    end

    test ":oci rejects a typo'd key with an ErrorMessage" do
      assert {:error, %ErrorMessage{}} = Cloud.validate_config(:oci, regionn: "typo")
    end

    test ":oci accepts a valid key" do
      assert Cloud.validate_config(:oci, region: "us-phoenix-1") === :ok
    end

    test "an unknown provider does not raise" do
      assert {:error, %ErrorMessage{}} = Cloud.validate_config(:gcp, [])
    end
  end

  describe "validate_config/1 — convenience arity reading the real source" do
    test "returns :ok under the default :aws provider" do
      assert Cloud.validate_config() === :ok
    end

    test "an absent provider namespace is [] and not an error" do
      assert Cloud.validate_config(provider: :oci) === :ok
    end
  end

  describe "dispatcher purity (plan section 3.1 executable pin)" do
    test "cloud.ex references no capability or behaviour module literals" do
      offenders =
        "lib/deploy_ex/cloud.ex"
        |> File.read!()
        |> then(&Regex.scan(~r/DeployEx\.[A-Za-z0-9_.]+/, &1))
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.reject(fn reference ->
          reference in ["DeployEx.Config", "DeployEx.Cloud"] or
            String.starts_with?(reference, "DeployEx.Cloud.Providers.")
        end)

      assert offenders === [],
             "DeployEx.Cloud must hold no capability literals, found: #{inspect(offenders)}"
    end

    test "the dispatcher reads the configured provider" do
      assert File.read!("lib/deploy_ex/cloud.ex") =~ "Config.cloud_provider()"
    end
  end

  describe "%Cloud.Instance{}" do
    test "has the exact provider-neutral field set" do
      keys =
        %DeployEx.Cloud.Instance{}
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.sort()

      assert keys === [
               :id,
               :ipv6,
               :launched_at,
               :name,
               :private_ip,
               :public_ip,
               :qa_node?,
               :state,
               :tags,
               :type
             ]
    end

    test "is not JSON-encodable — section 11 mandates explicit remapping at the output site" do
      assert_raise Protocol.UndefinedError, fn ->
        Jason.encode!(%DeployEx.Cloud.Instance{})
      end
    end
  end

  describe "behaviours" do
    test "all four capability behaviours declare callbacks" do
      for module <- [
            DeployEx.Cloud.Machine,
            DeployEx.Cloud.ObjectStore,
            DeployEx.Cloud.Infrastructure,
            DeployEx.Cloud.Security
          ] do
        refute Enum.empty?(module.behaviour_info(:callbacks)),
               "#{inspect(module)} declares no callbacks"
      end
    end
  end
end
