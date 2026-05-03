# How to Connect to Nodes

## Authorize SSH Access First

```bash
mix deploy_ex.ssh.authorize                       # add current IP to security group
mix deploy_ex.ssh.authorize --remove              # remove current IP
mix deploy_ex.ssh.authorize --ip 1.2.3.4          # add specific IP
mix deploy_ex.ssh.authorize --remove --ip 1.2.3.4
```

Security group is auto-discovered (or set `--security-group-id <id>`).

## SSH Into an Instance

```bash
mix deploy_ex.ssh my_app                          # interactive picker if multiple instances
mix deploy_ex.ssh my_app --root                   # SSH and `sudo -i` to root
mix deploy_ex.ssh my_app -i 0                     # connect to nth instance (0-indexed)
mix deploy_ex.ssh my_app --qa                     # restrict picker to QA nodes
mix deploy_ex.ssh my_app --list                   # just list instances, don't connect
mix deploy_ex.ssh my_app --short                  # output the ssh command, don't run it
mix deploy_ex.ssh my_app --pem ./deploys/terraform/key.pem
mix deploy_ex.ssh my_app --instance-id i-0abc123
```

`--directory` (`-d`, default `./deploys/terraform`) controls where the PEM is searched.

## View Logs

```bash
mix deploy_ex.ssh my_app --log                    # journalctl -u <app> in follow mode
mix deploy_ex.ssh my_app --log -n 200             # last 200 lines
mix deploy_ex.ssh my_app --log --all              # entire journal (no limit)
mix deploy_ex.ssh my_app --log --log-user ubuntu  # use a non-root journalctl user
```

## Remote IEx Console

```bash
mix deploy_ex.ssh my_app --iex                    # `bin/<app> remote` to attach to the running BEAM
```

## Find and Select Nodes

```bash
mix deploy_ex.find_nodes                                          # list every managed instance
mix deploy_ex.find_nodes --tag Environment=production --tag App=my_app
mix deploy_ex.find_nodes --setup-complete                         # only fully-configured nodes
mix deploy_ex.find_nodes --setup-incomplete                       # nodes still pending ansible.setup
mix deploy_ex.find_nodes --format ids                             # newline-separated instance IDs
mix deploy_ex.find_nodes --format json

mix deploy_ex.select_node my_app                                  # interactive picker, prints IP
mix deploy_ex.select_node my_app --short                          # script-friendly output
mix deploy_ex.select_node --qa                                    # QA nodes only

mix deploy_ex.instance.status                                     # instance dashboard
mix deploy_ex.instance.health                                     # AWS system+instance status checks
mix deploy_ex.instance.health --qa
mix deploy_ex.load_balancer.health                                # ELB target group health
mix deploy_ex.load_balancer.health --watch                        # live dashboard, refresh every 5s
```

See also: [Mix Tasks Reference](../reference/mix_tasks.md)
