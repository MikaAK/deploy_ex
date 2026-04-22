defmodule DeployEx.ReleaseLookupTest do
  use ExUnit.Case, async: true

  alias DeployEx.ReleaseLookup

  # Fake releases implementation — returns a pre-configured list of S3 keys.
  defmodule FakeReleases do
    def fetch_all_remote_releases(opts) do
      keys = Process.get(:fake_releases, [])
      prefix = opts[:prefix]

      filtered =
        if prefix do
          Enum.filter(keys, &String.starts_with?(&1, prefix))
        else
          keys
        end

      {:ok, filtered}
    end
  end

  # Fake git implementation — returns pre-configured list of short SHAs.
  defmodule FakeGit do
    def list_shas_on_branch(_branch, _depth) do
      shas = Process.get(:fake_git_shas, [])
      {:ok, shas}
    end
  end

  # Fake git that always errors.
  defmodule FakeGitError do
    def list_shas_on_branch(_branch, _depth) do
      {:error, ErrorMessage.failed_dependency("git not available")}
    end
  end

  defp base_opts do
    [
      aws_region: "us-east-1",
      aws_release_bucket: "test-bucket",
      releases_impl: FakeReleases,
      git_impl: FakeGit
    ]
  end

  defp set_releases(keys), do: Process.put(:fake_releases, keys)
  defp set_git_shas(shas), do: Process.put(:fake_git_shas, shas)

  # Builds release keys in the expected filename format:
  # <prefix><timestamp>-<sha>-<app>-<version>.tar.gz
  defp make_key(prefix, timestamp, sha, app, version \\ "0.1.0") do
    "#{prefix}#{timestamp}-#{sha}-#{app}-#{version}.tar.gz"
  end

  describe "list_releases/3" do
    test "returns empty list when no releases exist" do
      set_releases([])

      assert {:ok, []} === ReleaseLookup.list_releases("my_app", :qa, base_opts())
    end

    test "lists qa releases for app under qa/ prefix" do
      set_releases([
        make_key("qa/my_app/", 1_700_000_001, "abc1234", "my_app"),
        make_key("my_app/", 1_700_000_002, "def5678", "my_app")
      ])

      assert {:ok, releases} = ReleaseLookup.list_releases("my_app", :qa, base_opts())
      assert length(releases) === 1
      assert hd(releases).prefix === :qa
      assert hd(releases).sha === "abc1234"
    end

    test "lists prod releases for app under app/ prefix" do
      set_releases([
        make_key("qa/my_app/", 1_700_000_001, "abc1234", "my_app"),
        make_key("my_app/", 1_700_000_002, "def5678", "my_app")
      ])

      assert {:ok, releases} = ReleaseLookup.list_releases("my_app", :prod, base_opts())
      assert length(releases) === 1
      assert hd(releases).prefix === :prod
      assert hd(releases).sha === "def5678"
    end

    test "returns releases sorted newest-first by timestamp" do
      set_releases([
        make_key("qa/my_app/", 1_700_000_001, "aaa1111", "my_app"),
        make_key("qa/my_app/", 1_700_000_003, "ccc3333", "my_app"),
        make_key("qa/my_app/", 1_700_000_002, "bbb2222", "my_app")
      ])

      assert {:ok, [first, second, third]} = ReleaseLookup.list_releases("my_app", :qa, base_opts())
      assert first.sha === "ccc3333"
      assert second.sha === "bbb2222"
      assert third.sha === "aaa1111"
    end

    test "parses release struct fields correctly" do
      set_releases([make_key("qa/my_app/", 1_700_000_000, "abc1234", "my_app")])

      assert {:ok, [release]} = ReleaseLookup.list_releases("my_app", :qa, base_opts())
      assert release.sha === "abc1234"
      assert release.short_sha === "abc1234"
      assert release.timestamp === 1_700_000_000
      assert release.prefix === :qa
      assert String.contains?(release.key, "abc1234")
    end

    test "short_sha is first 7 chars of sha" do
      set_releases([make_key("qa/my_app/", 1_700_000_000, "abcdefg1234567", "my_app")])

      assert {:ok, [release]} = ReleaseLookup.list_releases("my_app", :qa, base_opts())
      assert release.short_sha === "abcdefg"
    end

    test "timestamp is nil when filename has no parseable timestamp" do
      set_releases(["qa/my_app/notimestamp-abc1234-my_app-0.1.0.tar.gz"])

      assert {:ok, [release]} = ReleaseLookup.list_releases("my_app", :qa, base_opts())
      assert is_nil(release.timestamp)
    end

    test "does not include releases from other apps" do
      set_releases([
        make_key("qa/other_app/", 1_700_000_001, "abc1234", "other_app"),
        make_key("qa/my_app/", 1_700_000_002, "def5678", "my_app")
      ])

      assert {:ok, releases} = ReleaseLookup.list_releases("my_app", :qa, base_opts())
      assert length(releases) === 1
      assert hd(releases).sha === "def5678"
    end

    test "propagates error from releases_impl" do
      defmodule ErrorReleases do
        def fetch_all_remote_releases(_opts) do
          {:error, ErrorMessage.failed_dependency("S3 unavailable")}
        end
      end

      assert {:error, _} =
               ReleaseLookup.list_releases("my_app", :qa,
                 Keyword.put(base_opts(), :releases_impl, ErrorReleases)
               )
    end
  end

  describe "filter_by_branch_history/3" do
    setup do
      set_releases([
        make_key("qa/my_app/", 1_700_000_003, "aaaaaaa", "my_app"),
        make_key("qa/my_app/", 1_700_000_002, "bbbbbbb", "my_app"),
        make_key("qa/my_app/", 1_700_000_001, "ccccccc", "my_app")
      ])

      :ok
    end

    test "keeps only releases whose sha appears in git history" do
      set_git_shas(["aaaaaaa", "ccccccc"])

      {:ok, releases} = ReleaseLookup.list_releases("my_app", :qa, base_opts())

      assert {:ok, filtered} = ReleaseLookup.filter_by_branch_history(releases, "main", base_opts())
      shas = Enum.map(filtered, & &1.sha)
      assert "aaaaaaa" in shas
      assert "ccccccc" in shas
      refute "bbbbbbb" in shas
    end

    test "returns empty list when no releases match git history" do
      set_git_shas(["zzzzzzz"])

      {:ok, releases} = ReleaseLookup.list_releases("my_app", :qa, base_opts())

      assert {:ok, []} = ReleaseLookup.filter_by_branch_history(releases, "main", base_opts())
    end

    test "returns unfiltered list when git impl errors" do
      set_git_shas([])

      {:ok, releases} = ReleaseLookup.list_releases("my_app", :qa, base_opts())

      opts = Keyword.put(base_opts(), :git_impl, FakeGitError)
      assert {:ok, filtered} = ReleaseLookup.filter_by_branch_history(releases, "main", opts)

      assert length(filtered) === 3
    end

    test "returns ok tuple even when releases list is empty" do
      set_git_shas(["aaaaaaa"])

      assert {:ok, []} = ReleaseLookup.filter_by_branch_history([], "main", base_opts())
    end

    test "filters using short_sha prefix match" do
      set_git_shas(["aaaaaaa"])

      releases = [
        %{
          sha: "aaaaaaa",
          short_sha: "aaaaaaa",
          timestamp: 1_700_000_000,
          key: "qa/my_app/1700000000-aaaaaaa-my_app-0.1.0.tar.gz",
          prefix: :qa
        }
      ]

      assert {:ok, [%{sha: "aaaaaaa"}]} =
               ReleaseLookup.filter_by_branch_history(releases, "main", base_opts())
    end
  end

  describe "resolve_sha/4 — :auto strategy" do
    test "returns newest release sha on the branch" do
      set_releases([
        make_key("qa/my_app/", 1_700_000_003, "newest11", "my_app"),
        make_key("qa/my_app/", 1_700_000_001, "oldest11", "my_app")
      ])
      set_git_shas(["newest11", "oldest11"])

      assert {:ok, sha} = ReleaseLookup.resolve_sha("my_app", :qa, :auto, base_opts())
      assert sha === "newest11"
    end

    test "falls back to unfiltered newest when branch filter produces empty list" do
      set_releases([
        make_key("qa/my_app/", 1_700_000_003, "notinbr1", "my_app"),
        make_key("qa/my_app/", 1_700_000_001, "notinbr2", "my_app")
      ])
      set_git_shas([])

      assert {:ok, sha} = ReleaseLookup.resolve_sha("my_app", :qa, :auto, base_opts())
      assert sha === "notinbr1"
    end

    test "returns not_found error when no releases exist at all" do
      set_releases([])

      assert {:error, %ErrorMessage{code: :not_found}} =
               ReleaseLookup.resolve_sha("my_app", :qa, :auto, base_opts())
    end

    test "works for prod release_type" do
      set_releases([make_key("my_app/", 1_700_000_001, "prodsha1", "my_app")])
      set_git_shas(["prodsha1"])

      assert {:ok, "prodsha1"} =
               ReleaseLookup.resolve_sha("my_app", :prod, :auto, base_opts())
    end
  end

  describe "resolve_sha/4 — :prompt strategy" do
    test "returns sha directly when only one release exists" do
      set_releases([make_key("qa/my_app/", 1_700_000_001, "onlyone1", "my_app")])
      set_git_shas(["onlyone1"])

      assert {:ok, "onlyone1"} =
               ReleaseLookup.resolve_sha("my_app", :qa, :prompt, base_opts())
    end

    test "returns not_found error when no releases exist" do
      set_releases([])

      assert {:error, %ErrorMessage{code: :not_found}} =
               ReleaseLookup.resolve_sha("my_app", :qa, :prompt, base_opts())
    end
  end

  describe "DeployEx.ReleaseLookup.GitImpl" do
    test "module exists and exports list_shas_on_branch/2" do
      assert Code.ensure_loaded?(DeployEx.ReleaseLookup.GitImpl)
      assert function_exported?(DeployEx.ReleaseLookup.GitImpl, :list_shas_on_branch, 2)
    end
  end
end
