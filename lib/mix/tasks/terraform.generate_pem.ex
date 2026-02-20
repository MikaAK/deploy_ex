
defmodule Mix.Tasks.Terraform.GeneratePem do
  use Mix.Task

  @shortdoc "Extracts the PEM file from Terraform state and saves it locally"
  @moduledoc """
  Extracts the PEM file and key name from the Terraform state and saves it to a file.

  ## Options
  - `--directory` - Terraform directory path (used for local backend and output)
  - `--output-file` - Path to save the PEM file (default: <key_name>.pem)
  - `--backend` - State backend: "s3" or "local" (default: from config)
  - `--bucket` - S3 bucket for state (default: from config)
  - `--region` - AWS region (default: from config)
  """

  alias DeployEx.TerraformState

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @doc """
  Extracts the private key PEM and key name from Terraform and saves it to a file.

  ## Parameters:
    - `directory` (optional): Path to the Terraform state folder.
    - `output_file` (optional): Path to save the PEM file. Defaults to `<key_name>.pem`.

  ## Example:
  ```bash
  mix terraform.generate_pem
  mix terraform.generate_pem --directory "custom/path"
  mix terraform.generate_pem --directory "custom/path" --output-file "my-key.pem"
  ```
  """
  def run(args) do
    opts = args |> parse_args() |> Keyword.put_new(:directory, @terraform_default_path)
    state_opts = build_state_opts(opts)

    maybe_start_aws_apps(state_opts[:backend])

    with {:ok, state} <- TerraformState.read_state(opts[:directory], state_opts),
         {:ok, private_key} <- TerraformState.get_resource_attribute(state, "tls_private_key", "key_pair", "private_key_pem"),
         {:ok, key_name} <- TerraformState.get_resource_attribute(state, "aws_key_pair", "key_pair", "key_name") do

      # If no output file is provided, default to `<key_name>.pem`
      output_file = Path.join(opts[:directory], opts[:output_file] || "#{key_name}.pem")

      cond do
        not File.exists?(output_file) ->
          save_pem_file(private_key, output_file)
          Mix.shell().info([:green, "PEM file saved to: ", :reset, output_file])

        File.read!(output_file) === private_key ->
          Mix.shell().info([:green, "PEM file exists and is the same already"])

        true ->
          Mix.raise("""
          PEM file exists but is not the same.

          Please manually delete it before rerunning the command...
          """)
      end
    else
      {:error, e} ->
        IO.inspect(e, label: "Error extracting PEM from Terraform")
        Mix.raise("Failed to extract PEM key from Terraform state")
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [d: :directory, o: :output_file, b: :backend],
      switches: [
        directory: :string,
        output_file: :string,
        backend: :string,
        bucket: :string,
        region: :string
      ]
    )

    opts
  end

  defp build_state_opts(opts) do
    state_opts = []

    state_opts = if opts[:backend] do
      Keyword.put(state_opts, :backend, String.to_existing_atom(opts[:backend]))
    else
      state_opts
    end

    state_opts = if opts[:bucket], do: Keyword.put(state_opts, :bucket, opts[:bucket]), else: state_opts
    state_opts = if opts[:region], do: Keyword.put(state_opts, :region, opts[:region]), else: state_opts
    state_opts
  end

  defp maybe_start_aws_apps(:s3) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)
  end

  defp maybe_start_aws_apps(_), do: :ok

  defp save_pem_file(private_key, output_file) do
    File.write!(output_file, private_key)
    File.chmod(output_file, 0o600)  # Secure the file (read/write owner only)
  end
end
