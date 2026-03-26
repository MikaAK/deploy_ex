defmodule DeployEx.ProjectContextTest do
  use ExUnit.Case, async: true

  alias DeployEx.ProjectContext

  defmodule FakeUmbrellaMixProject do
    def umbrella?, do: true
    def get, do: __MODULE__

    def project,
      do: [
        apps_path: "test/support/fake_apps",
        releases: [
          app_a: [applications: [app_a: :permanent]],
          app_b: [applications: [app_b: :permanent]]
        ]
      ]

    def apps_paths,
      do: %{app_a: "test/support/fake_apps/app_a", app_b: "test/support/fake_apps/app_b"}
  end

  defmodule FakeSingleAppMixProject do
    def umbrella?, do: false
    def get, do: __MODULE__
    def project, do: [app: :my_app]
    def apps_paths, do: %{}
  end

  defmodule FakeSingleAppWithReleasesMixProject do
    def umbrella?, do: false
    def get, do: __MODULE__

    def project,
      do: [
        app: :my_app,
        releases: [
          web: [applications: [my_app: :permanent]],
          worker: [applications: [my_app: :permanent]]
        ]
      ]

    def apps_paths, do: %{}
  end

  defmodule FakeMalformedMixProject do
    def umbrella?, do: false
    def get, do: __MODULE__
    def project, do: []
    def apps_paths, do: %{}
  end

  describe "type/1" do
    test "returns :umbrella for umbrella projects" do
      assert ProjectContext.type(FakeUmbrellaMixProject) === :umbrella
    end

    test "returns :single_app for non-umbrella projects" do
      assert ProjectContext.type(FakeSingleAppMixProject) === :single_app
    end
  end

  describe "apps/1" do
    test "returns app keys from apps_paths for umbrella" do
      assert ProjectContext.apps(FakeUmbrellaMixProject) === ["app_a", "app_b"]
    end

    test "returns single app name for single-app project" do
      assert ProjectContext.apps(FakeSingleAppMixProject) === ["my_app"]
    end

    test "returns single app name for single-app with explicit releases" do
      assert ProjectContext.apps(FakeSingleAppWithReleasesMixProject) === ["my_app"]
    end
  end

  describe "app_path/2" do
    test "returns the mapped path for umbrella app" do
      assert ProjectContext.app_path("app_a", FakeUmbrellaMixProject) ===
               "test/support/fake_apps/app_a"
    end

    test "returns File.cwd! for single-app" do
      assert ProjectContext.app_path("my_app", FakeSingleAppMixProject) === File.cwd!()
    end
  end

  describe "releases/1" do
    test "returns releases from mix.exs for umbrella" do
      {:ok, releases} = ProjectContext.releases(FakeUmbrellaMixProject)
      assert Keyword.has_key?(releases, :app_a)
      assert Keyword.has_key?(releases, :app_b)
    end

    test "returns releases from mix.exs for single-app with explicit releases" do
      {:ok, releases} = ProjectContext.releases(FakeSingleAppWithReleasesMixProject)
      assert Keyword.has_key?(releases, :web)
      assert Keyword.has_key?(releases, :worker)
    end

    test "synthesizes a release from :app key for single-app with no releases" do
      {:ok, releases} = ProjectContext.releases(FakeSingleAppMixProject)
      assert [{:my_app, opts}] = releases
      assert opts[:applications] === [my_app: :permanent]
    end

    test "returns error for malformed project with no :app key" do
      assert {:error, _} = ProjectContext.releases(FakeMalformedMixProject)
    end
  end

  describe "redeploy_config/2" do
    test "returns default RedeployConfig when no deploy_ex opts" do
      {:ok, config} = ProjectContext.redeploy_config(:app_a, FakeUmbrellaMixProject)
      assert %DeployEx.ReleaseUploader.RedeployConfig{} = config
    end
  end

  describe "check_valid_project/1" do
    test "returns :ok for umbrella project" do
      assert :ok === ProjectContext.check_valid_project(FakeUmbrellaMixProject)
    end

    test "returns :ok for valid single-app project" do
      assert :ok === ProjectContext.check_valid_project(FakeSingleAppMixProject)
    end

    test "returns error for malformed project" do
      assert {:error, _} = ProjectContext.check_valid_project(FakeMalformedMixProject)
    end
  end
end
