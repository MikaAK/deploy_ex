defmodule Mix.Tasks.DeployEx.Qa.DeployTest do
  use ExUnit.Case, async: true

  # parse_args/1 is private — mirror the OptionParser config here.
  # Same pattern as deploy_ex_qa_create_test.exs.

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :sha, q: :quiet, i: :instance_id],
      switches: [
        sha: :string,
        quiet: :boolean,
        instance_id: :string,
        aws_region: :string,
        aws_release_bucket: :string,
        no_tui: :boolean
      ]
    )
  end

  describe "parse_args/1 option parsing" do
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

    test "--instance-id parses to opts[:instance_id]" do
      {opts, _extra} = parse_args(["--instance-id", "i-0abc1234"])
      assert opts[:instance_id] === "i-0abc1234"
    end

    test "-i alias parses to opts[:instance_id]" do
      {opts, _extra} = parse_args(["-i", "i-0abc1234"])
      assert opts[:instance_id] === "i-0abc1234"
    end

    test "opts[:instance_id] is nil when --instance-id not passed" do
      {opts, _extra} = parse_args(["my_app", "--sha", "abc1234"])
      assert is_nil(opts[:instance_id])
    end

    test "positional app name ends up in extra_args" do
      {_opts, extra} = parse_args(["my_app", "--sha", "abc1234"])
      assert extra === ["my_app"]
    end

    test "opts is a keyword list, not a map" do
      {opts, _extra} = parse_args(["--sha", "abc1234"])
      assert Keyword.keyword?(opts)
    end

    test "--instance-id and --sha can be combined" do
      {opts, _extra} = parse_args(["--sha", "abc1234", "--instance-id", "i-0abc1234"])
      assert opts[:sha] === "abc1234"
      assert opts[:instance_id] === "i-0abc1234"
    end

    test "--quiet parses to opts[:quiet] === true" do
      {opts, _extra} = parse_args(["--quiet"])
      assert opts[:quiet] === true
    end

    test "-q alias parses to opts[:quiet] === true" do
      {opts, _extra} = parse_args(["-q"])
      assert opts[:quiet] === true
    end
  end
end
