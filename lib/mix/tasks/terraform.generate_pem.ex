
defmodule Mix.Tasks.Terraform.GeneratePem do
  @moduledoc """
  Extracts the PEM file and key name from the Terraform state and saves it to a file.
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

    with {:ok, state} <- TerraformState.read_state(opts[:directory]),
         {:ok, private_key} <- TerraformState.get_resource_attribute(state, "tls_private_key", "key_pair", "private_key_pem"),
         {:ok, key_name} <- TerraformState.get_resource_attribute(state, "aws_key_pair", "key_pair", "key_name") do

      # If no output file is provided, default to `<key_name>.pem`
      output_file = Path.join(opts[:directory], opts[:output_file] || "#{key_name}.pem")

      save_pem_file(private_key, output_file)
      Mix.shell().info([:green, "PEM file saved to: ", :reset, output_file])
    else
      {:error, e} ->
        IO.inspect(e, label: "Error extracting PEM from Terraform")
        Mix.raise("Failed to extract PEM key from Terraform state")
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [d: :directory, o: :output_file],
      switches: [
        directory: :string,
        output_file: :string
      ]
    )

    opts
  end

  defp save_pem_file(private_key, output_file) do
    File.write!(output_file, private_key)
    File.chmod(output_file, 0o600)  # Secure the file (read/write owner only)
  end
end
