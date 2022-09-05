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

If you want to use aws-cli credentials from the machine you're running initial setup on,
you can use the `--auto_pull_aws` of `-a` flag to pull the aws credentials into the
remote machines

#### Usage with Github Actions (WIP)
You can use this library with github actions to make for an easy deploy
pipeline, this way you can easily deploy to your nodes when you push
and is good for a quick setup

To set up this way you would run
- `mix deploy_ex.full_setup -y -k` - Sets up `./deploy` folder and terraform & ansible resources and skips running deployment
- `mix deploy_ex.install_github_action` - Adds a github action to your folder that will maintain terraform & ansible on push

#### Usage with Deploy Node
- `mix deploy_ex.full_setup -y` - Sets up `./deploy` folder and terraform & ansible resources & commit this
- Set up a deploy node and load elixir & this reposity onto the repo
- When you want to do a deploy trigger this node to run `mix deploy_ex.upload` to load releases
- After releases are uploaded use `mix ansible.deploy` to re-deploy all releases


#### Changes over time
Because the terraform and ansible files are generated directly into your application, you own these files.
You can make changes to ansible and terraform files as you see fit. In the case of terraform, it will automatically
inject the apps into your variables file despite changes to the file. If you change terraform, make sure to run `mix terraform.apply`


## Commands
- [x] `mix deploy_ex.full_setup` - Runs all the commands to initialize and setup your project
- [x] `mix deploy_ex.full_drop` - Runs all the commands to drop and remove the `./deploy` folder
- [x] `mix deploy_ex.upload` - Deploys your `mix release` to s3
- [x] `mix deploy_ex.install_github_action` - Deploys your `mix release` to s3
- [x] `mix deploy_ex.ssh` - Gets the ssh command for a specific node
- [x] `mix terraform.build` - Add the terraform files to project, or rebuilds them
- [x] `mix terraform.apply` - Applies terraform changes
- [x] `mix terraform.drop` - Destroys all terraform built resources
- [x] `mix ansible.build` - Adds ansible files to the project, or rebuilds them
- [x] `mix ansible.ping` - Pings ansible nodes to see if they can connect
- [x] `mix ansible.setup` - Runs basic setup on the ansible nodes
- [x] `mix ansible.deploy` - Deploys to your nodes via ansible from uploaded S3 releases
- [ ] `mix ansible.rollback` - Rollback to a prior release

## Extra Utilities
- [ ] - Volumes
- [ ] - Easy Distribution
- [ ] - Github Actions as Terraform Remote Server


### Credits
Big thanks to @alevan for helping to figure out all the Ansible side of things and
providing a solid foundation for all the ansible files. This project wouldn't of been
possible without his help!!

### Troubleshooting

<details>
  <summary>I'm getting `SSH Too Many Authentication Failures`</summary>

  You can add `IdentitiesOnly=yes` to your `~/.ssh/config` `*` setting to clear that up.
  See [here for more details](https://www.tecmint.com/fix-ssh-too-many-authentication-failures-error/)

</details>

<details>
  <summary>I'm getting `Operation timed out` at the end of `mix deploy_ex.full_setup`</summary>

  Sometimes it takes longer to setup the nodes, please just retry `mix ansible.ping` in a few minutes

</details>


