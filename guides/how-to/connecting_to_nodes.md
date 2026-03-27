# How to Connect to Nodes

## SSH

```bash
mix deploy_ex.ssh my_app              # interactive SSH
mix deploy_ex.ssh my_app --root       # SSH as root
mix deploy_ex.ssh my_app -i 2         # specific instance by index
mix deploy_ex.ssh my_app --qa         # QA nodes only
```

## View Logs

```bash
mix deploy_ex.ssh my_app --log        # stream app logs (journalctl)
```

## Remote IEx Console

```bash
mix deploy_ex.ssh my_app --iex        # connect to running app
```

## Authorize SSH Key

```bash
mix deploy_ex.ssh.authorize my_app    # add your SSH key to instances
```

## Find and Select Nodes

```bash
mix deploy_ex.find_nodes [--tag key=value] [--format table|json|ids]
mix deploy_ex.select_node             # interactive selection
mix deploy_ex.instance.status my_app  # instance dashboard
mix deploy_ex.instance.health         # health checks
```

See also: [Mix Tasks Reference](../reference/mix_tasks.md)
