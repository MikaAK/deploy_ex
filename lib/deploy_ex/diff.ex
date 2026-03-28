defmodule DeployEx.Diff do
  @moduledoc """
  Computes unified diffs between two strings and parses them into
  structured hunks for display and selective application.
  """

  # SECTION: Types

  @type line :: %{type: :context | :added | :removed, text: String.t()}

  @type hunk :: %{
          header: String.t(),
          lines: [line()],
          status: :pending | :accepted | :rejected
        }

  # SECTION: Public API

  @spec compute(String.t(), String.t()) :: {:ok, [hunk()]} | {:error, term()}
  def compute(old_content, new_content) do
    old_path = write_temp("old", old_content)
    new_path = write_temp("new", new_content)

    try do
      case System.cmd("diff", ["-u", old_path, new_path], stderr_to_stdout: true) do
        {_output, 0} -> {:ok, []}
        {output, 1} -> {:ok, parse_hunks(output)}
        {error, code} -> {:error, {code, error}}
      end
    after
      File.rm(old_path)
      File.rm(new_path)
    end
  end

  @spec parse_hunks(String.t()) :: [hunk()]
  def parse_hunks(""), do: []

  def parse_hunks(diff_output) do
    diff_output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@ ")))
    |> chunk_by_hunk_header()
    |> Enum.map(&build_hunk/1)
  end

  @spec apply_hunks(String.t(), [hunk()]) :: String.t()
  def apply_hunks(old_content, []), do: old_content

  def apply_hunks(old_content, hunks) do
    old_lines = String.split(old_content, "\n")

    result_lines = apply_hunks_to_lines(old_lines, hunks, 0, [])

    Enum.join(result_lines, "\n")
  end

  # SECTION: Hunk Parsing

  defp chunk_by_hunk_header(lines) do
    lines
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        if String.starts_with?(line, "@@ ") do
          if is_nil(acc), do: {:cont, [line]}, else: {:cont, Enum.reverse(acc), [line]}
        else
          {:cont, [line | (acc || [])]}
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.reject(&Enum.empty?/1)
  end

  defp build_hunk([header | rest]) do
    lines =
      rest
      |> Enum.reject(&(&1 === ""))
      |> Enum.map(fn line ->
        cond do
          String.starts_with?(line, "+") -> %{type: :added, text: String.slice(line, 1..-1//1)}
          String.starts_with?(line, "-") -> %{type: :removed, text: String.slice(line, 1..-1//1)}
          String.starts_with?(line, " ") -> %{type: :context, text: String.slice(line, 1..-1//1)}
          true -> %{type: :context, text: line}
        end
      end)

    %{header: header, lines: lines, status: :pending}
  end

  # SECTION: Hunk Application

  defp apply_hunks_to_lines(old_lines, [], _offset, acc) do
    Enum.reverse(acc) ++ old_lines
  end

  defp apply_hunks_to_lines(old_lines, [hunk | rest], offset, acc) do
    {old_start, _old_count} = parse_hunk_range(hunk.header, :old)

    # Adjusted start position (0-indexed)
    start_idx = old_start - 1 - offset

    # Lines before this hunk (unchanged)
    {before, remaining} = Enum.split(old_lines, max(start_idx, 0))
    acc = Enum.reverse(before) ++ acc

    # Count how many old lines this hunk covers
    old_line_count = Enum.count(hunk.lines, &(&1.type in [:removed, :context]))

    case hunk.status do
      :accepted ->
        # Drop the old lines covered by this hunk
        {_consumed, after_hunk} = Enum.split(remaining, old_line_count)

        # Add the new lines (context + added)
        new_lines =
          hunk.lines
          |> Enum.reject(&(&1.type === :removed))
          |> Enum.map(& &1.text)

        new_acc = Enum.reverse(new_lines) ++ acc
        new_offset = offset + length(before) + old_line_count
        apply_hunks_to_lines(after_hunk, rest, new_offset, new_acc)

      status when status in [:rejected, :pending] ->
        # Keep old lines as-is
        {kept, after_hunk} = Enum.split(remaining, old_line_count)
        new_acc = Enum.reverse(kept) ++ acc
        new_offset = offset + length(before) + old_line_count
        apply_hunks_to_lines(after_hunk, rest, new_offset, new_acc)
    end
  end

  defp parse_hunk_range(header, which) do
    regex = ~r/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    case Regex.run(regex, header) do
      [_, old_start, old_count, new_start, new_count] ->
        case which do
          :old -> {String.to_integer(old_start), String.to_integer(old_count)}
          :new -> {String.to_integer(new_start), String.to_integer(new_count)}
        end

      [_, old_start, "", new_start] ->
        case which do
          :old -> {String.to_integer(old_start), 1}
          :new -> {String.to_integer(new_start), 1}
        end

      _ ->
        {1, 0}
    end
  end

  # SECTION: Helpers

  defp write_temp(prefix, content) do
    path =
      "deploy_ex_diff_#{prefix}_#{System.unique_integer([:positive])}"
      |> then(&Path.join(System.tmp_dir!(), &1))

    File.write!(path, content)
    path
  end
end
