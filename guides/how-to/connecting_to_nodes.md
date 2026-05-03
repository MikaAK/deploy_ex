# How to Connect to Nodes

## Authorize SSH First

By default, SSH ingress is locked down. Whitelist your current IP:

```bash
mix deploy_ex.ssh.authorize                       # add current IP to security group
mix deploy_ex.ssh.authorize --remove              # remove when done
mix deploy_ex.ssh.authorize --ip 1.2.3.4          # add a specific IP
mix deploy_ex.ssh.authorize --remove --ip 1.2.3.4
```

Pass `--security-group-id <id>` to bypass auto-discovery. To turn this safeguard off entirely, edit `deploys/terraform/network.tf` and add `ssh-tcp` back to the public ingress list.

## SSH Into an Instance

App name can be a partial match — deploy_ex regex-matches it against instance tags.

```bash
mix deploy_ex.ssh my_app                          # interactive picker if multiple instances
mix deploy_ex.ssh my_app --root                   # SSH and `sudo -i` to root
mix deploy_ex.ssh my_app -i 0                     # connect to nth instance (0-indexed)
mix deploy_ex.ssh my_app --qa                     # restrict picker to QA nodes
mix deploy_ex.ssh my_app --list                   # list instances, don't connect
mix deploy_ex.ssh my_app --short                  # print the ssh command, don't run it
mix deploy_ex.ssh my_app --pem ./deploys/terraform/key.pem
mix deploy_ex.ssh my_app --instance-id i-0abc123
```

`--directory` (`-d`, default `./deploys/terraform`) controls where the PEM is searched.

## Eval Pattern (one-liner SSH)

`--short` (`-s`) prints the ssh command instead of running it, so you can wrap it in `eval` for shell aliases or scripts:

```bash
eval "$(mix deploy_ex.ssh -s my_app)"             # SSH directly
eval "$(mix deploy_ex.ssh -s --root my_app)"      # as root
eval "$(mix deploy_ex.ssh -s --log my_app)"       # tail logs
eval "$(mix deploy_ex.ssh -s --iex my_app)"       # remote IEx
```

## Utility Aliases

Wrap the eval pattern in a function so you can `my-app-ssh app_name --log` from anywhere.

**Bash:**

```bash
alias my-app-ssh='pushd ~/Documents/path/to/project >/dev/null && mix compile --quiet && eval "$(mix deploy_ex.ssh -s $@)" && popd >/dev/null'
```

**Fish:**

```fish
function my-app-ssh
  pushd ~/Documents/path/to/project &&
  set ssh_command (mix deploy_ex.ssh $argv -s) &&
  eval $ssh_command &&
  popd
end
```

## View Logs

```bash
mix deploy_ex.ssh my_app --log                    # journalctl -u <app> in follow mode
mix deploy_ex.ssh my_app --log -n 200             # last 200 lines
mix deploy_ex.ssh my_app --log --all              # entire journal (no limit)
mix deploy_ex.ssh my_app --log --log-user ubuntu  # use a non-root journalctl user
```

## Remote IEx Console

```bash
mix deploy_ex.ssh my_app --iex                    # bin/<app> remote — attaches to the running BEAM
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

mix deploy_ex.instance.status my_app                              # full instance dashboard
mix deploy_ex.instance.health                                     # AWS system + instance status checks
mix deploy_ex.instance.health --qa
mix deploy_ex.load_balancer.health                                # ELB target group health
mix deploy_ex.load_balancer.health --watch                        # live dashboard, refresh every 5s
```

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Troubleshooting → SSH](troubleshooting.md#setup--connectivity)
