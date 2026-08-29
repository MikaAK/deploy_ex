defmodule DeployEx.Cloud.OciObjectStore do
  @moduledoc """
  OCI Object Storage implementation of `DeployEx.Cloud.ObjectStore`, driven by the `oci` CLI.

  Not built on OCI's S3-compatible endpoint. That endpoint needs long-lived Customer Secret
  Keys and does NOT accept instance principals, so a node could not read its own release
  bucket without a credential on disk. The native API accepts instance principals, which is
  the OCI analogue of an EC2 instance profile — the same shape the AWS path already relies on.

  Every list call passes `--all`. That flag is OCI's equivalent of following S3 pagination to
  completion, and `DeployEx.ReleaseUploader` reads release history from these listings: a
  listing that silently stops after one page reports a fraction of the releases as if it were
  all of them, with no error.
  """

  @behaviour DeployEx.Cloud.ObjectStore

  alias DeployEx.Cloud.OciCli

  @impl DeployEx.Cloud.ObjectStore
  def get_object(container, key, opts \\ []) do
    path = temp_path("get")

    with {:ok, _output} <-
           OciCli.run("os object get#{namespace_flag(opts)} --bucket-name #{quote_arg(container)} --name #{quote_arg(key)} --file #{quote_arg(path)}", opts) do
      read_and_discard(path)
    end
  end

  @impl DeployEx.Cloud.ObjectStore
  def put_object(container, key, body, opts \\ []) do
    path = temp_path("put")

    with :ok <- File.write(path, body) do
      result = upload_file(container, key, path, opts)

      File.rm(path)

      result
    end
  end

  @impl DeployEx.Cloud.ObjectStore
  def upload_file(container, key, path, opts \\ []) do
    with {:ok, _output} <-
           OciCli.run("os object put#{namespace_flag(opts)} --bucket-name #{quote_arg(container)} --name #{quote_arg(key)} --file #{quote_arg(path)} --force", opts) do
      :ok
    end
  end

  @impl DeployEx.Cloud.ObjectStore
  def delete_object(container, key, opts \\ []) do
    with {:ok, _output} <-
           OciCli.run("os object delete#{namespace_flag(opts)} --bucket-name #{quote_arg(container)} --name #{quote_arg(key)} --force", opts) do
      :ok
    end
  end

  @impl DeployEx.Cloud.ObjectStore
  def list_objects(container, opts \\ []) do
    command = "os object list#{namespace_flag(opts)} --bucket-name #{quote_arg(container)} --all#{prefix_flag(opts)}"

    with {:ok, payload} <- OciCli.run_json(command, opts) do
      {:ok, payload |> Map.get("data", []) |> Enum.map(&(&1["name"]))}
    end
  end

  @impl DeployEx.Cloud.ObjectStore
  def create_container(container, opts \\ []) do
    with {:ok, compartment_id} <- require_compartment_id(opts),
         {:ok, _output} <-
           OciCli.run("os bucket create#{namespace_flag(opts)} --compartment-id #{compartment_id} --name #{quote_arg(container)}", opts) do
      :ok
    end
  end

  @impl DeployEx.Cloud.ObjectStore
  def delete_container(container, opts \\ []) do
    with {:ok, _output} <- OciCli.run("os bucket delete#{namespace_flag(opts)} --bucket-name #{quote_arg(container)} --force", opts) do
      :ok
    end
  end

  @doc """
  Lists buckets in the compartment.

  Returns maps carrying `:name`, matching what `DeployEx.Cloud.S3ObjectStore` returns and what
  `terraform.create_state_bucket`/`drop_state_bucket` read, rather than the bare strings the
  behaviour's typespec names. The typespec is the odd one out here — changing it is a separate
  correction from making OCI work.
  """
  @impl DeployEx.Cloud.ObjectStore
  def list_containers(opts \\ []) do
    with {:ok, compartment_id} <- require_compartment_id(opts),
         {:ok, payload} <- OciCli.run_json("os bucket list#{namespace_flag(opts)} --compartment-id #{compartment_id} --all", opts) do
      {:ok, payload |> Map.get("data", []) |> Enum.map(&bucket_summary/1)}
    end
  end

  @doc """
  Object tagging, which OCI Object Storage does not offer.

  Its nearest equivalent is user metadata, settable only at put time — there is no
  `oci os object update-metadata`, so tagging an already-uploaded object would mean
  re-uploading it. Implemented as an honest error rather than left out: the sole caller is
  `DeployEx.ReleaseUploader`'s `qa_release: true` path, and an unimplemented optional callback
  would reach it as an UndefinedFunctionError instead of a message naming the limitation.
  """
  @impl DeployEx.Cloud.ObjectStore
  def put_object_tags(container, key, _tags, _opts \\ []) do
    {:error,
     ErrorMessage.not_implemented(
       "oci object storage has no object tagging; tag data must be encoded in the key prefix",
       %{container: container, key: key}
     )}
  end

  defp bucket_summary(bucket) do
    %{name: bucket["name"], creation_date: bucket["time-created"]}
  end

  defp require_compartment_id(opts) do
    case OciCli.setting(opts, :compartment_id) do
      nil ->
        {:error,
         ErrorMessage.bad_request(
           "oci compartment_id is required for bucket operations " <>
             "(config :deploy_ex, :oci, compartment_id: \"...\")"
         )}

      compartment_id ->
        {:ok, compartment_id}
    end
  end

  # Passed explicitly rather than left to the CLI's auto-resolution. Resolving the namespace
  # internally requires a tenancy read, which a correctly-scoped CI credential does NOT have —
  # MEASURED: a user holding only object permissions fails every `oci os` call with "Unable to
  # retrieve namespace internally. Please provide the namespace using the option
  # --['namespace-name']". Auto-resolution only appears to work when the credential is
  # over-privileged, so relying on it quietly punishes least privilege.
  defp namespace_flag(opts) do
    case OciCli.setting(opts, :namespace) do
      namespace when is_binary(namespace) and namespace !== "" -> " --namespace #{quote_arg(namespace)}"
      _absent -> ""
    end
  end

  defp prefix_flag(opts) do
    case opts[:prefix] do
      prefix when is_binary(prefix) and prefix !== "" -> " --prefix #{quote_arg(prefix)}"
      _absent -> ""
    end
  end

  defp read_and_discard(path) do
    result = File.read(path)

    File.rm(path)

    case result do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, ErrorMessage.internal_server_error("could not read downloaded object", %{reason: reason})}
    end
  end

  defp temp_path(kind) do
    Path.join(System.tmp_dir!(), "deploy_ex_oci_#{kind}_#{System.unique_integer([:positive])}")
  end

  defp quote_arg(value), do: OciCli.quote_arg(value)
end
