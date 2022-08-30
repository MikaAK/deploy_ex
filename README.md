# DeployEx
This library allows you to add deployment to your umbrella application using AWS EC2, Ansible and Terraform


By default it uses `t3.nano` nodes but this can be changed in `./deploys/terraform/modules/aws-instance/variables.tf`


Use `mix terraform.build` from your umbrella root to add the `./deploys/terraform` folder
to the project. You can regenerate the root `variables.tf` & `main.tf` files at any time by running the command again and it'll inject the updates into the file
leaving any changes alone


## Installation

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
- [x] `mix terraform.build` - Add the terraform files to project, or rebuilds them
- [x] `mix terraform.apply` - Applies terraform changes
- [x] `mix terraform.drop` - Destroys all terraform built resources
- [x] `mix ansible.build` - Adds ansible files to the project, or rebuilds them
- [x] `mix ansible.ping` - Pings ansible nodes to see if they can connect
- [ ] `mix ansible.deploy` - Deploys to your nodes via ansible
- [ ] `mix build.deploy_ex` - Deploys your release to s3
