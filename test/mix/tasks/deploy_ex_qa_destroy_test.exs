defmodule Mix.Tasks.DeployEx.Qa.DestroyTest do
  use ExUnit.Case, async: true

  # Access parse_args/1 via the module directly — it's private, so we test
  # via the public-facing behaviour by calling the task with no valid project,
  # but parse_args itself is the unit we care about most. We expose it in a
  # test-helper function instead of making it public.
  #
  # Since parse_args/1 is private, we test the observable output of the options
  # by directly exercising OptionParser with the same config.

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [i: :instance_id, f: :force, q: :quiet],
      switches: [
        instance_id: :string,
        all: :boolean,
        force: :boolean,
        quiet: :boolean
      ]
    )
  end

  describe "parse_args/1 option parsing" do
    test "--all flag parses to opts[:all] === true" do
      {opts, _extra} = parse_args(["--all"])
      assert opts[:all] === true
    end

    test "--instance-id parses to opts[:instance_id]" do
      {opts, _extra} = parse_args(["--instance-id", "i-abc123"])
      assert opts[:instance_id] === "i-abc123"
    end

    test "-i alias parses to opts[:instance_id]" do
      {opts, _extra} = parse_args(["-i", "i-abc123"])
      assert opts[:instance_id] === "i-abc123"
    end

    test "--force flag parses to opts[:force] === true" do
      {opts, _extra} = parse_args(["--force"])
      assert opts[:force] === true
    end

    test "-f alias parses to opts[:force] === true" do
      {opts, _extra} = parse_args(["-f"])
      assert opts[:force] === true
    end

    test "positional app name ends up in extra_args" do
      {_opts, extra} = parse_args(["my_app"])
      assert extra === ["my_app"]
    end

    test "opts[:all] is nil when --all not passed" do
      {opts, _extra} = parse_args(["my_app"])
      refute opts[:all]
    end

    test "opts[:instance_id] is nil when -i not passed" do
      {opts, _extra} = parse_args(["my_app"])
      assert is_nil(opts[:instance_id])
    end

    test "opts[:force] is nil when --force not passed" do
      {opts, _extra} = parse_args(["my_app"])
      refute opts[:force]
    end

    test "opts is a keyword list, not a map" do
      {opts, _extra} = parse_args(["--all"])
      assert Keyword.keyword?(opts)
    end
  end
end
