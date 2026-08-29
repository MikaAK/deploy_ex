defmodule DeployEx.Cloud.OciCli do
  @moduledoc """
  Runner for the `oci` CLI, which is how deploy_ex talks to Oracle Cloud.

  No usable OCI SDK exists for Elixir or Erlang: `ex_oci_sdk` covers only the Queue service,
  and "OCI" in the Erlang ecosystem means Oracle Call Interface, a database driver for a
  different product. ExAws cannot substitute either — its partition table is compile-time, so
  an OCI region can never be registered, and signing with an AWS region against an OCI
  endpoint returns 403 because OCI requires the OCI region inside the SigV4 credential scope.

  `OCI_CLI_AUTH` selects the credential source: `api_key` on a workstation or in CI, and
  `instance_principal` on an OCI instance, which is the analogue of an EC2 instance profile.
  Session-token auth is deliberately not the default because it needs a browser and expires.
  """

  alias DeployEx.{Config, Utils}

  @doc """
  Runs an `oci` subcommand and returns its raw stdout.

  `:run_fn` in `opts` replaces the shell call. It is the injection seam that makes output
  parsing testable without a live tenancy, matching the `:request_fn` seam in
  `DeployEx.Cloud.S3ObjectStore`.
  """
  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}
  def run(subcommand, opts \\ []) do
    command = build_command(subcommand, opts)
    run_fn = opts[:run_fn] || (&Utils.run_command_with_return/2)

    case run_fn.(command, File.cwd!()) do
      {:ok, output} -> {:ok, output}
      {:error, error} -> {:error, classify_error(error, command)}
    end
  end

  @doc """
  Runs an `oci` subcommand and decodes its JSON payload.

  The CLI prints NOTHING — not `{"data": []}` — when a list matches no resources, so empty
  output decodes to an empty map rather than a JSON error. Without this an empty compartment
  is indistinguishable from a broken command.
  """
  @spec run_json(String.t(), keyword()) :: {:ok, map()} | {:error, ErrorMessage.t()}
  def run_json(subcommand, opts \\ []) do
    with {:ok, output} <- run("#{subcommand} --output json", opts) do
      decode_payload(output)
    end
  end

  @doc """
  Reads an OCI setting from opts first, then application config.

  Opts keys carry an `oci_` prefix (`:oci_region`, `:oci_profile`), matching the convention
  `Mix.Tasks.Ansible.Build` already uses. The prefix is load-bearing, not cosmetic: opts
  reaching here often came from an AWS-shaped caller carrying a bare `:region` of `us-west-2`,
  and reading that as the OCI region would send every call to a region the tenancy is not in.
  """
  @spec setting(keyword(), atom()) :: term()
  def setting(opts, key), do: opts[:"oci_#{key}"] || Config.oci_setting(key)

  # SUPPRESS_LABEL_WARNING silences a stderr nag about unlabeled API keys. That nag would
  # otherwise land in the merged stdout/stderr stream run_command_with_return/2 returns and
  # break JSON decoding.
  #
  # :auth/:profile/:region come from opts (an oci_* CLI override) or application config, both
  # of which land here unvalidated for shell-safety — an unquoted value with a `;`, `&&`, or
  # backtick is a shell injection, not just a malformed OCI flag. quote_arg/1 (below) wraps
  # every one of them the same way OciMachine/OciObjectStore quote their own command args.
  defp build_command(subcommand, opts) do
    auth = setting(opts, :auth) || "api_key"
    flags = build_flags(opts)

    String.trim("OCI_CLI_AUTH=#{quote_arg(auth)} SUPPRESS_LABEL_WARNING=True oci #{subcommand} #{flags}")
  end

  defp build_flags(opts) do
    [{"--profile", setting(opts, :profile)}, {"--region", setting(opts, :region)}]
    |> Enum.reject(fn {_flag, value} -> is_nil(value) end)
    |> Enum.map_join(" ", fn {flag, value} -> "#{flag} #{quote_arg(value)}" end)
  end

  @doc "Single-quotes a shell argument, escaping embedded single quotes. Shared by every OCI CLI caller."
  @spec quote_arg(term()) :: String.t()
  def quote_arg(value), do: "'#{String.replace(to_string(value), "'", "'\\''")}'"

  defp decode_payload(output) do
    case String.trim(output) do
      "" -> {:ok, %{}}
      trimmed -> decode_json(trimmed, output)
    end
  end

  defp decode_json(trimmed, original) do
    case Jason.decode(trimmed) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, decode_error} ->
        {:error,
         ErrorMessage.internal_server_error(
           "failed to decode oci CLI JSON output: #{Exception.message(decode_error)}",
           %{output: original}
         )}
    end
  end

  # A failed call prints `ServiceError:` followed by a JSON body carrying the real HTTP status.
  # Mapping that status onto an ErrorMessage is what lets callers tell "bucket already exists"
  # (409) and "no such object" (404) apart from a genuine failure, rather than treating every
  # non-zero exit as opaque.
  defp classify_error(%ErrorMessage{details: %{output: output}} = error, command) do
    case parse_service_error(output) do
      nil -> error
      {status, message} -> build_service_error(status, message, command, output)
    end
  end

  defp classify_error(error, _command), do: error

  defp parse_service_error(output) do
    with [_prefix, json] <- String.split(output, "ServiceError:", parts: 2),
         {:ok, %{"status" => status} = body} <- Jason.decode(String.trim(json)) do
      {status, body["message"] || "oci service error"}
    else
      _no_service_error -> nil
    end
  end

  defp build_service_error(status, message, command, output) do
    %ErrorMessage{
      code: ErrorMessage.http_code_reason_atom(status),
      message: message,
      details: %{command: command, output: output, status: status}
    }
  end
end
