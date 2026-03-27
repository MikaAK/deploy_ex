# How to Use QA Nodes

Ephemeral EC2 instances for testing specific release SHAs.

## Create a QA Node

```bash
mix deploy_ex.qa.create my_app --sha abc1234
mix deploy_ex.qa.create my_app --sha abc1234 --attach-lb   # with load balancer
```

QA nodes reuse app-specific AMIs when available (skips Ansible setup). State is persisted to S3.

## Deploy a Different SHA

```bash
mix deploy_ex.qa.deploy my_app --sha def5678
```

## Manage Load Balancer

```bash
mix deploy_ex.qa.attach_lb my_app    # route traffic to QA node
mix deploy_ex.qa.detach_lb my_app    # stop traffic
```

## List and Clean Up

```bash
mix deploy_ex.qa.list                # list all QA nodes
mix deploy_ex.qa.destroy my_app      # terminate
mix deploy_ex.qa.destroy --all       # terminate all
mix deploy_ex.qa.cleanup             # remove terminated from S3 state
```

See also: [Mix Tasks Reference](../reference/mix_tasks.md)
