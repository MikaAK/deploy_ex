defmodule DeployEx.GitHubActions.QaDeployStepInstaller do
  @moduledoc """
  Idempotently patches a GitHub Actions workflow file so that QA branch builds
  trigger `mix deploy_ex.qa.deploy` after the SSH key/PEM file is written, and
  so the existing `mix ansible.deploy` step skips on QA branches.

  Modifies the file as text — preserves user comments, ordering, and whitespace
  outside the managed regions. Sentinel comments mark every managed edit so
  re-runs are no-ops:

    * `# deploy_ex:qa-deploy:begin` / `# deploy_ex:qa-deploy:end` — wrap the
      inserted "Deploy to QA Node" step.
    * `# deploy_ex:qa-skip` — trailing marker on the managed `if:` guard for
      the existing `mix ansible.deploy` step.

  ## Anchor resolution

  Ansible needs the SSH private key on disk before it can connect to a deploy
  host. The QA step must therefore be inserted AFTER the step that writes the
  PEM file. The installer asks the configured LLM (`DeployEx.Config.llm_provider/0`)
  to identify the PEM-writing step by name; this is more reliable than a
  keyword scan because the step name, secret env var, and chmod target are all
  user-configurable. If no LLM is configured, or the LLM cannot identify a
  PEM-writing step, the installer falls back to the historical
  `mix deploy_ex.upload` anchor.

  Result map fields:

    * `:qa_step` — `:inserted` | `:already_installed`
    * `:ansible_guard` — `:inserted` | `:already_installed` |
      `:skipped_user_managed` (step has a non-managed `if:`) |
      `:not_applicable` (no `mix ansible.deploy` step present)
    * `:anchor` — `{:pem_step, name}` | `{:upload_step, signature}` — which
      anchor was used. Useful for telemetry / debugging the install.

  Errors:

    * `:not_found` — workflow file does not exist.
    * `:unprocessable_entity` — neither a PEM-writing step nor the
      `mix deploy_ex.upload` step is present, so the QA-deploy step has no
      deterministic place to go.
  """

  alias DeployEx.LLMMerge

  @qa_step_begin_marker "# deploy_ex:qa-deploy:begin"
  @qa_step_end_marker "# deploy_ex:qa-deploy:end"
  @qa_apps_marker "# deploy_ex:qa-apps:"
  @ansible_guard_marker "# deploy_ex:qa-skip"
  @upload_anchor_signature "mix deploy_ex.upload"
  @ansible_step_name_signature "Run Ansible Deploy"
  @pem_none_response "NONE"

  @type anchor_kind :: {:pem_step, String.t()} | {:upload_step, String.t()}

  @type install_result :: %{
          qa_step: :inserted | :updated | :already_installed,
          ansible_guard:
            :inserted | :already_installed | :skipped_user_managed | :not_applicable,
          qa_apps: [String.t()],
          anchor: anchor_kind() | nil
        }

  @spec install(Path.t(), String.t() | nil) :: {:ok, install_result} | {:error, ErrorMessage.t()}
  def install(workflow_path, app_name \\ nil) do
    with {:ok, contents} <- read_workflow(workflow_path),
         {:ok, with_qa_step, qa_status, qa_apps, anchor} <- ensure_qa_step(contents, app_name),
         {:ok, final_contents, guard_status} <- ensure_ansible_guard(with_qa_step) do
      write_if_changed(workflow_path, contents, final_contents)

      {:ok,
       %{
         qa_step: qa_status,
         ansible_guard: guard_status,
         qa_apps: qa_apps,
         anchor: anchor
       }}
    end
  end

  @spec installed?(Path.t()) :: boolean()
  def installed?(workflow_path) do
    case File.read(workflow_path) do
      {:ok, contents} -> qa_step_present?(contents)
      {:error, _reason} -> false
    end
  end

  @doc """
  Returns the QA apps currently tracked in the installed block, or `[]`
  when no block is present (or when the block predates the apps marker).
  """
  @spec tracked_apps(Path.t()) :: [String.t()]
  def tracked_apps(workflow_path) do
    case File.read(workflow_path) do
      {:ok, contents} -> parse_tracked_apps(contents)
      _ -> []
    end
  end

  defp read_workflow(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         ErrorMessage.not_found(
           "workflow file not readable: #{path}",
           %{path: path, reason: reason}
         )}
    end
  end

  defp ensure_qa_step(contents, app_name) do
    cond do
      qa_step_present?(contents) ->
        upgrade_existing_block(contents, app_name)

      true ->
        insert_fresh_qa_step(contents, app_name)
    end
  end

  defp insert_fresh_qa_step(contents, app_name) do
    case resolve_insert_anchor(contents) do
      {:ok, anchor_line, anchor_kind} ->
        apps = normalize_apps([app_name])
        {:ok, insert_qa_step_after(contents, anchor_line, apps), :inserted, apps, anchor_kind}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_insert_anchor(contents) do
    with {:ok, step_name} <- detect_pem_step_via_llm(contents),
         %{} = anchor_line <- find_anchor_block_end_by_step_name(contents, step_name) do
      {:ok, anchor_line, {:pem_step, step_name}}
    else
      _ -> resolve_upload_anchor(contents)
    end
  end

  defp resolve_upload_anchor(contents) do
    case find_anchor_step_block_end_by_signature(contents, @upload_anchor_signature) do
      %{} = anchor_line ->
        {:ok, anchor_line, {:upload_step, @upload_anchor_signature}}

      nil ->
        {:error,
         ErrorMessage.unprocessable_entity(
           "workflow has no PEM-writing step and no `#{@upload_anchor_signature}` step; cannot place QA-deploy step",
           %{upload_anchor: @upload_anchor_signature}
         )}
    end
  end

  defp detect_pem_step_via_llm(contents) do
    case LLMMerge.ask(pem_detection_prompt(contents)) do
      {:ok, text} -> parse_pem_detection_response(text)
      {:error, _} = err -> err
    end
  end

  defp pem_detection_prompt(contents) do
    """
    You are reading a GitHub Actions workflow YAML. Identify the single job step
    that writes the SSH PEM / private-key file used to connect to deploy hosts.

    Indicators (any combination):
      - writes a file whose name ends in `.pem` (often via `echo "$SECRET" > path/$PEM_FILE`)
      - references a secret variable like `EC2_PEM_FILE`, `SSH_KEY`, `DEPLOY_KEY`
      - runs `chmod 400` / `chmod 0400` on a key file immediately after writing it

    Reply with the EXACT step name (the value after `- name:`), nothing else.
    Strip surrounding quotes. Do not include any explanation, backticks, or punctuation.
    If no such step exists in the workflow, reply with the single token: #{@pem_none_response}

    Workflow:

    ```yaml
    #{contents}
    ```
    """
  end

  defp parse_pem_detection_response(text) do
    cleaned =
      text
      |> String.trim()
      |> String.trim(~s("))
      |> String.trim(~s('))
      |> String.trim()

    cond do
      cleaned === "" -> {:error, :empty_response}
      String.upcase(cleaned) === @pem_none_response -> {:error, :no_pem_step}
      true -> {:ok, cleaned}
    end
  end

  defp find_anchor_block_end_by_step_name(contents, step_name) do
    lines = String.split(contents, "\n")
    pattern = ~r/^\s*-\s+name:\s+#{Regex.escape(step_name)}\s*$/

    case Enum.find_index(lines, &Regex.match?(pattern, &1)) do
      nil -> nil
      idx -> last_line_of_step_starting_around(lines, idx)
    end
  end

  defp upgrade_existing_block(contents, app_name) do
    current_apps = parse_tracked_apps(contents)
    new_apps = add_app(current_apps, app_name)

    if new_apps === current_apps and block_marker_present?(contents) do
      {:ok, contents, :already_installed, current_apps, nil}
    else
      {:ok, rewrite_block(contents, new_apps), :updated, new_apps, nil}
    end
  end

  defp parse_tracked_apps(contents) do
    case Regex.run(~r/#{Regex.escape(@qa_apps_marker)}[ \t]*([^\n]*)/, contents) do
      [_, list] -> split_apps_list(list)
      _ -> []
    end
  end

  defp split_apps_list(list) do
    list
    |> String.trim()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 === ""))
  end

  defp add_app(apps, nil), do: apps
  defp add_app(apps, ""), do: apps

  defp add_app(apps, app_name) when is_binary(app_name) do
    if app_name in apps, do: apps, else: apps ++ [app_name]
  end

  defp normalize_apps(apps) do
    apps
    |> Enum.reject(&blank_app?/1)
    |> Enum.uniq()
  end

  defp blank_app?(nil), do: true
  defp blank_app?(""), do: true
  defp blank_app?(_), do: false

  defp block_marker_present?(contents), do: String.contains?(contents, @qa_apps_marker)

  defp qa_step_present?(contents) do
    String.contains?(contents, @qa_step_begin_marker) and
      String.contains?(contents, @qa_step_end_marker)
  end

  defp find_anchor_step_block_end_by_signature(contents, signature) do
    lines = String.split(contents, "\n")

    case Enum.find_index(lines, &String.contains?(&1, signature)) do
      nil -> nil
      idx -> last_line_of_step_starting_around(lines, idx)
    end
  end

  defp last_line_of_step_starting_around(lines, anchor_idx) do
    step_start_idx = step_start_idx_at_or_before(lines, anchor_idx)
    step_indent = leading_space_count(Enum.at(lines, step_start_idx))
    next_step_idx = next_step_or_eof_idx(lines, step_start_idx + 1, step_indent)
    %{step_start: step_start_idx, insert_after: next_step_idx - 1, step_indent: step_indent}
  end

  defp step_start_idx_at_or_before(lines, idx) do
    Enum.reduce_while(idx..0//-1, idx, fn i, _acc ->
      if step_header_line?(Enum.at(lines, i)), do: {:halt, i}, else: {:cont, idx}
    end)
  end

  defp step_header_line?(line) when is_binary(line) do
    Regex.match?(~r/^\s*-\s+(name:|uses:|run:|id:)/, line)
  end

  defp step_header_line?(_), do: false

  defp next_step_or_eof_idx(lines, from_idx, step_indent) do
    total = length(lines)

    Enum.reduce_while(from_idx..(total - 1), total, fn i, _acc ->
      line = Enum.at(lines, i)

      if step_header_line?(line) and leading_space_count(line) === step_indent do
        {:halt, i}
      else
        {:cont, total}
      end
    end)
  end

  defp leading_space_count(line) when is_binary(line) do
    line |> String.graphemes() |> Enum.take_while(&(&1 === " ")) |> length()
  end

  defp leading_space_count(_), do: 0

  defp insert_qa_step_after(contents, %{insert_after: insert_idx, step_indent: indent}, apps) do
    lines = String.split(contents, "\n")
    {before_lines, after_lines} = Enum.split(lines, insert_idx + 1)
    qa_block = qa_step_lines(indent, apps)
    Enum.join(before_lines ++ qa_block ++ after_lines, "\n")
  end

  defp rewrite_block(contents, apps) do
    lines = String.split(contents, "\n")
    {begin_idx, end_idx, indent} = locate_block(lines)

    {head, _} = Enum.split(lines, begin_idx)
    tail = Enum.drop(lines, end_idx + 1)

    new_block = qa_step_lines(indent, apps)
    Enum.join(head ++ new_block ++ tail, "\n")
  end

  defp locate_block(lines) do
    begin_idx = Enum.find_index(lines, &String.contains?(&1, @qa_step_begin_marker))
    end_idx = Enum.find_index(lines, &String.contains?(&1, @qa_step_end_marker))
    indent = leading_space_count(Enum.at(lines, begin_idx))

    if begin_idx > 0 and Enum.at(lines, begin_idx - 1) === "" do
      {begin_idx - 1, end_idx, indent}
    else
      {begin_idx, end_idx, indent}
    end
  end

  defp qa_step_lines(indent, apps) do
    pad = String.duplicate(" ", indent)
    inner = String.duplicate(" ", indent + 2)
    run = String.duplicate(" ", indent + 4)
    apps_csv = Enum.join(apps, ",")
    apps_shell = Enum.map_join(apps, " ", &shell_quote/1)

    [
      "",
      pad <> @qa_step_begin_marker,
      pad <> "- name: Deploy to QA Nodes",
      inner <> "if: ${{ startsWith(github.ref, 'refs/heads/qa/') || startsWith(github.ref, 'refs/heads/qa-') }}",
      inner <> "run: |",
      run <> @qa_apps_marker <> " " <> apps_csv,
      run <> "branch_name=\"${GITHUB_REF#refs/heads/}\"",
      run <> "sha=$(git rev-parse --short ${{ github.sha }})",
      run <> "for app in #{apps_shell}; do",
      run <> "  mix deploy_ex.qa.deploy \"$app\" \\",
      run <> "    --sha \"$sha\" \\",
      run <> "    --git-branch \"$branch_name\" \\",
      run <> "    --only-local-release \\",
      run <> "    --no-tui --quiet",
      run <> "done",
      pad <> @qa_step_end_marker
    ]
  end

  defp shell_quote(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9_\-\.\/]+$/, value) do
      value
    else
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    end
  end

  defp ensure_ansible_guard(contents) do
    lines = String.split(contents, "\n")

    case find_ansible_step(lines) do
      nil ->
        {:ok, contents, :not_applicable}

      %{name_idx: name_idx} = step ->
        evaluate_ansible_step(contents, lines, name_idx, step)
    end
  end

  defp evaluate_ansible_step(contents, lines, name_idx, step) do
    cond do
      ansible_guard_marker_present?(lines, step) ->
        {:ok, contents, :already_installed}

      user_managed_if?(lines, step) ->
        {:ok, contents, :skipped_user_managed}

      true ->
        new_contents = insert_ansible_guard(lines, name_idx, step.indent)
        {:ok, new_contents, :inserted}
    end
  end

  defp find_ansible_step(lines) do
    name_idx =
      Enum.find_index(lines, fn line ->
        Regex.match?(~r/^\s*-\s+name:\s+#{@ansible_step_name_signature}\b/, line)
      end)

    case name_idx do
      nil ->
        nil

      idx ->
        line = Enum.at(lines, idx)
        indent = leading_space_count(line)
        next_idx = next_step_or_eof_idx(lines, idx + 1, indent)
        %{name_idx: idx, indent: indent, end_idx: next_idx - 1}
    end
  end

  defp ansible_guard_marker_present?(lines, %{name_idx: name_idx, end_idx: end_idx}) do
    lines
    |> Enum.slice(name_idx..end_idx)
    |> Enum.any?(&String.contains?(&1, @ansible_guard_marker))
  end

  defp user_managed_if?(lines, %{name_idx: name_idx, end_idx: end_idx, indent: indent}) do
    inner_indent = indent + 2
    if_prefix = String.duplicate(" ", inner_indent) <> "if:"

    lines
    |> Enum.slice((name_idx + 1)..end_idx)
    |> Enum.any?(&String.starts_with?(&1, if_prefix))
  end

  defp insert_ansible_guard(lines, name_idx, indent) do
    pad = String.duplicate(" ", indent + 2)

    guard_line =
      "#{pad}if: ${{ !startsWith(github.ref, 'refs/heads/qa/') && !startsWith(github.ref, 'refs/heads/qa-') }}  #{@ansible_guard_marker}"

    {before_lines, after_lines} = Enum.split(lines, name_idx + 1)
    Enum.join(before_lines ++ [guard_line] ++ after_lines, "\n")
  end

  defp write_if_changed(_path, contents, contents), do: :ok

  defp write_if_changed(path, _old, new_contents) do
    File.write!(path, new_contents)
    :ok
  end
end
