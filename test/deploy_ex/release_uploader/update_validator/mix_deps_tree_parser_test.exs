defmodule DeployEx.ReleaseUploader.UpdateValidator.MixDepsTreeParserTest do
  use ExUnit.Case, async: true

  alias DeployEx.ReleaseUploader.UpdateValidator.MixDepsTreeParser

  @cmd_output File.read!(Path.join(__DIR__, "./mix_deps_tree.txt"))

  describe "&parse_deps_tree/1" do
    test "parses the tree correctly" do
      output = MixDepsTreeParser.parse_deps_tree(@cmd_output)

      assert output === Map.new([
        {
          "shared_utils",
          [
            "error_message", "excoveralls", "finch",
            "jason", "proper_case", "tzdata"
          ]
        }, {
          "short_linker",
          ["credo", "error_message", "excoveralls", "shared_utils"]
        }, {
          "learn_elixir_metrics",
          ["excoveralls", "prometheus_telemetry", "telemetry_metrics"]
        }, {
          "learn_elixir_mailer",
          ["finch", "swoosh"]
        }, {
          "learn_elixir_lander",
          [
            "con_cache", "credo", "dart_sass",
            "earmark", "ecto", "error_message",
            "esbuild", "ex_aws", "ex_aws_s3",
            "excoveralls", "faker", "finch",
            "floki", "gen_smtp", "gettext", "hackney",
            "jason", "learn_elixir_mailer", "mailchimp",
            "phoenix", "phoenix_ecto", "phoenix_html",
            "phoenix_live_dashboard", "phoenix_live_reload",
            "phoenix_live_view", "plug_cowboy", "postgrex",
            "pot", "shared_utils", "short_linker", "sweet_xml",
            "swoosh", "tailwind", "telemetry_metrics",
            "telemetry_poller", "timex", "tzdata"
          ]
        }, {
          "discord_bot",
          ["excoveralls", "shared_utils"]
        }, {
          "thinkific_session_scraper",
          ["error_message", "excoveralls", "hound", "shared_utils"]
        }, {
          "thinkific_api",
          ["excoveralls", "shared_utils"]
        }, {
          "assignment_marker",
          [
            "con_cache", "error_message",
            "excoveralls", "finch", "gen_stage",
            "learn_elixir_metrics", "prometheus_telemetry",
            "shared_utils", "thinkific_api", "thinkific_session_scraper"
          ]
        }, {
          "learn_elixir_tasks",
          [
            "discord_bot", "excoveralls", "shared_utils",
            "thinkific_api", "thinkific_session_scraper"
          ]
        }
      ])
    end
  end
end
