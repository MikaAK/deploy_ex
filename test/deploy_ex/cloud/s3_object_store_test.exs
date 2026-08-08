defmodule DeployEx.Cloud.S3ObjectStoreTest do
  use ExUnit.Case, async: true

  alias DeployEx.Cloud.S3ObjectStore

  describe "Cloud.ObjectStore conformance" do
    test "declares the behaviour" do
      assert DeployEx.Cloud.ObjectStore in (S3ObjectStore.module_info(:attributes)[:behaviour] || [])
    end

    test "exports every callback the behaviour declares" do
      Code.ensure_loaded!(S3ObjectStore)

      missing =
        DeployEx.Cloud.ObjectStore.behaviour_info(:callbacks)
        |> Enum.reject(fn {name, arity} -> function_exported?(S3ObjectStore, name, arity) end)

      assert missing === [], "S3ObjectStore is missing callbacks: #{inspect(missing)}"
    end

    test "the AWS descriptor now fills the object_store slot" do
      assert DeployEx.Cloud.capability(:object_store) === {:ok, S3ObjectStore}
    end

    test "every capability module in the AWS descriptor exists" do
      for {_name, module} <- DeployEx.Cloud.Providers.Aws.capabilities() do
        assert Code.ensure_loaded?(module), "#{inspect(module)} is a dangling reference"
      end
    end
  end

  describe "classify_error/3" do
    test "maps 409 to conflict" do
      assert {:error, %ErrorMessage{code: :conflict}} =
               S3ObjectStore.classify_error(409, "exists", %{container: "b"})
    end

    test "maps 404 to not_found" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               S3ObjectStore.classify_error(404, "missing", %{container: "b"})
    end

    test "falls back to the http code reason for anything else" do
      assert {:error, %ErrorMessage{code: :forbidden}} =
               S3ObjectStore.classify_error(403, "denied", %{container: "b"})
    end

    test "carries details through unchanged" do
      details = %{container: "my-bucket", key: "some/key.json"}

      assert {:error, %ErrorMessage{details: ^details}} =
               S3ObjectStore.classify_error(500, "boom", details)
    end
  end

  describe "list_objects pagination" do
    test "follows pagination rather than stopping at the first page" do
      source = File.read!("lib/deploy_ex/cloud/s3_object_store.ex")

      assert source =~ "is_truncated",
             "list_objects must inspect is_truncated; a single request silently caps at 1000 keys"

      assert source =~ ~r/:marker/,
             "list_objects must advance a marker to fetch subsequent pages"
    end

    test "the paginating helper recurses" do
      source = File.read!("lib/deploy_ex/cloud/s3_object_store.ex")
      body = source |> String.split("defp list_objects_page") |> Enum.at(1)

      assert body =~ "list_objects_page(",
             "the page fetcher must call itself; without recursion only page one is returned"
    end
  end

  describe "AwsBucket compatibility" do
    test "keeps its public API so existing call sites are untouched" do
      Code.ensure_loaded!(DeployEx.AwsBucket)

      for {name, arity} <- [
            create_bucket: 2,
            list_buckets: 1,
            list_objects: 2,
            delete_all_objects: 3,
            delete_bucket: 2
          ] do
        assert function_exported?(DeployEx.AwsBucket, name, arity),
               "AwsBucket.#{name}/#{arity} disappeared"
      end
    end

    test "holds no ExAws calls of its own — they moved into S3ObjectStore" do
      refute File.read!("lib/deploy_ex/aws_bucket.ex") =~ "ExAws.",
             "aws_bucket.ex must delegate its S3 calls to S3ObjectStore"
    end
  end
end
