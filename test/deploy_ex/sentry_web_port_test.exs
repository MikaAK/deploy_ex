defmodule DeployEx.SentryWebPortTest do
  use ExUnit.Case, async: true

  alias DeployEx.PrivRenderer

  # priv/ansible/roles/sentry_server/defaults/main.yaml pins the port Sentry's
  # container binds to (SENTRY_BIND in env.j2, and the role's own health check
  # in tasks/main.yaml). priv/ansible/group_vars/all.yaml.eex pins the
  # system.url-prefix placeholder every fresh consumer sees before their first
  # `mix terraform.apply`. The two used to agree at 9000; this suite pins both
  # at 80 AND pins that they agree with each other, so a future change to only
  # one of them fails loudly instead of silently reintroducing the mismatch.

  @sentry_role_dir Path.expand("../../priv/ansible/roles/sentry_server", __DIR__)
  @sentry_defaults_path Path.join(@sentry_role_dir, "defaults/main.yaml")

  defp sentry_web_port do
    @sentry_defaults_path
    |> YamlElixir.read_from_file!()
    |> Map.fetch!("sentry_web_port")
  end

  defp render_group_vars(opts \\ []) do
    {:ok, temp_dir} = PrivRenderer.render_to_temp(Keyword.put_new(opts, :environment, "dev"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)
    File.read!(Path.join(temp_dir, "ansible/group_vars/all.yaml"))
  end

  defp sentry_url_from(group_vars_content) do
    [_, url] = Regex.run(~r/^sentry_url: "(.+)"$/m, group_vars_content)
    url
  end

  # SECTION: D1 — sentry_server role default

  describe "sentry_server role default — sentry_web_port" do
    test "defaults to 80" do
      assert sentry_web_port() === 80
    end
  end

  # SECTION: D2 — paired group_vars placeholder

  describe "sentry_url group_vars placeholder" do
    test "renders with port 80, FILL_IN_AFTER_FIRST_APPLY untouched" do
      content = render_group_vars()

      assert sentry_url_from(content) === "http://FILL_IN_AFTER_FIRST_APPLY:80"
    end
  end

  # SECTION: Done criterion 4 — the agreement test

  describe "sentry_url and sentry_web_port stay in agreement" do
    test "sentry_url's rendered port equals sentry_web_port's default" do
      content = render_group_vars()
      rendered_port = content |> sentry_url_from() |> URI.parse() |> Map.fetch!(:port)

      assert rendered_port === sentry_web_port()
    end
  end

  # SECTION: behavioural — SENTRY_BIND and the health check key off the same variable

  describe "env.j2 SENTRY_BIND and the role's own health check" do
    test "both interpolate {{ sentry_web_port }} — they cannot independently drift" do
      env_content = File.read!(Path.join(@sentry_role_dir, "templates/env.j2"))
      tasks_content = File.read!(Path.join(@sentry_role_dir, "tasks/main.yaml"))

      assert env_content =~ "SENTRY_BIND={{ ansible_default_ipv4.address }}:{{ sentry_web_port }}"
      assert tasks_content =~ "http://{{ ansible_default_ipv4.address }}:{{ sentry_web_port }}/_health/"
    end
  end
end
