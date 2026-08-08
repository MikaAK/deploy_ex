defmodule DeployEx.TerraformStateTest do
  use ExUnit.Case, async: true

  alias DeployEx.TerraformState

  @source "lib/deploy_ex/terraform_state.ex"

  @state %{
    "version" => 4,
    "outputs" => %{"databases" => %{"general" => %{"endpoint" => "db.example.com:5432"}}},
    "resources" => [
      %{
        "type" => "aws_db_instance",
        "name" => "rds_database",
        "instances" => [
          %{"attributes" => %{"password" => "hunter2", "tags" => %{"Name" => "my-database"}}}
        ]
      }
    ]
  }

  setup do
    directory = Path.join(System.tmp_dir!(), "deploy_ex_tfstate_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, directory: directory}
  end

  describe "public API" do
    test "keeps every function its call sites use" do
      Code.ensure_loaded!(TerraformState)

      for {name, arity} <- [
            read_state: 1,
            read_state: 2,
            get_output: 2,
            get_resource_attribute: 4,
            get_resource_attribute_by_tag: 5,
            get_app_display_name: 1,
            get_app_display_name: 2
          ] do
        assert function_exported?(TerraformState, name, arity),
               "TerraformState.#{name}/#{arity} disappeared"
      end
    end
  end

  describe "read_state/2 with the local backend" do
    test "decodes the state file", %{directory: directory} do
      File.write!(Path.join(directory, "terraform.tfstate"), Jason.encode!(@state))

      assert TerraformState.read_state(directory, backend: :local) === {:ok, @state}
    end

    test "returns a bare string error when the file is absent", %{directory: directory} do
      assert TerraformState.read_state(directory, backend: :local) ===
               {:error, "Terraform state file not found: #{Path.join(directory, "terraform.tfstate")}"}
    end
  end

  describe "get_output/2" do
    test "walks a dotted path into outputs" do
      assert TerraformState.get_output(@state, "databases.general.endpoint") ===
               {:ok, "db.example.com:5432"}
    end

    test "returns a bare string error for a missing key" do
      assert TerraformState.get_output(@state, "databases.general.nope") ===
               {:error, "Output key not found: databases.general.nope"}
    end
  end

  describe "get_resource_attribute/4" do
    test "pulls the attribute off the first instance" do
      assert TerraformState.get_resource_attribute(@state, "aws_db_instance", "rds_database", "password") ===
               {:ok, "hunter2"}
    end

    test "returns a bare string error when the resource is absent" do
      assert TerraformState.get_resource_attribute(@state, "aws_db_instance", "nope", "password") ===
               {:error, "Resource not found"}
    end

    test "returns a bare string error when the attribute is absent" do
      assert TerraformState.get_resource_attribute(@state, "aws_db_instance", "rds_database", "nope") ===
               {:error, "Attribute not found: nope"}
    end
  end

  describe "get_resource_attribute_by_tag/5" do
    test "matches the resource on a tag value" do
      assert TerraformState.get_resource_attribute_by_tag(
               @state,
               "aws_db_instance",
               "Name",
               "my-database",
               "password"
             ) === {:ok, "hunter2"}
    end

    test "returns a bare string error when no tag matches" do
      assert TerraformState.get_resource_attribute_by_tag(
               @state,
               "aws_db_instance",
               "Name",
               "other-database",
               "password"
             ) === {:error, "Resource not found"}
    end
  end

  describe "object-store delegation" do
    test "holds no ExAws calls of its own" do
      refute File.read!(@source) =~ "ExAws.",
             "terraform_state.ex must route its S3 read through S3ObjectStore"
    end

    test "routes through S3ObjectStore" do
      assert File.read!(@source) =~ "S3ObjectStore",
             "terraform_state.ex must call the provider-neutral object store"
    end

    test "reads one fixed key, so no listing can silently truncate" do
      refute File.read!(@source) =~ "list_objects",
             "a listing here would need pagination; terraform_state.ex must not grow one"
    end
  end

  describe "s3 error mapping" do
    test "keeps the three bare-string messages its callers surface" do
      source = File.read!(@source)

      assert source =~ "Terraform state not found in S3: s3://"
      assert source =~ "Access denied to S3 bucket: "
      assert source =~ "Failed to read Terraform state from S3: "
    end

    test "discriminates on the ErrorMessage codes S3ObjectStore produces" do
      source = File.read!(@source)

      assert source =~ ":not_found", "a missing object must still map to the not-found message"
      assert source =~ ":forbidden", "a denied bucket must still map to the access-denied message"
    end

    test "S3ObjectStore really produces those codes" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               DeployEx.Cloud.S3ObjectStore.classify_error(404, "missing", %{container: "b"})

      assert {:error, %ErrorMessage{code: :forbidden}} =
               DeployEx.Cloud.S3ObjectStore.classify_error(403, "denied", %{container: "b"})
    end
  end
end
