defmodule DeployEx.DiffTest do
  use ExUnit.Case, async: true

  alias DeployEx.Diff

  @old_content """
  line 1
  line 2
  line 3
  line 4
  line 5
  """

  @new_content """
  line 1
  line 2 modified
  line 3
  new line inserted
  line 5
  """

  describe "compute/2" do
    test "returns hunks for differing content" do
      assert {:ok, hunks} = Diff.compute(@old_content, @new_content)
      assert is_list(hunks)
      assert length(hunks) > 0
    end

    test "returns empty list for identical content" do
      assert {:ok, []} = Diff.compute("same\n", "same\n")
    end
  end

  describe "parse_hunks/1" do
    test "parses a unified diff into structured hunks" do
      diff_output = """
      --- a/file.txt
      +++ b/file.txt
      @@ -1,4 +1,4 @@
       line 1
      -line 2
      +line 2 modified
       line 3
      @@ -4,2 +4,3 @@
      -line 4
      +new line inserted
       line 5
      """

      hunks = Diff.parse_hunks(diff_output)

      assert length(hunks) === 2
      assert %{header: header, lines: lines} = hd(hunks)
      assert String.starts_with?(header, "@@ ")
      assert is_list(lines)
    end

    test "returns empty list for empty diff" do
      assert [] === Diff.parse_hunks("")
    end

    test "each hunk line has a type" do
      diff_output = """
      --- a/file.txt
      +++ b/file.txt
      @@ -1,3 +1,3 @@
       context
      -removed
      +added
       context
      """

      [hunk] = Diff.parse_hunks(diff_output)

      types = Enum.map(hunk.lines, & &1.type)
      assert :context in types
      assert :removed in types
      assert :added in types
    end
  end

  describe "apply_hunks/2" do
    test "accepting all hunks produces the new content" do
      old = "line 1\nline 2\nline 3\n"
      new = "line 1\nline 2 modified\nline 3\n"

      {:ok, hunks} = Diff.compute(old, new)
      accepted = Enum.map(hunks, &%{&1 | status: :accepted})

      result = Diff.apply_hunks(old, accepted)
      assert result === new
    end

    test "rejecting all hunks preserves old content" do
      old = "line 1\nline 2\nline 3\n"
      new = "line 1\nline 2 modified\nline 3\n"

      {:ok, hunks} = Diff.compute(old, new)
      rejected = Enum.map(hunks, &%{&1 | status: :rejected})

      result = Diff.apply_hunks(old, rejected)
      assert result === old
    end

    test "mixed accept/reject applies only accepted hunks" do
      # Need enough lines between changes so diff produces two separate hunks
      old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\n"
      new = "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\n"

      {:ok, hunks} = Diff.compute(old, new)
      assert length(hunks) === 2

      # Accept first hunk (b->B), reject second (k->K)
      mixed =
        hunks
        |> Enum.with_index()
        |> Enum.map(fn {hunk, idx} ->
          if idx === 0, do: %{hunk | status: :accepted}, else: %{hunk | status: :rejected}
        end)

      result = Diff.apply_hunks(old, mixed)
      assert String.contains?(result, "B")
      refute String.contains?(result, "K")
      assert String.contains?(result, "k")
    end

    test "returns old content when no hunks" do
      old = "unchanged\n"
      assert old === Diff.apply_hunks(old, [])
    end
  end

  describe "full flow: compute -> mark -> apply" do
    test "accept all hunks transforms old into new" do
      old = "alpha\nbeta\ngamma\ndelta\n"
      new = "alpha\nBETA\ngamma\nDELTA\n"

      {:ok, hunks} = Diff.compute(old, new)
      accepted = Enum.map(hunks, &%{&1 | status: :accepted})
      result = Diff.apply_hunks(old, accepted)

      assert result === new
    end

    test "reject all hunks preserves old" do
      old = "alpha\nbeta\ngamma\ndelta\n"
      new = "alpha\nBETA\ngamma\nDELTA\n"

      {:ok, hunks} = Diff.compute(old, new)
      rejected = Enum.map(hunks, &%{&1 | status: :rejected})
      result = Diff.apply_hunks(old, rejected)

      assert result === old
    end

    test "compute returns ok with empty hunks for identical content" do
      content = "no changes here\n"
      assert {:ok, []} = Diff.compute(content, content)
    end
  end
end
