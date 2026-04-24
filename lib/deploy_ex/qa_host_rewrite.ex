defmodule DeployEx.QaHostRewrite do
  @moduledoc """
  Rewrites Phoenix/CORS/cookie host references in the umbrella being deployed so
  a QA node with a public IP SSL cert can serve the app directly from its IP.

  Flow:

  1. `scan_candidates/1` — greps the umbrella for host-like config (endpoint
     `url: [host: ...]`, `check_origin`, cookie `:domain`, hardcoded production
     domains) and returns a list of `{path, chunk_text, start_line}` entries.
     Only relevant file types (`.ex`, `.exs`) are scanned; whole-file content
     is chunked to keep LLM prompts small.

  2. `propose_rewrite/3` — hands each chunk to the LLM via LangChain, asking for
     a rewritten version that routes traffic to the QA IP. Returns a list of
     `%{path, original, rewritten, rationale}` proposals.

  3. `review_and_apply/3` — opens `DeployEx.TUI.DiffViewer` per-file. Accepted
     files get backed up to the QA node's backup dir, then written to disk.
     A `manifest.json` records every backup with sha256 of the original so
     `restore/2` can detect drift later.

  4. `restore/2` — reads the manifest and restores the originals. If a file's
     on-disk sha256 no longer matches what the manifest recorded as "rewritten"
     content, the user has modified it since — we prompt before overwriting.

  The backup dir is `~/.deploy_ex/qa-host-rewrites/<app>-<instance_id>/`.
  """

  @backup_root "~/.deploy_ex/qa-host-rewrites"
  @manifest_filename "manifest.json"

  @type proposal :: %{
          path: String.t(),
          original: String.t(),
          rewritten: String.t(),
          rationale: String.t()
        }

  @type manifest_entry :: %{
          path: String.t(),
          sha256_before: String.t(),
          sha256_after: String.t()
        }

  # SECTION: Public API — scan / propose / apply / restore

  @spec scan_candidates(String.t(), String.t(), String.t()) ::
          {:ok, [%{path: String.t(), content: String.t()}]}
  def scan_candidates(umbrella_root, app_name, module_prefix) do
    host_patterns = host_patterns()
    app_patterns = app_patterns(app_name, module_prefix)

    config_candidates =
      umbrella_root
      |> config_files()
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&any_pattern_matches?(&1, host_patterns))
      |> Enum.filter(&any_pattern_matches?(&1, app_patterns))

    endpoint_candidates =
      umbrella_root
      |> endpoint_files(app_name)
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&any_pattern_matches?(&1, host_patterns))

    candidates =
      (config_candidates ++ endpoint_candidates)
      |> Enum.uniq()
      |> Enum.map(&%{path: &1, content: File.read!(&1)})

    {:ok, candidates}
  end

  @spec propose_rewrite([%{path: String.t(), content: String.t()}], String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [proposal()]} | {:error, term()}
  def propose_rewrite(candidates, public_ip, app_name, module_prefix, opts \\ []) do
    proposals =
      candidates
      |> Enum.map(&build_proposal(&1, public_ip, app_name, module_prefix, opts))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, proposal}, {:ok, acc} -> {:cont, {:ok, [proposal | acc]}}
        {:skip, _}, {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error, _ -> {:halt, error}
      end)

    case proposals do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = error -> error
    end
  end

  @spec review_and_apply([proposal()], String.t(), keyword()) ::
          {:ok, [manifest_entry()]} | {:error, term()}
  def review_and_apply(proposals, backup_dir, opts \\ []) do
    File.mkdir_p!(backup_dir)

    entries =
      proposals
      |> Enum.map(&review_one(&1, backup_dir, opts))
      |> Enum.reject(&is_nil/1)

    write_manifest(backup_dir, entries)
    {:ok, entries}
  end

  @spec restore(Path.t(), keyword()) :: :ok | {:error, term()}
  def restore(backup_dir, opts \\ []) do
    manifest_path = Path.join(backup_dir, @manifest_filename)

    cond do
      not File.exists?(backup_dir) ->
        :ok

      not File.exists?(manifest_path) ->
        Mix.shell().info([:yellow, "  No manifest found in #{backup_dir}, skipping restore"])
        :ok

      true ->
        manifest_path |> File.read!() |> Jason.decode!() |> restore_entries(backup_dir, opts)
        File.rm_rf!(backup_dir)
        :ok
    end
  end

  @spec backup_dir(String.t(), String.t()) :: Path.t()
  def backup_dir(app_name, instance_id) do
    @backup_root
    |> Path.expand()
    |> Path.join("#{app_name}-#{instance_id}")
  end

  @spec working_tree_clean?(Path.t()) :: {:ok, boolean()} | {:error, term()}
  def working_tree_clean?(umbrella_root) do
    case DeployEx.Utils.run_command_with_return("git status --porcelain", umbrella_root) do
      {:ok, output} -> {:ok, String.trim(output) === ""}
      {:error, _} = error -> error
    end
  end

  # SECTION: Scan — candidate file discovery

  defp host_patterns do
    [
      ~r/check_origin/,
      ~r/host:\s*["']/,
      ~r/url:\s*\[/,
      ~r/:domain\s*=>/,
      ~r/domain:\s*["']/,
      ~r/https?:\/\/[^"'\s]+\.(com|io|dev|net|org)/
    ]
  end

  defp app_patterns(app_name, module_prefix) do
    [~r/:#{Regex.escape(app_name)}\b/, ~r/\b#{Regex.escape(module_prefix)}\./]
  end

  defp config_files(umbrella_root) do
    umbrella_root |> Path.join("config/*.exs") |> Path.wildcard()
  end

  defp endpoint_files(umbrella_root, app_name) do
    umbrella_root
    |> Path.join("apps/#{app_name}/lib/**/endpoint.ex")
    |> Path.wildcard()
  end

  defp any_pattern_matches?(path, patterns) do
    content = File.read!(path)
    Enum.any?(patterns, &Regex.match?(&1, content))
  end

  # SECTION: Proposal — LLM rewrite per file

  defp build_proposal(%{path: path, content: content}, public_ip, app_name, module_prefix, opts) do
    prompt = rewrite_prompt(path, content, public_ip, app_name, module_prefix)

    case DeployEx.LLMMerge.ask(prompt, opts) do
      {:ok, response} -> parse_llm_response(path, content, response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_llm_response(path, original, response) do
    trimmed = String.trim(response)

    if String.starts_with?(trimmed, "SKIP:") do
      {:skip, trimmed}
    else
      build_proposal_from_response(path, original, trimmed)
    end
  end

  defp build_proposal_from_response(path, original, response) do
    case extract_rewritten_block(response) do
      {:ok, rewritten, rationale} when rewritten !== original ->
        {:ok,
         %{
           path: path,
           original: original,
           rewritten: rewritten,
           rationale: rationale
         }}

      {:ok, _same, _rationale} ->
        {:skip, "no changes needed"}

      {:error, _} ->
        {:skip, "malformed LLM response"}
    end
  end

  defp extract_rewritten_block(response) do
    case Regex.run(~r/```(?:\w+)?\n(.*?)\n```/s, response, capture: :all_but_first) do
      [code] ->
        rationale = response |> String.replace(~r/```(?:\w+)?\n.*?\n```/s, "") |> String.trim()
        {:ok, code, rationale}

      _ ->
        {:error, :no_code_block}
    end
  end

  defp rewrite_prompt(path, content, public_ip, app_name, module_prefix) do
    """
    You are rewriting an Elixir/Phoenix umbrella config for a QA deployment.

    Target app (CRITICAL — this is the ONLY app whose config should be rewritten):
    - OTP app atom: `:#{app_name}`
    - Phoenix module prefix: `#{module_prefix}` — e.g. `#{module_prefix}.Endpoint`.
      This was extracted directly from `apps/#{app_name}/lib/**/endpoint.ex`, so it
      is the authoritative name for this app's endpoint module.

    A QA EC2 instance has just been provisioned with a public IP and a self-signed
    SSL certificate. The target app will be reached at `https://#{public_ip}` instead
    of the normal production domain.

    Rewrite ONLY lines that apply to the target app. Specifically:

    - `config :#{app_name}, <Mod>.Endpoint, url: [host: "..."]` → `host: "#{public_ip}"`
    - `config :#{app_name}, <Mod>.Endpoint, check_origin: [...]` → add
      `"https://#{public_ip}"` while keeping existing entries
    - Session/cookie `:domain` on the target app's endpoint → set to `nil`
    - Hardcoded `https://<production-domain>` literals that refer to the target app's
      own origin (CORS, absolute_url helpers, redirect URLs) → `https://#{public_ip}`

    DO NOT touch any of the following:

    - Other sibling apps' endpoints in the same file (e.g. other `config :other_app, ...`
      blocks — leave them exactly as they are, byte-for-byte)
    - Shared cluster/node DNS, libcluster epmd hosts, database URLs, Redis hosts
    - Third-party API URLs (Stripe, SES, S3, etc.)
    - Any config key that doesn't route inbound traffic to this app's Endpoint

    File path: `#{path}`

    Current content:

    ```elixir
    #{content}
    ```

    Respond in one of two ways:

    1. If no changes are needed (file doesn't configure the target app's endpoint,
       or already points at the QA IP), reply with exactly:

       SKIP: <one-line reason>

    2. Otherwise, reply with a brief rationale (1-2 sentences naming exactly which
       lines you changed and why they belong to `:#{app_name}`), then the full
       rewritten file inside a fenced code block:

       ```elixir
       <rewritten file content>
       ```

    Preserve all unrelated lines exactly. Do not reformat, do not add comments,
    do not change indentation of unchanged lines.
    """
  end

  # SECTION: Review — DiffViewer per file + backup + write

  defp review_one(%{path: path, original: original, rewritten: rewritten, rationale: rationale}, backup_dir, _opts) do
    Mix.shell().info(["\n", :cyan, "── ", path, :reset])
    if rationale !== "", do: Mix.shell().info([:light_black, rationale])

    case DeployEx.TUI.DiffViewer.run(original, rewritten, title: "QA host rewrite: #{path}") do
      {:ok, merged} when merged !== original ->
        backup_file!(path, original, backup_dir)
        File.write!(path, merged)

        %{
          path: path,
          sha256_before: sha256(original),
          sha256_after: sha256(merged)
        }

      {:ok, _same} ->
        Mix.shell().info([:yellow, "  skipped (no changes accepted)"])
        nil

      :cancelled ->
        Mix.shell().info([:yellow, "  cancelled"])
        nil
    end
  end

  defp backup_file!(path, original, backup_dir) do
    target = backup_file_path(backup_dir, path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, original)
  end

  defp backup_file_path(backup_dir, source_path) do
    relative = source_path |> Path.expand() |> String.replace_leading("/", "")
    Path.join(backup_dir, relative)
  end

  defp write_manifest(backup_dir, entries) do
    manifest_path = Path.join(backup_dir, @manifest_filename)
    File.write!(manifest_path, Jason.encode!(entries, pretty: true))
  end

  # SECTION: Restore — read manifest, restore files, verify sha

  defp restore_entries(entries, backup_dir, opts) do
    Enum.each(entries, &restore_one(&1, backup_dir, opts))
  end

  defp restore_one(%{"path" => path, "sha256_after" => expected_sha} = entry, backup_dir, opts) do
    backup_path = backup_file_path(backup_dir, path)

    cond do
      not File.exists?(backup_path) ->
        Mix.shell().error("  ✗ Backup missing for #{path}, cannot restore")

      not File.exists?(path) ->
        File.write!(path, File.read!(backup_path))
        Mix.shell().info([:green, "  ✓ Restored #{path} (original was deleted)"])

      sha256_of_file(path) === expected_sha || opts[:force] ->
        File.write!(path, File.read!(backup_path))
        Mix.shell().info([:green, "  ✓ Restored #{path}"])

      true ->
        handle_drift(path, backup_path, entry)
    end
  end

  defp handle_drift(path, backup_path, _entry) do
    Mix.shell().info([
      :yellow,
      "  ⚠ #{path} has been modified since the QA rewrite."
    ])

    if Mix.shell().yes?("    Overwrite local changes with the pre-QA original?") do
      File.write!(path, File.read!(backup_path))
      Mix.shell().info([:green, "  ✓ Restored #{path}"])
    else
      Mix.shell().info([:light_black, "  · Kept local changes for #{path}"])
    end
  end

  # SECTION: Hashing

  defp sha256(content) do
    content
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sha256_of_file(path) do
    path |> File.read!() |> sha256()
  end
end
