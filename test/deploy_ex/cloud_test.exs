defmodule DeployEx.CloudTest do
  use ExUnit.Case, async: true

  alias DeployEx.Cloud

  describe "capability/2 — default provider" do
    test "resolves AWS capabilities through the descriptor" do
      assert Cloud.capability(:machine) === {:ok, DeployEx.AwsMachine}
      assert Cloud.capability(:infrastructure) === {:ok, DeployEx.AwsInfrastructure}
      assert Cloud.capability(:security) === {:ok, DeployEx.AwsSecurityGroup}
    end

    test "object_store resolves now that P0.2 filled the slot" do
      assert Cloud.capability(:object_store) === {:ok, DeployEx.Cloud.S3ObjectStore}
    end

    test "a capability AWS does not implement returns :not_implemented rather than nil" do
      assert {:error, %ErrorMessage{code: :not_implemented}} = Cloud.capability(:autoscaling)
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

    test "a non-atom provider errors instead of raising FunctionClauseError" do
      assert {:error, %ErrorMessage{}} = Cloud.capability(:machine, provider: "aws")
      assert {:error, %ErrorMessage{}} = Cloud.capability(:machine, provider: 42)
    end
  end

  describe "inventory/1" do
    test "resolves AWS's dynamic plugin descriptor" do
      assert Cloud.inventory(:aws) ===
               {:ok, %{strategy: :aws_ec2_plugin, template: "ansible/aws_ec2.yaml.eex", filename: "aws_ec2.yaml"}}
    end

    test "resolves OCI's static generator descriptor" do
      assert Cloud.inventory(:oci) ===
               {:ok,
                %{strategy: :static_oci_cli, template: "ansible/providers/oci/oci.yaml.eex", filename: "oci.yaml"}}
    end

    test "an unknown provider errors instead of raising" do
      assert {:error, %ErrorMessage{code: :not_implemented}} = Cloud.inventory(:gcp)
    end

    test "accepts a descriptor module directly, same seam as capability/2" do
      assert Cloud.inventory(DeployEx.Cloud.Providers.Aws) ===
               {:ok, %{strategy: :aws_ec2_plugin, template: "ansible/aws_ec2.yaml.eex", filename: "aws_ec2.yaml"}}
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

    test "accepts a bare provider atom, which reads naturally and must not crash" do
      assert Cloud.validate_config(:oci) === :ok
      assert Cloud.validate_config(:aws) === :ok
    end

    test "a non-keyword config errors instead of raising" do
      assert {:error, %ErrorMessage{}} = Cloud.validate_config(:oci, %{region: "us-phoenix-1"})
    end

    test "a non-atom provider errors instead of raising" do
      assert {:error, %ErrorMessage{}} = Cloud.validate_config("aws", [])
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
          # DeployEx.Cloud.Provider is the descriptor BEHAVIOUR, not a capability
          # implementation — naming it in a typespec is correct and is the point of having it.
          # Rejecting it forced a caller to weaken a spec to bare map(), which is this test
          # degrading the code rather than guarding it.
          reference in ["DeployEx.Config", "DeployEx.Cloud"] or
            String.starts_with?(reference, "DeployEx.Cloud.Provider") or
            String.starts_with?(reference, "DeployEx.Cloud.Providers.")
        end)

      assert offenders === [],
             "DeployEx.Cloud must hold no capability literals, found: #{inspect(offenders)}"
    end

    test "provider resolution falls back to the configured provider" do
      assert Cloud.active_provider([]) === DeployEx.Config.cloud_provider()
    end

    test "an explicit provider opt wins over the configured one" do
      assert Cloud.active_provider(provider: :oci) === :oci
    end

    test "every dispatch path resolves the provider through active_provider/1" do
      source = File.read!("lib/deploy_ex/cloud.ex")

      assert function_body(source, "capability") =~ "active_provider(",
             "capability/2 must resolve the provider through active_provider/1; resolving it " <>
               "inline lets a hardcoded provider ship while every other test stays green"

      assert source =~ ~r/def validate_config\(opts\) when is_list\(opts\) do\n\s+provider = active_provider\(opts\)/,
             "validate_config/1 must resolve the provider through active_provider/1"

      assert function_body(source, "active_provider") =~ "Config.cloud_provider()",
             "active_provider/1 is the single place the configured provider is read"
    end
  end

  describe "ssh_user/1 — LT-OCI S1 accessor" do
    test "resolves the AWS descriptor's admin user under the default provider" do
      assert Cloud.ssh_user([]) === "admin"
    end

    test "resolves the OCI descriptor's ubuntu user under an explicit override" do
      assert Cloud.ssh_user(provider: :oci) === "ubuntu"
    end

    test "falls back to admin for an unregistered provider instead of raising" do
      assert Cloud.ssh_user(provider: :gcp) === "admin"
    end
  end

  describe "resource_group/1 — LT-OCI S1/review-fix accessor" do
    test "resolves through DeployEx.Config.aws_resource_group/0 under the default provider" do
      assert Cloud.resource_group([]) === {:ok, DeployEx.Config.aws_resource_group()}
    end

    test "resolves AWS's flat config when given the descriptor MODULE instead of the atom :aws" do
      assert Cloud.resource_group(provider: DeployEx.Cloud.Providers.Aws) ===
               {:ok, DeployEx.Config.aws_resource_group()}
    end

    test "reads the real, seeded :oci config namespace under an explicit atom override" do
      assert Cloud.resource_group(provider: :oci) === {:ok, "OCI Test Backend"}
    end

    test "reads the :oci namespace when given the descriptor MODULE instead of the atom :oci" do
      assert Cloud.resource_group(provider: DeployEx.Cloud.Providers.Oci) === {:ok, "OCI Test Backend"}
    end

    test "an unregistered provider errors instead of raising" do
      assert {:error, %ErrorMessage{code: :not_implemented}} = Cloud.resource_group(provider: :gcp)
    end
  end

  describe "release_bucket/1 — LT-OCI S1/review-fix accessor" do
    test "resolves through DeployEx.Config.aws_release_bucket/0 under the default provider" do
      assert Cloud.release_bucket([]) === {:ok, DeployEx.Config.aws_release_bucket()}
    end

    test "resolves AWS's flat config when given the descriptor MODULE instead of the atom :aws" do
      assert Cloud.release_bucket(provider: DeployEx.Cloud.Providers.Aws) ===
               {:ok, DeployEx.Config.aws_release_bucket()}
    end

    test "a real, registered provider with the key genuinely unset errors loudly rather than nil" do
      assert {:error, %ErrorMessage{code: :bad_request, message: message}} =
               Cloud.release_bucket(provider: :oci)

      assert message =~ "release_bucket"
      assert message =~ "oci"
    end

    test "an unregistered provider errors instead of raising" do
      assert {:error, %ErrorMessage{code: :not_implemented}} = Cloud.release_bucket(provider: :gcp)
    end
  end

  describe "parse_provider/1 — safe CLI --provider flag parsing (LT-OCI review-fix)" do
    test "parses a known provider string into its atom" do
      assert Cloud.parse_provider("aws") === {:ok, :aws}
      assert Cloud.parse_provider("oci") === {:ok, :oci}
    end

    test "nil (flag absent) resolves to nil, not an error" do
      assert Cloud.parse_provider(nil) === {:ok, nil}
    end

    test "an unknown provider string errors instead of silently being swallowed" do
      assert {:error, %ErrorMessage{code: :bad_request, message: message}} = Cloud.parse_provider("gcp")

      assert message =~ "gcp"
      assert message =~ "aws"
      assert message =~ "oci"
    end

    test "a fresh, never-before-seen string still errors cleanly rather than raising" do
      random = "totally-unrecognized-#{System.unique_integer([:positive])}"

      assert {:error, %ErrorMessage{code: :bad_request}} = Cloud.parse_provider(random)
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
    test "Machine declares its exact callback set" do
      assert callback_set(DeployEx.Cloud.Machine) === [
               await_running: 2,
               delete_tags: 3,
               describe_instance: 2,
               fetch_tags: 2,
               find_app_instances: 3,
               instance_address: 1,
               list_instances: 2,
               put_tags: 3,
               run_instance: 2,
               start_instance: 2,
               stop_instance: 2,
               terminate_instance: 2
             ]
    end

    test "the Phase-5 callbacks are optional so AwsMachine conforms without them" do
      assert DeployEx.Cloud.Machine.behaviour_info(:optional_callbacks) |> Enum.sort() === [
               await_running: 2,
               delete_tags: 3,
               put_tags: 3,
               run_instance: 2,
               terminate_instance: 2
             ]
    end

    test "ObjectStore declares its exact callback set" do
      assert callback_set(DeployEx.Cloud.ObjectStore) === [
               create_container: 2,
               delete_container: 2,
               delete_object: 3,
               get_object: 3,
               list_containers: 1,
               list_objects: 2,
               put_object: 4,
               put_object_tags: 4,
               upload_file: 4
             ]
    end

    test "Infrastructure declares its exact callback set" do
      assert callback_set(DeployEx.Cloud.Infrastructure) === [
               find_image: 1,
               find_instance_identity: 1,
               find_key_pair: 2,
               find_network: 1,
               find_subnet: 1,
               gather_infrastructure: 1
             ]
    end

    test "gather_infrastructure/1 is optional so a provider conforms without it (LT-OCI review-fix)" do
      assert DeployEx.Cloud.Infrastructure.behaviour_info(:optional_callbacks) === [gather_infrastructure: 1]
    end

    test "Security declares its exact callback set" do
      assert callback_set(DeployEx.Cloud.Security) === [
               authorize_ingress: 3,
               find_group: 1,
               revoke_ingress: 3
             ]
    end

    test "the Provider descriptor declares its exact callback set" do
      assert callback_set(DeployEx.Cloud.Provider) === [
               backend_template: 0,
               capabilities: 0,
               cli_adapter: 0,
               completion_marker: 0,
               config_schema: 0,
               default_ssh_user: 0,
               inventory: 0
             ]
    end
  end

  defp function_body(source, name) do
    [_before, rest] = String.split(source, ~r/\n  def #{name}\(/, parts: 2)

    rest
    |> String.split(~r/\n  (?:@doc|@spec|def|defp) /, parts: 2)
    |> List.first()
  end

  defp callback_set(module) do
    module.behaviour_info(:callbacks)
    |> Enum.sort()
    |> Enum.map(fn {name, arity} -> {name, arity} end)
  end
end
