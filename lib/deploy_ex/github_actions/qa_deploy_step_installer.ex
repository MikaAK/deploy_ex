defmodule DeployEx.GitHubActions.QaDeployStepInstaller do
  @moduledoc """
  Idempotently patches a GitHub Actions workflow file so that QA branch builds
  trigger `mix deploy_ex.qa.deploy` after the upload step, and so the existing
  `mix ansible.deploy` step skips on QA branches.

  Modifies the file as text — preserves user comments, ordering, and whitespace
  outside the managed regions. Sentinel comments mark every managed edit so
  re-runs are no-ops:

    * `# deploy_ex:qa-deploy:begin` / `# deploy_ex:qa-deploy:end` — wrap the
      inserted "Deploy to QA Node" step.
    * `# deploy_ex:qa-skip` — trailing marker on the managed `if:` guard for
      the existing `mix ansible.deploy` step.

  Result map fields:

    * `:qa_step` — `:inserted` | `:already_installed`
    * `:ansible_guard` — `:inserted` | `:already_installed` |
      `:skipped_user_managed` (step has a non-managed `if:`) |
      `:not_applicable` (no `mix ansible.deploy` step present)

  Errors:

    * `:not_found` — workflow file does not exist.
    * `:unprocessable_entity` — anchor step (`mix deploy_ex.upload`) is missing,
      so we cannot place the QA-deploy step deterministically.
  """

  @qa_step_begin_marker "# deploy_ex:qa-deploy:begin"
  @qa_step_end_marker "# deploy_ex:qa-deploy:end"
  @ansible_guard_marker "# deploy_ex:qa-skip"
  @anchor_signature "mix deploy_ex.upload"
  @ansible_step_name_signature "Run Ansible Deploy"

  @type install_result :: %{
          qa_step: :inserted | :already_installed,
          ansible_guard:
            :inserted | :already_installed | :skipped_user_managed | :not_applicable
        }

  @spec install(Path.t()) :: {:ok, install_result} | {:error, ErrorMessage.t()}
  def install(workflow_path) do
    with {:ok, contents} <- read_workflow(workflow_path),
         {:ok, with_qa_step, qa_status} <- ensure_qa_step(contents),
         {:ok, final_contents, guard_status} <- ensure_ansible_guard(with_qa_step) do
      write_if_changed(workflow_path, contents, final_contents)
      {:ok, %{qa_step: qa_status, ansible_guard: guard_status}}
    end
  end

  @spec installed?(Path.t()) :: boolean()
  def installed?(workflow_path) do
    case File.read(workflow_path) do
      {:ok, contents} -> qa_step_present?(contents)
      {:error, _reason} -> false
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

  defp ensure_qa_step(contents) do
    cond do
      qa_step_present?(contents) ->
        {:ok, contents, :already_installed}

      anchor_line = find_anchor_step_block_end(contents) ->
        {:ok, insert_qa_step_after(contents, anchor_line), :inserted}

      true ->
        {:error,
         ErrorMessage.unprocessable_entity(
           "workflow has no `#{@anchor_signature}` step; cannot place QA-deploy step",
           %{anchor: @anchor_signature}
         )}
    end
  end

  defp qa_step_present?(contents) do
    String.contains?(contents, @qa_step_begin_marker) and
      String.contains?(contents, @qa_step_end_marker)
  end

  defp find_anchor_step_block_end(contents) do
    lines = String.split(contents, "\n")

    case Enum.find_index(lines, &String.contains?(&1, @anchor_signature)) do
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

  defp insert_qa_step_after(contents, %{insert_after: insert_idx, step_indent: indent}) do
    lines = String.split(contents, "\n")
    {before_lines, after_lines} = Enum.split(lines, insert_idx + 1)
    qa_block = qa_step_lines(indent)
    Enum.join(before_lines ++ qa_block ++ after_lines, "\n")
  end

  defp qa_step_lines(indent) do
    pad = String.duplicate(" ", indent)
    inner = String.duplicate(" ", indent + 2)
    run = String.duplicate(" ", indent + 4)

    [
      "",
      pad <> @qa_step_begin_marker,
      pad <> "- name: Deploy to QA Node",
      inner <> "if: ${{ startsWith(github.ref, 'refs/heads/qa/') || startsWith(github.ref, 'refs/heads/qa-') }}",
      inner <> "run: |",
      run <> "branch_name=\"${GITHUB_REF#refs/heads/}\"",
      run <> "mix deploy_ex.qa.deploy \\",
      run <> "  --sha $(git rev-parse --short ${{ github.sha }}) \\",
      run <> "  --git-branch \"$branch_name\" \\",
      run <> "  --no-tui --quiet",
      pad <> @qa_step_end_marker
    ]
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
