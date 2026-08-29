defmodule DeployEx.Cloud.OciObjectStoreTest do
  use ExUnit.Case, async: true

  alias DeployEx.Cloud.OciObjectStore

  @compartment "ocid1.compartment.oc1..test"

  # Captures the command the store built and replays a canned CLI response. Process.put keeps
  # it per-test-PID, so the suite stays async without a registry or an ETS table.
  defp stub(output) do
    [
      run_fn: fn command, _cwd ->
        Process.put(:last_command, command)

        case output do
          {:error, _} = error -> error
          stdout -> {:ok, stdout}
        end
      end
    ]
  end

  defp last_command, do: Process.get(:last_command)

  defp cli_failure(output) do
    {:error,
     ErrorMessage.internal_server_error("oci exited 1", %{output: output, code: 1, command: "oci"})}
  end

  describe "list_objects/2" do
    test "reads names out of a real --all payload" do
      payload = """
      {
        "data": [
          {"name": "app/2026-a.tar.gz", "size": 9},
          {"name": "app/2026-b.tar.gz", "size": 9}
        ],
        "prefixes": []
      }
      """

      assert OciObjectStore.list_objects("bucket", stub(payload)) ===
               {:ok, ["app/2026-a.tar.gz", "app/2026-b.tar.gz"]}
    end

    test "a payload with NO data key is an empty listing, not a crash" do
      # MEASURED: `oci os object list` on a prefix matching nothing prints `{"prefixes": []}`
      # with the data key absent entirely, so Map.get/3 must supply the default.
      assert OciObjectStore.list_objects("bucket", stub(~s({"prefixes": []}))) === {:ok, []}
    end

    test "empty stdout is an empty listing, not a JSON decode error" do
      # MEASURED: the oci CLI prints NOTHING for an empty result set. Treating that as a decode
      # failure makes a first-run empty bucket indistinguishable from a broken command.
      assert OciObjectStore.list_objects("bucket", stub("")) === {:ok, []}
    end

    test "always passes --all, which is OCI's pagination-to-completion flag" do
      OciObjectStore.list_objects("bucket", stub(~s({"data": []})))

      assert last_command() =~ "--all",
             "without --all the CLI returns one page and reports a fraction of the releases " <>
               "as if it were all of them, with no error"
    end

    test "a prefix narrows the listing" do
      OciObjectStore.list_objects("bucket", stub(~s({"data": []})) ++ [prefix: "app/"])

      assert last_command() =~ "--prefix 'app/'"
    end

    test "an empty prefix adds no flag rather than an empty one" do
      OciObjectStore.list_objects("bucket", stub(~s({"data": []})) ++ [prefix: ""])

      refute last_command() =~ "--prefix"
    end
  end

  describe "namespace" do
    # Resolving the namespace internally costs a tenancy read that a least-privilege CI
    # credential does not have: it fails every call with "Unable to retrieve namespace
    # internally". Auto-resolution only works when the credential is over-privileged, so this
    # is invisible until someone does the right thing and scopes the CI user down.
    test "is passed explicitly on object calls rather than left to auto-resolution" do
      OciObjectStore.list_objects("bucket", stub(~s({"data": []})) ++ [oci_namespace: "axm8ic8kr5of"])

      assert last_command() =~ "--namespace 'axm8ic8kr5of'"
    end

    test "is passed on bucket calls too" do
      opts = stub(~s({"data": []})) ++ [oci_namespace: "axm8ic8kr5of", oci_compartment_id: @compartment]

      OciObjectStore.list_containers(opts)

      assert last_command() =~ "--namespace 'axm8ic8kr5of'"
    end

    test "is omitted when unset, so an unconfigured project still relies on auto-resolution" do
      OciObjectStore.list_objects("bucket", stub(~s({"data": []})))

      refute last_command() =~ "--namespace"
    end
  end

  describe "provider-shaped opts" do
    test "an AWS-shaped :region does NOT become the OCI region" do
      # AwsManager threads opts[:aws_region] (default us-west-2) through to whichever store is
      # active. Reading that as the OCI region sends every call to a region the tenancy is not
      # in, and the failure looks like a permissions problem rather than a wrong endpoint.
      OciObjectStore.list_objects("bucket", stub(~s({"data": []})) ++ [region: "us-west-2"])

      refute last_command() =~ "us-west-2"
    end

    test ":oci_region is the explicit override that does apply" do
      OciObjectStore.list_objects("bucket", stub(~s({"data": []})) ++ [oci_region: "ap-seoul-1"])

      assert last_command() =~ "--region 'ap-seoul-1'"
    end

    test "instance_principal auth is selectable for on-instance use" do
      OciObjectStore.list_objects("bucket", stub(~s({"data": []})) ++ [oci_auth: "instance_principal"])

      assert last_command() =~ "OCI_CLI_AUTH='instance_principal'"
    end
  end

  describe "error classification" do
    test "a 404 service error becomes :not_found" do
      output = ~s(ServiceError:\n{"status": 404, "message": "The service returned error code 404"})

      assert {:error, %ErrorMessage{code: :not_found}} =
               OciObjectStore.get_object("bucket", "nope", stub(cli_failure(output)))
    end

    test "a 409 service error becomes :conflict so an existing bucket is distinguishable" do
      output = ~s(ServiceError:\n{"status": 409, "message": "bucket already exists"})

      assert {:error, %ErrorMessage{code: :conflict}} =
               OciObjectStore.create_container("bucket", stub(cli_failure(output)) ++ [oci_compartment_id: @compartment])
    end

    test "a failure with no ServiceError body passes the original error through" do
      assert {:error, %ErrorMessage{code: :internal_server_error}} =
               OciObjectStore.delete_object("bucket", "key", stub(cli_failure("command not found: oci")))
    end
  end

  describe "bucket operations" do
    test "a missing compartment_id is a bad_request naming the config key, not a crash" do
      assert {:error, %ErrorMessage{code: :bad_request} = error} =
               OciObjectStore.list_containers(stub(~s({"data": []})))

      assert error.message =~ "compartment_id"
    end

    test "list_containers returns maps carrying :name, matching the S3 store's callers" do
      payload = ~s({"data": [{"name": "a-bucket", "time-created": "2026-08-09T00:00:00Z"}]})
      opts = stub(payload) ++ [oci_compartment_id: @compartment]

      assert OciObjectStore.list_containers(opts) ===
               {:ok, [%{name: "a-bucket", creation_date: "2026-08-09T00:00:00Z"}]}
    end
  end

  describe "put_object_tags/4" do
    test "is an honest :not_implemented rather than an UndefinedFunctionError" do
      # OCI has no object tagging and no update-metadata subcommand. Leaving the optional
      # callback out would surface at the qa_release call site as an UndefinedFunctionError.
      assert {:error, %ErrorMessage{code: :not_implemented}} =
               OciObjectStore.put_object_tags("bucket", "key", %{"qa" => "true"})
    end
  end

  describe "shell argument quoting" do
    test "object keys are quoted so a key with a space cannot split into two arguments" do
      OciObjectStore.list_objects("my bucket", stub(~s({"data": []})))

      assert last_command() =~ "--bucket-name 'my bucket'"
    end
  end
end
