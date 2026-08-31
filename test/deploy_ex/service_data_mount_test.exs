defmodule DeployEx.ServiceDataMountTest do
  use ExUnit.Case, async: true

  # The four unit artefacts below all write to /data, which is mounted by
  # cloud-init's prepare-ebs-volume.sh (priv/terraform/modules/aws-instance/
  # cloud_init_data.yaml.tftpl), not by any ansible role — see
  # docs/superpowers/plans/d5-backlog/mount-mechanism.md. That script can
  # exit cleanly with /data unmounted (prepare-ebs-volume.sh:283, device
  # never appears within the wait), and none of these units declared a
  # mount dependency, so a service could start writing into a bare root
  # directory that /data later shadows once the real mount lands.
  #
  # This suite pins RequiresMountsFor=/data + After=local-fs.target on all
  # four artefacts (MEASURED, item C of the combined mount lane), preserves
  # each file's pre-existing After= tokens (append, not replace), and pins
  # that the dead, uncopied files/redis.service sibling is left untouched —
  # covered via raw content assertions, same exemption/pattern as
  # test/deploy_ex/mimir_role_test.exs.

  @priv_roles_dir Path.expand("../../priv/ansible/roles", __DIR__)

  @artefacts [
    {"prometheus.service.j2", Path.join(@priv_roles_dir, "prometheus_db/templates/prometheus.service.j2"), []},
    {"loki_systemd.service.j2", Path.join(@priv_roles_dir, "grafana_loki/templates/loki_systemd.service.j2"),
     ["network.target"]},
    {"mimir_systemd.service.j2", Path.join(@priv_roles_dir, "mimir_db/templates/mimir_systemd.service.j2"),
     ["network.target"]},
    {"redis-stack.service", Path.join(@priv_roles_dir, "redis_server/files/redis-stack.service"), ["network.target"]}
  ]

  @dead_redis_service_path Path.join(@priv_roles_dir, "redis_server/files/redis.service")
  @dead_redis_service_baseline """
  [Unit]
  Description=Redis In-Memory Data Store
  Documentation=https://redis.io/
  After=network.target

  [Service]
  Type=simple
  User=root
  Group=root
  ExecStart=/usr/bin/redis-server /etc/redis/redis.conf
  PIDFile=/run/redis/redis-server.pid
  TimeoutStartSec=120
  TimeoutStopSec=120
  Restart=always
  RestartSec=5
  LimitNOFILE=65535
  WorkingDirectory=/data
  UMask=0077

  [Install]
  WantedBy=multi-user.target
  """

  defp extract_unit_section(content) do
    [_before, rest] = String.split(content, "[Unit]", parts: 2)
    [unit_section | _after] = String.split(rest, "\n[", parts: 2)
    unit_section
  end

  # SECTION: item C — units must not start before /data is mounted

  describe "service units — RequiresMountsFor=/data" do
    for {name, path, prior_after_tokens} <- @artefacts do
      test "#{name} declares RequiresMountsFor=/data and After=local-fs.target" do
        unit_section = unquote(path) |> File.read!() |> extract_unit_section()

        assert unit_section =~ "RequiresMountsFor=/data"
        assert unit_section =~ ~r/After=.*local-fs\.target/

        for token <- unquote(prior_after_tokens) do
          assert unit_section =~ token
        end
      end
    end
  end

  describe "redis_server — dead files/redis.service left untouched" do
    test "the uncopied redis.service sibling is byte-identical to its pre-lane content" do
      assert File.read!(@dead_redis_service_path) === @dead_redis_service_baseline
    end

    test "no task in the role copies files/redis.service (confirms it stays dead, out of scope)" do
      tasks_content = File.read!(Path.join(@priv_roles_dir, "redis_server/tasks/main.yaml"))

      refute tasks_content =~ "src: redis.service\n"
    end
  end
end
