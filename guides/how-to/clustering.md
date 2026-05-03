# How to Cluster Your Nodes

deploy_ex tags every instance with `Group` and `InstanceGroup`, which integrates with [`libcluster_ec2_tag_strategy`](https://github.com/MikaAK/libcluster_ec2_tag_strategy) to discover cluster members at runtime.

## Add the Library

```elixir
# mix.exs
def deps do
  [
    {:libcluster, "~> 3.3"},
    {:libcluster_ec2_tag_strategy, "~> 0.1"}
  ]
end
```

## Configure Topologies

deploy_ex uses the project name in the `Group` tag — for `learn_elixir`, the tag value is `Learn Elixir Backend`.

```elixir
config :libcluster,
  topologies: [
    my_app_backend: [
      strategy: Cluster.Strategy.EC2Tag,
      config: [
        tag_name: "Group",
        tag_value: "<MY APP> Backend"
      ]
    ],

    # Multiple clusters with different InstanceGroup values:
    my_app_secondary: [
      strategy: Cluster.Strategy.EC2Tag,
      config: [
        tag_name: "Group",
        tag_value: "<MY APP> Backend Secondary"
      ]
    ]
  ]
```

The strategy queries EC2 for instances with the matching tag and adds them to the BEAM cluster automatically. New autoscaled instances join on boot; terminated instances drop out.

## Verify Cluster Health

```bash
mix deploy_ex.ssh <app> --iex
# Inside IEx:
Node.list()
```

You should see every other node in the same `Group`.

## Common Pitfalls

- **Different `aws_resource_group` values across apps** — the `Group` tag follows `aws_resource_group`. Make sure every app you want clustered is in the same resource group.
- **Security group blocks BEAM ports** — the default deploy_ex SG allows VPC-internal traffic, which covers EPMD (`4369`) and dynamic distribution ports. If you tighten the SG, leave VPC-internal allowed.
- **Node naming mismatch** — `libcluster` connects nodes by `nodename@<ip>`. Make sure your release config uses `RELEASE_NODE` with an IP-based hostname (deploy_ex's default Ansible role does this automatically).

See also: [Architecture — clustering tags](../explanation/architecture.md) | [Troubleshooting → Instances aren't joining the cluster](troubleshooting.md#autoscaling)
