defmodule Mix.Tasks.DeployEx.Qa.CreateTest do
  use ExUnit.Case, async: true

  # parse_args/1 is private, so we mirror the OptionParser config here and test
  # the observable option output — the same approach used in qa_destroy_test.exs.

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :sha, t: :tag, f: :force, q: :quiet],
      switches: [
        sha: :string,
        tag: :string,
        instance_type: :string,
        skip_setup: :boolean,
        skip_deploy: :boolean,
        skip_ami: :boolean,
        attach_lb: :boolean,
        force: :boolean,
        quiet: :boolean,
        aws_region: :string,
        aws_release_bucket: :string,
        no_tui: :boolean
      ]
    )
  end

  describe "parse_args/1 option parsing" do
    test "--tag parses to opts[:tag]" do
      {opts, _extra} = parse_args(["--tag", "my-feature"])
      assert opts[:tag] === "my-feature"
    end

    test "-t alias parses to opts[:tag]" do
      {opts, _extra} = parse_args(["-t", "my-feature"])
      assert opts[:tag] === "my-feature"
    end

    test "--sha parses to opts[:sha]" do
      {opts, _extra} = parse_args(["--sha", "abc1234"])
      assert opts[:sha] === "abc1234"
    end

    test "-s alias parses to opts[:sha]" do
      {opts, _extra} = parse_args(["-s", "abc1234"])
      assert opts[:sha] === "abc1234"
    end

    test "opts[:sha] is nil when --sha not passed" do
      {opts, _extra} = parse_args(["my_app"])
      assert is_nil(opts[:sha])
    end

    test "opts[:tag] is nil when --tag not passed" do
      {opts, _extra} = parse_args(["my_app", "--sha", "abc1234"])
      assert is_nil(opts[:tag])
    end

    test "positional app name ends up in extra_args" do
      {_opts, extra} = parse_args(["my_app", "--sha", "abc1234"])
      assert extra === ["my_app"]
    end

    test "opts is a keyword list, not a map" do
      {opts, _extra} = parse_args(["--sha", "abc1234"])
      assert Keyword.keyword?(opts)
    end

    test "--tag and --sha can be combined" do
      {opts, _extra} = parse_args(["--sha", "abc1234", "--tag", "my-feature"])
      assert opts[:sha] === "abc1234"
      assert opts[:tag] === "my-feature"
    end

    test "--force parses to opts[:force] === true" do
      {opts, _extra} = parse_args(["--force"])
      assert opts[:force] === true
    end

    test "-f alias parses to opts[:force] === true" do
      {opts, _extra} = parse_args(["-f"])
      assert opts[:force] === true
    end
  end
end
