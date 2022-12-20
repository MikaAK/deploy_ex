# DeployEx (WIP THIS IS NOT AVAILABLE IN HEX)
*Important: This requires Terraform and Ansible to be installed to use the commands*

This library allows you to add deployment to your umbrella application using AWS EC2, Ansible and Terraform

By default it uses `t3.nano` nodes but this can be changed in `./deploys/terraform/modules/aws-instance/variables.tf`
Once the files are generated, you can manage all files yourself, and we'll attempt to inject the variables in upon
reruns of the build commands.

## Legend
- [Package Installation](https://github.com/MikaAK/deploy_ex#installation)
- [Basic TL;DR Installation](https://github.com/MikaAK/deploy_ex#tldr-installation)
  - [Usage with Github Actions](https://github.com/MikaAK/deploy_ex#usage-with-github-actions)
  - [Usage with Deploy Node](https://github.com/MikaAK/deploy_ex#usage-with-deploy-node)
  - [Changes Over Time](https://github.com/MikaAK/deploy_ex#changes-over-time)
- [Commands](https://github.com/MikaAK/deploy_ex#changes-over-time)
- [Univiersal Options](https://github.com/MikaAK/deploy_ex#universial-options)
- [Terraform Variables](https://github.com/MikaAK/deploy_ex#terraform-variables)
- [Connecting to Your Nodes](https://github.com/MikaAK/deploy_ex#connecting-to-your-nodes)
  - [Connecting to Node as Root](https://github.com/MikaAK/deploy_ex#connection-to-node-as-root)
  - [Connecting to App Logs](https://github.com/MikaAK/deploy_ex#connecting-to-app-logs)
  - [Connecting to Remote IEx](https://github.com/MikaAK/deploy_ex#connecting-to-remote-iex)
  - [Writing a utility command](https://github.com/MikaAK/deploy_ex#writing-a-utility-command)
- [Monitoring](https://github.com/MikaAK/deploy_ex#monitoring)
  - [Setting up Grafana UI](https://github.com/MikaAK/deploy_ex#setting-up-grafana-ui)
  - [Setting up Loki for Logging](https://github.com/MikaAK/deploy_ex#setting-up-loki-for-logging)
  - [Setting up Prometheus for Metrics (WIP)](https://github.com/MikaAK/deploy_ex#setting-up-prometheus-for-metrics)
  - [Setting up Sentry for Error Capturing (WIP)](https://github.com/MikaAK/deploy_ex#setting-up-sentry-for-error-capturing)
- [Extra Utilities](https://github.com/MikaAK/deploy_ex#extra-utilities)
  - [Github Action](https://github.com/MikaAK/deploy_ex#github-action)
  - [Clustering](https://github.com/MikaAK/deploy_ex#clustering)
- [Credits](https://github.com/MikaAK/deploy_ex#credits)
- [Troubleshooting](https://github.com/MikaAK/deploy_ex#troubleshooting)

## Installation

*NOTE*: Currently this app is in development as you need to commit your AWS key into `deploys/ansible/group_vars/all.yaml`.
There are a few variables to be set in here. Once all of these can be dealt with automatically and rollbacks are implemented we will release a 0.1.0

#### Pre-requisite
You will need to make sure to have `ansible`, `terraform` & `git` available

[Available in Hex](https://hex.pm/deploy_ex), the package can be installed
by adding `deploy_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:deploy_ex, "~> 0.1"}
  ]
end
```

Documentation is published on [HexDocs](https://hexdocs.pm/deploy_ex)

If you want to use aws-cli credentials from the machine you're running initial setup on,
you can use the `--auto_pull_aws` of `-a` flag to pull the aws credentials into the
remote machines

## TL;DR Installation
Make sure you have your `releases` configured in your root `mix.exs`. This command will only
function in the root of an umbrella app.

By default nodes will be generated for prometheus, grafana ui, grafana loki and sentry. To turn this
off pass the options when calling `deploy_ex.full_setup`, `terraform.build` or `ansible.build`:

- `no-prometheus`
- `no-grafana`
- `no-loki`
- `no-sentry`

***Note***: It's very important to make sure you add the `:tar` step to your releases, see [here](https://hexdocs.pm/mix/Mix.Tasks.Release.html#module-steps) for info
```bash
$ vi mix.exs # Add {:deploy_ex, "~> 0.1"}
$ mix deps.get
$ mix deploy_ex.full_setup -yak # generate files & run inital setup
$ mix deploy_ex.install_github_action
$ git add . && git commit -m "chore: add deployment"
```
Once you do this, go to Github and set a few Secrets:

- `DEPLOY_EX_AWS_ACCESS_KEY_ID`
- `DEPLOY_EX_AWS_SECRET_ACCESS_KEY`
- `EC2_PEM_FILE` - You can get this by copying the pem file produced by `deploy_ex.full_setup`

Then we can start pushing to GitHub, every merge to `main` will trigger this
(set the branch in the `.github/workflows` if neededd)

We can connect to these nodes by runnin `mix deploy_ex.ssh node`, this will attempt to find a matching
node to the passed string and give you a command to connect to it, if you pass `--log` you'll get a command
to monitor it's logs remotely, and `--iex` will give you a command to connect to it using a iex shell

### Available Configuration

```
config :deploy_ex,
  aws_region: "us-west-2",
  aws_log_bucket: "#{String.replace(DeployExHelpers.underscored_app_name(), "_", "-")}-backend-logs-#{env()}",
  aws_release_bucket: "my-app-name-elixir-deploys-env"
  deploy_folder: "./deploys"
```

### Usage with Github Actions
***Note: This doesn't work properly with branch protections, to do
so you'll need to modify the GH action to bypass branch protections***

You can use this library with github actions to make for an easy deploy
pipeline, this way you can easily deploy to your nodes when you push
and is good for a quick setup

To set up this way you would run
- `mix deploy_ex.full_setup -y -k` - Sets up `./deploy` folder and terraform & ansible resources and skips running deployment
- `mix deploy_ex.install_github_action` - Adds a github action to your folder that will maintain terraform & ansible on push

### Usage with Deploy Node
- `mix deploy_ex.full_setup -y` - Sets up `./deploy` folder and terraform & ansible resources & commit this
- Set up a deploy node and load elixir & this reposity onto the repo
- When you want to do a deploy trigger this node to run `mix deploy_ex.upload` to load releases
- After releases are uploaded use `mix ansible.deploy` to re-deploy all releases


### Changes over time
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
- [x] `mix terraform.refresh` - Refreshes terraform state to pull new IPs and sync with AWS
- [x] `mix terraform.replace` - Replaces a resource within terraform, has fuzzy matching nodes
- [x] `mix terraform.drop` - Destroys all terraform built resources
- [x] `mix ansible.build` - Adds ansible files to the project, or rebuilds them
- [x] `mix ansible.ping` - Pings ansible nodes to see if they can connect
- [x] `mix ansible.setup` - Runs basic setup on the ansible nodes
- [x] `mix ansible.deploy` - Deploys to your nodes via ansible from uploaded S3 releases
- [ ] `mix ansible.rollback` - Rollback to a prior release

## Universial Options
Most of these are available on any command in DeployEx
- `aws-bucket` - Bucket to use for aws deploys
- `aws-region` - Bucket to use for aws deploys

## Terraform Variables
The main variables you'll want to know about are the ones inside `deploys/terraform/variables.tf`

Inside this file specifically the `my_app_project` variable is the most important.

The following options are present:

- `name` - Should aim not to touch this, it effects a lot of tags, if you do, make sure to modify the ansible files to match as the instance name itself is based on this
- `instance_count`- Number of instances to create for this app
- `instance_type` - The instance tier to use eg `t3.nano` or `t3.micro`
- `enable_eip` - Enable an Elastic IP from AWS giving this a static URL
- `enable_ebs` - Enable a secondary EBS Volume mounted on /data
- `instance_ebs_secondary_size` - Set the EBS Volume on /data size (default: 16GB)
- `enable_lb` - Enable a load balancer when there is more than one `instance_count`
- `elb_port` - Port for the load balancer to serve, this is the url you will hit
- `elb_instance_port` - Port for the load balancer to forward to, this is your application port
- `tags` - Tags specified in `Key=Value` format to add to the EC2 instance

There is also a default volume of 16gb created and mounted at the /data directory, you can change this in each specific app type if desired

## Connecting to your nodes
You can use `mix deploy_ex.ssh <app_name>` to connect to your nodes. By itself it will return the command, but can be
combined with eval using the `-s` flag

App name can be a partially complete form of app_name, so you can shorten it, and it will use a regex to find the match

#### Connection to Node
This command will connect to the node, you can use `--log` to view the logs, or `--iex` to connect to a remote iex shell

```bash
$ eval "$(mix deploy_ex.ssh -s app)"
```

#### Connection to Node as Root
```bash
$ eval "$(mix deploy_ex.ssh -s --root app)"
```

#### Connecting to App Logs
```bash
$ eval "$(mix deploy_ex.ssh -s --logs app)"
```

#### Connecting to Remote IEx
```bash
$ eval "$(mix deploy_ex.ssh -s --iex app)"
```

#### Writing a utility command
You can use this command like `my-app-ssh ap_nm --log` or `my-app-ssh app_name --iex` to get into a remote iex shell

Bash:
```bash
alias my-app-ssh='pushd ~/Documents/path/to/project && mix compile && eval "$(mix deploy_ex.ssh $@)" && popd'
```

Fish:
```fish
function my-app-ssh
  pushd ~/Documents/path/to/project &&
  mix compile &&
  eval "(mix deploy_ex.ssh $@)" &&
  popd
end
```

## Monitoring
Out of the box, deploy_ex will generate Prometheus (WIP), Grafana UI, Grafana Loki and Sentry (WIP) into the application

To use these however there are a few steps to getting started currently (this will change in the future so it's painless)

### Setting up Grafana UI
This one is pretty easy. It should just work out of the box on the `grafana_ui` app listed in `mix terraform.output`
If it's not you can deploy it by using `mix ansible.setup --only grafana_ui`

### Setting up Loki for Logging
This has a few setup requirements, we must first go into `deploys/ansible/group_vars/all.yaml` and change the following:

- `loki_logger_s3_region` - This should be set to the same logging region as the logging bucket from `mix terraform.output`
- `loki_logger_s3_bucket_name` - This should be set to the bucket name for logging from `mix terraform.output`
- `grafana_loki_url` - This should be set after running `mix terraform.apply`, it will need to be swapped to the instance id like so `http://i-00d30d1957d4b4f4c:3100`. Redeploy using `mix ansible.setup --only loki` to apply changes

### Setting up Prometheus for Metrics
(WIP)

### Setting up Sentry for Error Capturing
(WIP)

## Extra Utilities
- [x] - Easy Distribution (https://github.com/MikaAK/libcluster_ec2_tag_strategy)
- [ ] - Runs ansible setup on nodes created via github actions

### Github Action
***Note: This doesn't work properly with branch protections, to do
so you'll need to modify the GH action to bypass branch protections***

To install the github action run `mix deploy_ex.install_github_action`
This action requires a few variables to be set into the Secrets section in the repo settings

```
DEPLOY_EX_AWS_ACCESS_KEY_ID
DEPLOY_EX_AWS_SECRET_ACCESS_KEY
EC2_PEM_FILE
```

The EC2 PEM file will have been created initially when running `mix deploy_ex.full_setup`
or any form of `mix terraform.apply`

Once installed this github action will build releases, upload them to s3 and trigger
Ansible to run and deploy each node with the release

To load ENV Variables into the Build Environment from Github Actions Secrets, name the secret
in accordance to this pattern `__DEPLOY_EX__MY_ENV_VARIABLE` doing this will load `MY_ENV_VARIABLE`
as a environment variable in the build machine so it's available during compile


### Clustering
You can easily cluster your app with [this LibCluster Strategy](https://github.com/MikaAK/libcluster_ec2_tag_strategy) which
will read the EC2 tags from all instances and attempt to connect them. Because this library will tag resources with
`<APP_NAME> Backend`, so `learn_elixir` becomes `Learn Elixir Backend`, you can use a config similar to the following to
connect your nodes together with the strategy mentioned above:

```elixir
topologies = [
  my_app_background: [
    strategy: Cluster.Strategy.EC2Tag,
    config: [
      tag_name: "Group",
      tag_value: "<MY APP> Backend"
    ]
  ],

  my_app_second: [
    strategy: Cluster.Strategy.EC2Tag,
    config: [
      tag_name: "Group",
      tag_value: "<MY APP> Backend Secondary"
    ]
  ]
]

```

## Credits
Big thanks to @alevan for helping to figure out all the Ansible side of things and
providing a solid foundation for all the ansible files. This project wouldn't of been
possible without his help!!

## Troubleshooting
<details>
  <summary>Ansible throwing errors about not matching host patterns or you can't connect with `deploy_ex.ssh`</summary>

  Sometimes nodes change public ips, to refresh them you can run `mix terraform.refresh`

</details>

<details>
  <summary>I'm getting `SSH Too Many Authentication Failures`</summary>

  You can add `IdentitiesOnly=yes` to your `~/.ssh/config` `*` setting to clear that up.
  See [here for more details](https://www.tecmint.com/fix-ssh-too-many-authentication-failures-error/)

</details>

<details>
  <summary>I'm getting `Operation timed out` at the end of `mix deploy_ex.full_setup`</summary>

  Sometimes it takes longer to setup the nodes, please just retry `mix ansible.ping` in a few minutes

</details>

<details>
  <summary>How do I redeploy a node?</summary>

  All you need to do is run `mix ansible.deploy --only <app_name>` this will find all nodes
  that match the input and run a redeploy using the last release found in S3

</details>

<details>
  <summary>How can I replace a broken node??</summary>

  All we have to do is run `mix terraform replace <app_name>` if it's a specific services node
  add a `--node <number>` on to it to target that node number.

  We can then run `mix ansible.setup --only <app_name>` and `mix ansible.deploy --only <app_name>` to deploy these nodes

</details>

<details>
  <summary>Why are there so many tags on my EC2 node?</summary>

  Going to your EC2 node, you'll notice there are around 8 tags. These help you to manage costs
  since you can filter cost based off tags. Cloud Hosting is terrible for showing you
  cost allocation so using the tags you can roughly identify the cost of difference services

  `Group` for example aids in [clustering](https://github.com/MikaAK/deploy_ex#clustering)
  helping to register all the nodes in our application. This can be used to look at the costs
  for all the elixir specific backend services

  `InstanceGroup` on the other hand is seperated by services and will have all nodes under that
  one service or app, this can be used for billing to show you the cost of a specific service/app. This is also used for ansible playbooks to target specific node groups

  `MonitoringKey` is present on monitoring resources and helps playbooks to identify monitoring
  services

  `Vendor` is tagged between different vendor like Grafana or Sentry, internal ones will use Self to help identify vendor costs in billing

  `Type` We use this to seperate what the service is for or who it's by, in the case of
  monitoring we set this to `Monitoring` or in the case of self built apps this is set
  to `Self Made`. This helps to organize billing between costs to run metrics and costs to run
  the elixir apps

</details>

<details>
  <summary>What to do if monitoring is failing?</summary>

  First figure out what is failing, there are several monitoring systems running in the background:

  1) `promtail` - This is present on all app nodes, it tails the logs and exports them to loki
  2) `prometheus_exporter` - This is present on all app nodes, it scrapes metrics endpoints and exports them to prometheus
  2) `prometheus-server` - This is present on all `prometheus` nodes, it's the database for prometheus
  3) `grafana-server` - This is present on all `grafana_ui` node, it's the service for the interface
  4) `loki` - This is present on all `loki_log_aggregator` node, it's the service for the log aggregator

  Try restarting whichever is failing, and tailing the logs using `mix deploy_ex.ssh --log --all -n 50` to see if there are any
  errors with that service

</details>

<details>
  <summary>How can I restart a service without redeploying?</summary>

  Sometimes we need to restart a service but it doesn't need a full deploy, in this case we can
  ssh onto the server using our `mix deploy_ex.ssh --root app` command, and running `systemctl restart app_name`

</details>

<details>
  <summary>How can I uninstall??</summary>

  It's pretty easy, just run `mix deploy_ex.full_drop`, you can even add a `-y` to auto confirm
  any destructive actions. This will remove all built resources in AWS and delete the ./deploy folder
  from your application

</details>

<details>
  <summary>How can I run elixirs runtime in the cloud using `include_erts: false` with deploys and installing erlang on machine</summary>

  To do this you must use at least a `t3.small` node, you may have luck with smaller nodes or it may run out of memory. It's possible for the ansible task to also run out of memory (in which case it will complain the install Erlang step is non blocking) in which case you must ssh onto the node manually and run `asdf install erlang <version specified in ansible step>`

  In our `deploys/ansible/setup/<app_name>.yaml` we set a new role of `elixir-runner`

  In our `deploys/ansible/playbook/<app_name>.yaml` we modify it and add `extra_env`:
  ```
  - hosts: group_<app_name>
    vars:
      extra_env:
        - PATH=/root/.asdf/shims:/root/.asdf/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  ```

  Once this is done we can run `mix ansible.setup --only <app_name> && mix ansible.deploy --only <app_name>` to setup and deploy our code on the node

</details>

