defmodule DeployEx.PrivManifest do
  @manifest_filename ".deploy_ex_manifest.exs"

  def read(deploy_folder) do
    manifest_path = Path.join(deploy_folder, @manifest_filename)

    if File.exists?(manifest_path) do
      {manifest, _bindings} = Code.eval_file(manifest_path)
      {:ok, manifest}
    else
      {:error, ErrorMessage.not_found("manifest not found at #{manifest_path}, run mix deploy_ex.export_priv first")}
    end
  end

  def write(deploy_folder, manifest) do
    manifest_path = Path.join(deploy_folder, @manifest_filename)

    content =
      manifest
      |> inspect(pretty: true)
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    File.write!(manifest_path, content)
    :ok
  rescue
    e ->
      {:error, ErrorMessage.internal_server_error("#{__MODULE__}: failed to write manifest, error: #{inspect(e)}")}
  end

  def base_hash(manifest, relative_path) do
    files = Keyword.get(manifest, :files, [])

    case Enum.find(files, fn {path, _opts} -> path === relative_path end) do
      {_path, file_opts} ->
        {:ok, Keyword.fetch!(file_opts, :base_hash)}

      nil ->
        {:error, ErrorMessage.not_found("#{__MODULE__}: #{relative_path} not found in manifest")}
    end
  end

  def put_file(manifest, relative_path, hash) do
    files = Keyword.get(manifest, :files, [])
    updated_at = DateTime.utc_now() |> DateTime.to_iso8601()
    new_entry = {relative_path, [base_hash: hash, updated_at: updated_at]}

    updated_files =
      case Enum.find_index(files, fn {path, _} -> path === relative_path end) do
        nil -> files ++ [new_entry]
        index -> List.replace_at(files, index, new_entry)
      end

    Keyword.put(manifest, :files, updated_files)
  end

  def hash_content(content) do
    hash =
      :crypto.hash(:sha256, content)
      |> Base.encode16(case: :lower)

    "sha256:#{hash}"
  end
end
