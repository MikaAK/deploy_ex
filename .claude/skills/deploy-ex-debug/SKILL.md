---
name: deploy-ex-debug
description: "Use when something deployed via deploy_ex is broken and the cause is unknown — deploy failed, app won't start or crashes on boot, service down after deploy, instance unreachable, SSH refused or timing out, ansible errors or 'no hosts matched', health check failing, old version still running after deploy, autoscaled instance not joining the cluster, systemd 'Failed with result', or 'where are the logs'. This is for DIAGNOSIS. Once the cause is known, deploy-ex-ops has the commands to fix it. NOT for writing deploy_ex code (deploy-ex-dev) or generating infra (deploy-ex-infra)."
---

# Debugging deploy_ex Deployments

Diagnose before touching anything. **REQUIRED BACKGROUND:** superpowers:systematic-debugging — form a hypothesis, run the cheapest experiment that can falsify it. An elimination experiment that removes the *wrong* file proves nothing.

## On-node facts (where things actually are)

- Systemd unit is named after the app: `systemctl status my_app.service`
- Releases unpack under `/srv/` (previous release kept at `/srv/<app>.old`)
- `journalctl -u my_app` for the service's stdout — but **diagnose a daemon from its own log file, not systemd's**: `Failed with result 'protocol'` looks identical for a config parse error and a `Type=notify` mismatch. Redis/RabbitMQ/ClickHouse write their own logs under `/var/log/`.
- Release artifacts in S3: `{app}/{timestamp}-{sha}-{filename}.tar.gz`

## First moves

```bash
mix deploy_ex.instance.status my_app          # is the instance even up
mix deploy_ex.view_current_release my_app     # what SHA is running
mix deploy_ex.list_app_release_history my_app # what SHAs exist
mix deploy_ex.ssh my_app --log                # stream journalctl
mix deploy_ex.ssh my_app                      # get on the box
```

## Failure signatures

| Symptom | Likely cause | Check / fix |
|---------|--------------|-------------|
| Ansible "no hosts matched" / SSH can't find host | Public IP changed (stop/start without EIP) | `mix terraform.refresh` |
| SSH times out | Ingress locked to allowlist | `mix deploy_ex.ssh.authorize` (`--remove` when done) |
| SSH "Too Many Authentication Failures" | Agent offering too many keys | `IdentitiesOnly yes` in `~/.ssh/config` |
| `ansible.setup` hangs forever | `/tmp` full (Debian 13 small nodes) | SSH as root, `df -h`, clear `/tmp` |
| `full_setup` ends "Operation timed out" | Node still initializing | Wait, re-run `mix ansible.ping` |
| Old version still running after deploy | Wrong SHA targeted, or artifact missing | Compare `view_current_release` vs `list_app_release_history`; check S3 artifact exists; redeploy with `--target-sha` |
| `ansible.build` exits 0 but templates stale | Overwrite prompt silently skipped (non-TTY) | Re-run with `--force` |
| App crashes instantly, unit restarts loop | Config/env problem — read the crash, not the restart | `journalctl -u app -n 200`; check `__DEPLOY_EX__` secrets landed; look for `erl_crash.dump` under `/srv/` |
| BEAM segfaults on start | Release built on wrong arch (qemu emulation) | Rebuild on target arch; release must bundle ERTS |
| Autoscaled instance runs wrong version / won't join cluster / user-data failed | See `guides/how-to/troubleshooting.md` § Autoscaling | `/var/log/cloud-init-output.log` on the instance |
| Terraform drift on `desired_capacity` | Autoscaler changed it outside terraform | Expected — see troubleshooting guide |
| App up but unreachable from outside | Security group / (OCI: host firewall or security list) | `mix deploy_ex.load_balancer.health`; on OCI use deploy-ex-oci |

## Escalation ladder

1. Read the failing thing's own log (not just its supervisor's).
2. Reproduce the smallest failing step (`ansible.deploy --only app`, single task, curl from the node itself).
3. Node-local vs network: does it work via `curl localhost:PORT` on the box? Then it's security groups/firewall/LB, not the app.
4. Broken node and cause found but node state suspect: `mix deploy_ex.remake my_app` replaces + redeploys it.

Full symptom catalogue: `guides/how-to/troubleshooting.md`. Monitoring checks: `guides/how-to/monitoring.md`. OCI-specific traps: use the deploy-ex-oci skill.
