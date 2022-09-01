# DeployEx (WIP THIS IS NOT AVAILABLE IN HEX)
*Important: This requires Terraform and Ansible to be installed to use the commands*

This library allows you to add deployment to your umbrella application using AWS EC2, Ansible and Terraform


By default it uses `t3.nano` nodes but this can be changed in `./deploys/terraform/modules/aws-instance/variables.tf`


Use `mix terraform.build` from your umbrella root to add the `./deploys/terraform` folder
to the project. You can regenerate the root `variables.tf` & `main.tf` files at any time by running the command again and it'll inject the updates into the file
leaving any changes alone

When using `mix deploy_ex.upload` it's important to note, it will only upload releases when it finds a difference
in one of the following: release_app code, release_app local dependency changes or a dependency updates in the mix.lock


## Installation

#### Pre-requisite
You will need to make sure to have `ansible`, `terraform` & `git` available

[Available in Hex](https://hex.pm/deploy_ex), the package can be installed
by adding `deploy_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:deploy_ex, "~> 0.1.0"}
  ]
end
```

Documentation is published on [HexDocs](https://hexdocs.pm/deploy_ex)


## Commands
- [x] `mix deploy_ex.full_setup` - Runs all the commands to initialize and setup your project
- [x] `mix terraform.build` - Add the terraform files to project, or rebuilds them
- [x] `mix terraform.apply` - Applies terraform changes
- [x] `mix terraform.drop` - Destroys all terraform built resources
- [x] `mix ansible.build` - Adds ansible files to the project, or rebuilds them
- [x] `mix ansible.ping` - Pings ansible nodes to see if they can connect
- [ ] `mix ansible.setup` - Runs basic setup on the ansible nodes
- [ ] `mix ansible.deploy` - Deploys to your nodes via ansible from uploaded S3 releases
- [ ] `mix ansible.rollback` - Rollback to a prior release
- [x] `mix deploy_ex.upload` - Deploys your `mix release` to s3


### Troubleshooting

<details>
  <summary>I'm getting `SSH Too Many Authentication Failures`</summary>

  You can add `IdentitiesOnly=yes` to your `~/.ssh/config` `*` setting to clear that up.
  See [here for more details](https://www.tecmint.com/fix-ssh-too-many-authentication-failures-error/)

</details>

<details>
  <summary>I'm getting `Operation timed out` at the end of `mix deploy_ex.full_setup`</summary>

  You can add `IdentitiesOnly=yes` to your `~/.ssh/config` `*` setting to clear that up.
  See [here for more details](https://www.tecmint.com/fix-ssh-too-many-authentication-failures-error/)

</details>


