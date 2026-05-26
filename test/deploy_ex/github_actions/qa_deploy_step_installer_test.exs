defmodule DeployEx.GitHubActions.QaDeployStepInstallerTest do
  use ExUnit.Case, async: true

  alias DeployEx.GitHubActions.QaDeployStepInstaller

  @fixtures_root Path.expand("../../support/fixtures/workflows/installer", __DIR__)

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "qa_deploy_step_installer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "install/1" do
    test "inserts QA deploy step and ansible.deploy guard on fresh workflow", %{tmp_dir: tmp_dir} do
      path = copy_fixture("fresh.yml", tmp_dir)

      assert {:ok,
              %{
                qa_step: :inserted,
                ansible_guard: :inserted,
                qa_apps: [],
                anchor: {:upload_step, "mix deploy_ex.upload"}
              }} === QaDeployStepInstaller.install(path)

      contents = File.read!(path)

      assert contents =~ "# deploy_ex:qa-deploy:begin"
      assert contents =~ "# deploy_ex:qa-deploy:end"
      assert contents =~ "- name: Deploy to QA Nodes"
      assert contents =~ "mix deploy_ex.qa.deploy"
      assert contents =~ "--git-branch"
      assert contents =~ "# deploy_ex:qa-apps:"
      assert contents =~ "for app in"
      assert contents =~ "# deploy_ex:qa-skip"
      assert contents =~ ~r/Run Ansible Deploy.*\n\s+if: .*startsWith.*qa\//s
    end

    test "is idempotent — second run is no-op", %{tmp_dir: tmp_dir} do
      path = copy_fixture("fresh.yml", tmp_dir)

      {:ok, _} = QaDeployStepInstaller.install(path)
      first_run = File.read!(path)

      assert {:ok,
              %{
                qa_step: :already_installed,
                ansible_guard: :already_installed,
                qa_apps: [],
                anchor: nil
              }} === QaDeployStepInstaller.install(path)

      assert File.read!(path) === first_run
    end

    test "inserts QA step but reports no ansible guard when no ansible.deploy step", %{
      tmp_dir: tmp_dir
    } do
      path = copy_fixture("no_ansible_deploy.yml", tmp_dir)

      assert {:ok,
              %{
                qa_step: :inserted,
                ansible_guard: :not_applicable,
                qa_apps: [],
                anchor: {:upload_step, "mix deploy_ex.upload"}
              }} === QaDeployStepInstaller.install(path)

      contents = File.read!(path)
      assert contents =~ "# deploy_ex:qa-deploy:begin"
      refute contents =~ "# deploy_ex:qa-skip"
    end

    test "skips ansible guard when step has a user-managed `if:` without marker", %{
      tmp_dir: tmp_dir
    } do
      path = copy_fixture("user_managed_if.yml", tmp_dir)

      assert {:ok,
              %{
                qa_step: :inserted,
                ansible_guard: :skipped_user_managed,
                qa_apps: [],
                anchor: {:upload_step, "mix deploy_ex.upload"}
              }} === QaDeployStepInstaller.install(path)

      contents = File.read!(path)
      assert contents =~ "# deploy_ex:qa-deploy:begin"
      assert contents =~ "github.actor != 'dependabot[bot]'"
      refute contents =~ "# deploy_ex:qa-skip"
    end

    test "tracks app names across re-installs and renders bash for-loop", %{tmp_dir: tmp_dir} do
      path = copy_fixture("fresh.yml", tmp_dir)

      assert {:ok, %{qa_step: :inserted, qa_apps: ["cfx_web"]}} =
               QaDeployStepInstaller.install(path, "cfx_web")

      assert File.read!(path) =~ "for app in cfx_web; do"

      assert {:ok, %{qa_step: :updated, qa_apps: ["cfx_web", "theta_data_api"]}} =
               QaDeployStepInstaller.install(path, "theta_data_api")

      contents = File.read!(path)
      assert contents =~ "# deploy_ex:qa-apps: cfx_web,theta_data_api"
      assert contents =~ "for app in cfx_web theta_data_api; do"

      assert {:ok, %{qa_step: :already_installed, qa_apps: ["cfx_web", "theta_data_api"]}} =
               QaDeployStepInstaller.install(path, "cfx_web")
    end

    test "tracked_apps/1 returns [] for fresh block without app_name", %{tmp_dir: tmp_dir} do
      path = copy_fixture("fresh.yml", tmp_dir)
      {:ok, _} = QaDeployStepInstaller.install(path)

      assert QaDeployStepInstaller.tracked_apps(path) === []
    end

    test "returns :unprocessable_entity when no deploy_ex.upload anchor present", %{
      tmp_dir: tmp_dir
    } do
      path = copy_fixture("no_anchor.yml", tmp_dir)
      original = File.read!(path)

      assert {:error, %ErrorMessage{code: :unprocessable_entity, message: msg}} =
               QaDeployStepInstaller.install(path)

      assert msg =~ "deploy_ex.upload"
      assert File.read!(path) === original
    end

    test "returns :not_found when workflow file does not exist" do
      missing = "/tmp/definitely_missing_#{System.unique_integer([:positive])}.yml"

      assert {:error, %ErrorMessage{code: :not_found}} =
               QaDeployStepInstaller.install(missing)
    end
  end

  describe "installed?/1" do
    test "true when both sentinels present", %{tmp_dir: tmp_dir} do
      path = copy_fixture("fresh.yml", tmp_dir)
      {:ok, _} = QaDeployStepInstaller.install(path)

      assert QaDeployStepInstaller.installed?(path)
    end

    test "false on a fresh workflow", %{tmp_dir: tmp_dir} do
      path = copy_fixture("fresh.yml", tmp_dir)
      refute QaDeployStepInstaller.installed?(path)
    end

    test "false on a missing file" do
      missing = "/tmp/missing_#{System.unique_integer([:positive])}.yml"
      refute QaDeployStepInstaller.installed?(missing)
    end
  end

  defp copy_fixture(name, tmp_dir) do
    src = Path.join(@fixtures_root, name)
    dest = Path.join(tmp_dir, name)
    File.cp!(src, dest)
    dest
  end
end
