# DeployEx (WIP THIS IS NOT AVAILABLE IN HEX)
**NOTE:** [erlexec fails to compile](https://github.com/saleyn/erlexec/issues/189) in otp 26 making this library not work

*Important: This requires [Terraform](https://terraform.io) and [Ansible](https://www.ansible.com/) to be installed to use the commands*

This library allows you to add deployment to your umbrella application using AWS EC2, Ansible and Terraform

By default it uses `t3.nano` nodes but this can be changed in `./deploys/terraform/modules/aws-instance/variables.tf`
Once the files are generated, you can manage all files yourself, and we'll attempt to inject the variables in upon
reruns of the build commands.

Under the default commands you will gain the following services (all of which can be disabled easily to opt-out):
- [Redis](https://redis.com/)
- [Grafana UI](https://grafana.com/)
- [Grafana Loki](https://grafana.com/oss/loki/)
- [Prometheus](https://prometheus.io/)
- [Postgres](https://postgresql.org/)

## Legend
- [Package Installation](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#installation)
- [Basic TL;DR Installation](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#tldr-installation)
  - [Usage with Github Actions](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#usage-with-github-actions)
  - [Usage with Deploy Node](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#usage-with-deploy-node)
  - [Changes Over Time](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#changes-over-time)
  - [Multiple Phoenix Apps](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#multiple-phoenix-apps)
- [Redeploy Config](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#redeploy-config)
- [Commands](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#commands)
- [Univiersal Options](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#universial-options)
- [Terraform Variables](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#terraform-variables)
- [Autoscaling](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#autoscaling)
  - [Configuration](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#autoscaling-configuration)
  - [How It Works](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#how-autoscaling-works)
  - [Deployment Strategies](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#autoscaling-deployment-strategies)
  - [Commands](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#autoscaling-commands)
  - [Instance Setup](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#autoscaling-instance-setup)
  - [Connecting to Instances](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#connecting-to-autoscaled-instances)
- [QA Nodes](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#qa-nodes)
  - [Quick Start](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#quick-start-1)
  - [QA Node Commands](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#qa-node-commands)
  - [How QA Nodes Work](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#how-qa-nodes-work)
  - [QA Node Tags](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#qa-node-tags)
  - [Commands with QA Support](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#commands-with-qa-support)
- [Connecting to Your Nodes](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#connecting-to-your-nodes)
  - [Authorizing for SSH](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#authorizing-for-ssh)
  - [Connecting to Node as Root](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#connection-to-node-as-root)
  - [Connecting to App Logs](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#connecting-to-app-logs)
  - [Connecting to Remote IEx](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#connecting-to-remote-iex)
  - [Writing a utility command](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#writing-a-utility-command)
- [Monitoring](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#monitoring)
  - [Setting up Grafana UI](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#setting-up-grafana-ui)
  - [Setting up Loki for Logging](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#setting-up-loki-for-logging)
  - [Setting up Prometheus for Metrics](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#setting-up-prometheus-for-metrics)
  - [Setting up Sentry for Error Capturing (WIP)](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#setting-up-sentry-for-error-capturing)
- [Extra Utilities](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#extra-utilities)
  - [Github Action](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#github-action)
  - [Clustering](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#clustering)
- [Credits](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#credits)
- [Troubleshooting](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#troubleshooting)
- [Goals](https://github.com/MikaAK/deploy_ex?tab=readme-ov-file#goals)

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

All releases in the app must have a `:tar` step at the end of their `steps`

## TL;DR Installation
Make sure you have your `releases` configured in your root `mix.exs`. This command will only
function in the root of an umbrella app.

By default nodes will be generated for prometheus, grafana ui, grafana loki and sentry. To turn this
off pass the options when calling `deploy_ex.full_setup`, `terraform.build` or `ansible.build`:

- `no-prometheus`
- `no-grafana`
- `no-loki`
- `no-redis`
- `no-sentry`
- `no-database` - Disables PG database creation in AWS RDS

***Note***: It's very important to make sure you add the `:tar` step to your releases, see [here](https://hexdocs.pm/mix/Mix.Tasks.Release.html#module-steps) for info.

```bash
$ vi mix.exs # Add {:deploy_ex, "~> 0.1"}
$ mix deps.get
$ mix deploy_ex.full_setup -yak # generate files & run inital setup
$ mix deploy_ex.install_github_action
$ git add . && git commit -m "chore: add deployment"
```

***Note***: Make sure to take the ami when terraform is run and uncomment and insert it into `/deploys/terraform/ec2.tf` so that the AMI doesn't change ***FAILURE TO DO THIS WILL CAUSE MASS DEPLOYS VERY OFTEN***

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

```elixir
config :deploy_ex,
  aws_region: "us-west-2",
  aws_resource_group: "#{DeployExHelpers.project_name()} Backend",  # AWS "Group" tag for filtering instances
  aws_log_bucket: "#{String.replace(DeployExHelpers.underscored_project_name(), "_", "-")}-backend-logs-#{env()}",
  aws_release_bucket: "#{String.replace(DeployExHelpers.underscored_project_name(), "_", "-")}-elixir-deploys-{env}"
  aws_release_state_bucket: "#{String.replace(DeployExHelpers.underscored_project_name(), "_", "-")}-release-state-#{env}"
  deploy_folder: "./deploys",
  aws_names_include_env: false
```

**Configuration Options:**
- `aws_region` - AWS region for all operations (default: `"us-west-2"`)
- `aws_resource_group` - AWS "Group" tag value for filtering instances (default: `"#{ProjectName} Backend"`)
- `aws_log_bucket` - S3 bucket for logs
- `aws_release_bucket` - S3 bucket for release artifacts
- `aws_release_state_bucket` - S3 bucket for release state
- `deploy_folder` - Local folder for deployment files (default: `"./deploys"`)
- `aws_names_include_env` - Whether AWS resource names include the environment (e.g., `myapp-prod-sg` vs `myapp-sg`). Set to `true` if your Terraform creates resources with environment in the name. (default: `false`)

### Redeploy Config

You can control which file changes trigger a redeploy for each app within a release using the `redeploy_config` option under the `:deploy_ex` key in your release configuration. This is useful when a release bundles multiple apps but you only want certain file changes to trigger a rebuild.

Patterns are regex strings (or `~r` sigils) matched against file paths from `git diff --name-only`. Paths are relative to the repo root (e.g. `apps/my_app/lib/my_app.ex`), with no leading `/`.

#### Whitelist

Only redeploy when changed files match at least one whitelist pattern. All other changes (including config, root `mix.exs`, and dependency changes) are ignored for that app.

```elixir
releases: [
  my_web: [
    steps: [:assemble, :tar],
    deploy_ex: [
      redeploy_config: [my_service: [
        whitelist: [
          ~r/apps\/my_service\/lib\/my_service\.ex$/,
          ~r/apps\/my_service\/lib\/my_service\/critical_module\.ex$/
        ]
      ]]
    ],
    applications: [my_web: :permanent, my_service: :permanent]
  ]
]
```

In this example, the `my_web` release will only be rebuilt due to `my_service` changes if `my_service.ex` or `critical_module.ex` changed. Changes to other files inside `my_service` are ignored. The `my_web` app itself (which has no redeploy_config) still triggers on any change normally.

#### Blacklist

Ignore file changes matching blacklist patterns. If **all** changed files for an app match the blacklist, no redeploy is triggered for that app. If any non-blacklisted files also changed, normal redeploy logic applies. Dependency changes (mix.lock) still trigger redeployment.

```elixir
releases: [
  my_web: [
    steps: [:assemble, :tar],
    deploy_ex: [
      redeploy_config: [my_service: [
        blacklist: [
          ~r/apps\/my_service\/test\//,
          ~r/\.md$/
        ]
      ]]
    ],
    applications: [my_web: :permanent, my_service: :permanent]
  ]
]
```

In this example, test file and markdown changes inside `my_service` are ignored. Any other file change in `my_service` still triggers a redeploy.

#### Key Behaviors

- **Per-app scoping**: Each app within a release can have its own whitelist or blacklist. Apps without config use default behavior (any change triggers redeploy).
- **Whitelist suppresses dependency changes**: When an app has a whitelist, hex dependency changes (`mix.lock`) will not trigger a redeploy for that app.
- **Blacklist preserves dependency changes**: Hex dependency changes still trigger a redeploy for blacklisted apps.
- **Patterns are regexes**: Use `~r` sigils or string patterns (compiled via `Regex.compile!/1`).

### Usage with Github Actions
***Note: This doesn't work properly with branch protections, to do
so you'll need to modify the GH action to bypass branch protections***

You can use this library with github actions to make for an easy deploy
pipeline, this way you can easily deploy to your nodes when you push
and is good for a quick setup

To set up this way you would run
- `mix deploy_ex.full_setup -y -k` - Sets up `./deploy` folder and terraform & ansible resources and skips running deployment
- `mix deploy_ex.install_github_action` - Adds a github action to your folder that will maintain terraform & ansible on push

For more info see the [Github Actions Section](https://github.com/MikaAK/deploy_ex#github-action)

### Usage with Deploy Node
- `mix deploy_ex.full_setup -y` - Sets up `./deploy` folder and terraform & ansible resources & commit this
- Set up a deploy node and load elixir & this reposity onto the repo
- When you want to do a deploy trigger this node to run `mix deploy_ex.upload` to load releases
- After releases are uploaded use `mix ansible.deploy` to re-deploy all releases


### Changes over time
Because the terraform and ansible files are generated directly into your application, you own these files.
You can make changes to ansible and terraform files as you see fit. In the case of terraform, it will automatically
inject the apps into your variables file despite changes to the file. If you change terraform, make sure to run `mix terraform.apply`

### Multiple Phoenix Apps
In order to have multiple phoenix apps in the umbrella supported, we need to configure our
`:dart_sass`, `:tailwind` and `:esbuild` to support multiple apps by changing the key from default
to the key of each app and setting the proper `cd` and `NODE_PATH`

Example:
```
cd: Path.expand("../apps/learn_elixir_lander/assets", __DIR__),
env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
```

## Commands

### DeployEx Core
- `mix deploy_ex` - Lists all available deploy_ex commands
- `mix deploy_ex.full_setup` - Performs complete infrastructure and application setup using Terraform and Ansible
- `mix deploy_ex.full_drop` - Completely removes DeployEx configuration and files from the project
- `mix deploy_ex.install_github_action` - Installs GitHub Actions for automated infrastructure and deployment management
- `mix deploy_ex.install_migration_script` - Installs migration scripts for running Ecto migrations in releases
- `mix deploy_ex.release` - Builds releases for applications with detected changes
- `mix deploy_ex.upload` - Uploads your release folder to Amazon S3

### Application Management
- `mix deploy_ex.restart_app` - Restarts a specific application's systemd service
- `mix deploy_ex.restart_machine` - Restarts EC2 instances for a specific application
- `mix deploy_ex.remake` - Replaces and redeploys a specific application node
- `mix deploy_ex.stop_app` - Stops a specific application's systemd service
- `mix deploy_ex.start_app` - Starts a specific application's systemd service

### Connectivity & Inspection
- `mix deploy_ex.ssh` - SSH into a specific app's remote node
- `mix deploy_ex.ssh.authorize` - Add or remove SSH authorization to the internal network for specific IPs
- `mix deploy_ex.download_file` - Downloads a file from a remote server using SCP
- `mix deploy_ex.find_nodes` - Find EC2 instances by tags
- `mix deploy_ex.select_node` - Select an EC2 instance and output its instance ID

### Release Information
- `mix deploy_ex.list_app_release_history` - Lists the release history for a specific app from S3
- `mix deploy_ex.list_available_releases` - Lists all available releases uploaded to the release bucket
- `mix deploy_ex.view_current_release` - Shows the current (latest) release for a specific app from S3

### Instance & Load Balancer Health
- `mix deploy_ex.instance.status` - Displays instance status for an application
- `mix deploy_ex.instance.health` - Shows health status of EC2 instances
- `mix deploy_ex.load_balancer.health` - Check load balancer health status for all instances

### Autoscaling
- `mix deploy_ex.autoscale.status` - Displays autoscaling group status for an application
- `mix deploy_ex.autoscale.scale` - Manually set desired capacity of an autoscaling group
- `mix deploy_ex.autoscale.refresh` - Triggers an instance refresh to recreate autoscaling instances
- `mix deploy_ex.autoscale.refresh_status` - Shows the status of instance refreshes for an autoscaling group

### QA Nodes
- `mix deploy_ex.qa` - Overview of QA node commands and usage
- `mix deploy_ex.qa.create` - Creates a new QA node with a specific SHA
- `mix deploy_ex.qa.destroy` - Destroys a QA node
- `mix deploy_ex.qa.list` - Lists all active QA nodes
- `mix deploy_ex.qa.deploy` - Deploys a specific SHA to an existing QA node
- `mix deploy_ex.qa.attach_lb` - Attaches a QA node to the app's load balancer
- `mix deploy_ex.qa.detach_lb` - Detaches a QA node from the load balancer
- `mix deploy_ex.qa.cleanup` - Cleans up orphaned QA nodes

### Ansible
- `mix ansible.build` - Builds ansible files into your repository
- `mix ansible.deploy` - Deploys to ansible hosts (use `--qa` for QA-only, `--include-qa` to include QA nodes)
- `mix ansible.ping` - Pings all configured Ansible hosts
- `mix ansible.rollback` - Rolls back an ansible host to a previous SHA
- `mix ansible.setup` - Initial setup and configuration of Ansible hosts

### Terraform
- `mix terraform.apply` - Applies terraform changes to provision AWS infrastructure
- `mix terraform.build` - Builds/Updates terraform files or adds it to your project
- `mix terraform.init` - Initializes terraform in the project directory
- `mix terraform.plan` - Shows terraform's potential changes if you were to apply
- `mix terraform.output` - Displays terraform output values
- `mix terraform.refresh` - Refreshes terraform state to sync with actual AWS resources
- `mix terraform.replace` - Runs terraform replace with a node
- `mix terraform.drop` - Destroys all resources built by terraform
- `mix terraform.generate_pem` - Extracts the PEM file from Terraform state and saves it locally
- `mix terraform.show_password` - Shows passwords for databases in the cluster
- `mix terraform.dump_database` - Dumps a database from RDS through a jump server
- `mix terraform.restore_database` - Restores a database dump to either RDS or local PostgreSQL
- `mix terraform.create_ebs_snapshot` - Creates an EBS snapshot for a specified app
- `mix terraform.delete_ebs_snapshot` - Deletes EBS snapshots for a specified app or by snapshot IDs
- `mix terraform.create_state_bucket` - Creates a bucket within S3 to host the terraform state file
- `mix terraform.create_state_lock_table` - Creates a DynamoDB table for Terraform state locking
- `mix terraform.drop_state_bucket` - Drops the S3 bucket used to host the Terraform state file
- `mix terraform.drop_state_lock_table` - Drops the DynamoDB table used for Terraform state locking

## Universial Options
Most of these are available on any command in DeployEx
- `aws-bucket` - Bucket to use for aws deploys
- `aws-region` - Bucket to use for aws deploys
- `resource-group` - The resource group to target (AWS Group Tag for instances), by default this is "AppName Backend"

## Terraform Command Options

### Targeting Specific Apps
You can target specific apps when running terraform commands using the `--target` flag. This allows you to apply changes to only specific resources:

```bash
# Target a specific app
mix terraform.apply --target cfx_web

# Target multiple apps
mix terraform.apply --target cfx_web --target cfx_api

# Use with other commands
mix terraform.plan --target cfx_web
mix terraform.destroy --target cfx_web
```

The `--target` flag automatically expands to the full terraform module path `module.ec2_instance["app_name"]`.

### Default Command Arguments
You can configure default arguments for terraform commands in your config. This is useful for setting common options like `--var-file`:

```elixir
# config/config.exs
config :deploy_ex, :terraform_default_args, %{
  apply: ["--var-file=production.tfvars"],
  plan: ["--var-file=production.tfvars"],
  destroy: ["--var-file=production.tfvars"]
}
```

Default arguments are merged with command-line arguments, with command-line arguments taking precedence. This works for all terraform commands:
- `:apply`
- `:plan`
- `:destroy`
- `:refresh`
- `:replace`
- `:init`
- `:output`

## Terraform Variables
The main variables you'll want to know about are the ones inside `deploys/terraform/variables.tf`

Inside this file specifically the `my_app_project` variable is the most important.

The following options are present:

- `name` - Should aim not to touch this, it effects a lot of tags, if you do, make sure to modify the ansible files to match as the instance name itself is based on this
- `instance_count`- Number of instances to create for this app (ignored when autoscaling is enabled)
- `instance_type` - The instance tier to use eg `t3.nano` or `t3.micro`
- `instance_ami` - Override the default AMI for this instance
- `private_ip` - Set a static private IP for the instance
- `enable_eip` - Enable an Elastic IP from AWS giving this a static URL
- `disable_ipv6` - Disable IPv6 for this instance
- `disable_public_ip` - Disable public IP assignment for this instance
- `load_balancer` - Load balancer configuration object:
  - `enable` - Enable a load balancer when there is more than one `instance_count`
  - `enable_https` - Enable HTTPS listener on the load balancer
  - `port` - Port for the load balancer to serve, this is the url you will hit
  - `instance_port` - Port for the load balancer to forward to, this is your application port
  - `health_check` - Health check configuration object:
    - `path` - Health check endpoint path (e.g., "/health")
    - `protocol` - Protocol for health checks (HTTP/HTTPS)
    - `matcher` - HTTP status codes considered healthy for HTTP (default: "200-299,301")
    - `https_matcher` - HTTP status codes considered healthy for HTTPS (default: "200-299")
    - `unhealthy_threshold` - Number of failed checks before marking unhealthy (default: 2)
    - `healthy_threshold` - Number of successful checks before marking healthy (default: 2)
    - `timeout` - Health check timeout in seconds (default: 5)
    - `interval` - Time between health checks in seconds (default: 20)
- `ebs` - EBS volume configuration object:
  - `enable_secondary` - Enable a secondary EBS Volume mounted on /data
  - `primary_size` - Set the primary EBS Volume size in GB (default: 16GB)
  - `secondary_size` - Set the secondary EBS Volume on /data size in GB (default: 16GB)
  - `secondary_snapshot_id` - Snapshot ID to restore secondary volume from
- `tags` - Tags specified in `Key=Value` format to add to the EC2 instance
- `autoscaling` - Configure AWS Auto Scaling Groups (see [Autoscaling section](https://github.com/MikaAK/deploy_ex#autoscaling))

## Switching out IaC Tools
By default, DeployEx uses Terraform and Ansible for infrastructure as code (IaC) tools.
However, you can switch to, e.g., [OpenTofu](https://opentofu.org/) using the `:iac_tool` option
in `:deploy_ex` config. This should point to the binary for the installed IaC tool:

```elixir
config :deploy_ex, iac_tool: "tofu
```

## Autoscaling

DeployEx supports AWS Auto Scaling Groups (ASG) with automatic CPU-based scaling. When enabled, instances are managed dynamically by AWS based on load, providing automatic horizontal scaling for your applications.

### Autoscaling Configuration

Enable autoscaling in your Terraform variables (`deploys/terraform/variables.tf`):

```hcl
my_app_project = {
  my_app = {
    name          = "My App"
    instance_type = "t3.nano"
    
    autoscaling = {
      enable             = true
      min_size           = 1
      max_size           = 5
      desired_capacity   = 2
      cpu_target_percent = 60
      scale_in_cooldown  = 300
      scale_out_cooldown = 300
    }
    
    load_balancer = {
      enable        = true
      port          = 80
      instance_port = 4000
      health_check = {
        path     = "/health"
        protocol = "HTTP"
      }
    }
    
    # Optional: EBS volumes work with autoscaling via dynamic attachment
    ebs = {
      enable_secondary = true
      secondary_size   = 32
    }
  }
}
```

**Configuration Options:**
- `enable` - Enable autoscaling for this app
- `min_size` - Minimum number of instances (ASG will never scale below this)
- `max_size` - Maximum number of instances (ASG will never scale above this)
- `desired_capacity` - Initial number of instances to launch
- `cpu_target_percent` - Target CPU utilization percentage (ASG scales to maintain this)
- `scale_in_cooldown` - Seconds to wait after scale-in before another scale-in (default: 300)
- `scale_out_cooldown` - Seconds to wait after scale-out before another scale-out (default: 300)

### How Autoscaling Works

**Automatic Scaling:**
- AWS monitors average CPU utilization across all instances
- When CPU exceeds `cpu_target_percent`, new instances launch automatically
- When CPU drops below target, instances terminate automatically
- Cooldown periods prevent rapid scaling oscillations

**Instance Lifecycle:**
1. **Launch:** New instance boots with Launch Template configuration
2. **User-Data Execution:** Cloud-init runs setup scripts
3. **Release Discovery:** Instance queries existing nodes or S3 for current version
4. **Download & Start:** Instance downloads release from S3 and starts application
5. **Health Checks:** Load balancer marks instance healthy after successful checks
6. **Cluster Join:** Instance automatically joins cluster via libcluster EC2 tag strategy

**Version Consistency:**
New instances automatically discover the correct release version:
1. Query existing instances via AWS API for running nodes
2. SSH to existing instance and read `/srv/current_release.txt` (managed by Ansible)
3. Respects rollbacks - uses the version Ansible deployed, not necessarily latest
4. Fallback to latest S3 release if no instances exist (enables scaling from zero)

**IAM Permissions:**
Autoscaled instances receive an IAM role with permissions for:
- S3 release downloads (`s3:GetObject` on release bucket)
- CloudWatch metrics and logs
- EC2 instance discovery (`ec2:DescribeInstances`)
- EC2 volume attachment/detachment if EBS enabled (`ec2:AttachVolume`, `ec2:DetachVolume`)

**Load Balancing:**
- Network Load Balancer (NLB) automatically created when autoscaling enabled
- Instances register/deregister automatically with target groups
- Health checks ensure traffic only routes to healthy instances
- Supports both HTTP (port 80) and HTTPS (port 443) listeners

**EBS Volumes:**
- Volume pool created equal to `max_size` (one volume per potential instance)
- Volumes attach/detach dynamically as instances scale
- Volumes are AZ-specific and only attach to instances in same AZ
- User-data script handles attachment, filesystem detection, and mounting

**Limitations:**
- Elastic IPs not supported with autoscaling (instances get dynamic IPs)
- EBS volumes require pool equal to `max_size`
- EBS volumes are AZ-specific
- `instance_count` is ignored when autoscaling enabled

### Autoscaling Deployment Strategies

When deploying new application versions with autoscaling, you have three strategies:

#### Strategy 1: Ansible Deploy (Fast Updates)
Deploy to all running instances simultaneously:
```bash
mix deploy_ex.upload
mix ansible.deploy
```

**Pros:** Fast, no instance replacement, maintains current capacity  
**Cons:** All instances update at once (brief downtime possible)  
**Best for:** Quick updates, bug fixes, low-traffic periods

#### Strategy 2: Instance Refresh (Zero-Downtime)
Trigger AWS rolling instance refresh:
```bash
mix deploy_ex.upload
mix terraform.apply  # Updates Launch Template if needed
# AWS automatically performs rolling refresh
```

**How it works:**
- AWS gradually replaces instances (maintains 50% healthy)
- New instances download latest release from S3
- Old instances terminate after new ones are healthy
- Automatic rollback on health check failures

**Pros:** Zero-downtime, gradual rollout, automatic rollback  
**Cons:** Slower (replaces all instances), uses more resources temporarily  
**Best for:** Production deployments, critical updates

#### Strategy 3: Manual Scale Cycle (Testing)
Force new instances by scaling down then up:
```bash
mix deploy_ex.upload
mix deploy_ex.autoscale.scale my_app 0
sleep 30
mix deploy_ex.autoscale.scale my_app 3
```

**Pros:** Simple, forces fresh instances  
**Cons:** Temporary capacity reduction, downtime  
**Best for:** Testing, non-production environments

### Autoscaling Commands

#### View Instance Status
```bash
mix deploy_ex.instance.status <app_name>
```

Displays comprehensive instance information for an application:
- Autoscaling status (enabled/disabled, ASG name, capacity)
- Instance details (ID, state, type)
- IP addresses (Elastic IP, public IP, private IP, IPv6)
- Load balancer health (target group attachment and health status)
- All instance tags

**Options:**
- `--environment, -e` - Environment name (default: Mix.env())

**Example:**
```bash
mix deploy_ex.instance.status my_app -e prod

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Autoscaling: Enabled
  Group: my-app-asg-prod
  Desired: 2 | Min: 1 | Max: 5
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Instances (2):

  My App-prod-0
  ├─ Instance ID: i-0abc123def456
  ├─ State: running
  ├─ Type: t3.small
  ├─ Public IP: 54.123.45.67
  ├─ Private IP: 10.0.1.100
  ├─ Target Group: my-app-tg-prod - healthy
  └─ Tags:
     ├─ Environment: prod
     ├─ InstanceGroup: my_app
     └─ ManagedBy: DeployEx

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### View Autoscaling Status
```bash
mix deploy_ex.autoscale.status <app_name>
```

Displays:
- Current, minimum, and maximum capacity
- Instance count and IDs
- Instance lifecycle states (InService, Pending, Terminating)
- Health status
- Availability zones
- Scaling policy configuration (CPU target)

**Example:**
```bash
mix deploy_ex.autoscale.status my_app

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Autoscaling Group: my-app-asg-dev
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Capacity:
  Desired: 3
  Minimum: 1
  Maximum: 5

Current Instances: 3
  • i-0abc123 (InService, Healthy) - us-west-2a
  • i-0def456 (InService, Healthy) - us-west-2b
  • i-0ghi789 (Pending, Healthy) - us-west-2c

Scaling Policies:
  • my-app-cpu-target-dev (TargetTrackingScaling)
    Target: 60% ASGAverageCPUUtilization
```

#### Manually Scale Capacity
```bash
mix deploy_ex.autoscale.scale <app_name> <desired_capacity>
```

Sets the desired number of instances. AWS will launch or terminate instances to match.

**Examples:**
```bash
# Scale to 5 instances
mix deploy_ex.autoscale.scale my_app 5

# Scale to minimum (useful before maintenance)
mix deploy_ex.autoscale.scale my_app 1

# Scale to zero (stops all instances)
mix deploy_ex.autoscale.scale my_app 0
```

**Notes:**
- Desired capacity must be between `min_size` and `max_size`
- AWS rejects values outside this range
- Terraform ignores `desired_capacity` drift (allows dynamic scaling)

#### Trigger Instance Refresh
```bash
mix deploy_ex.autoscale.refresh <app_name> [options]
```

Triggers an instance refresh to replace all instances with new ones. New instances will run cloud-init and pull the current release from S3.

**Options:**
- `--min-healthy-percentage` - Minimum percentage of healthy instances during refresh (default: 90)
- `--instance-warmup` - Seconds to wait for instance warmup (default: 300)
- `--skip-matching` - Skip instances that already match the desired configuration
- `--environment, -e` - Environment name (default: Mix.env())

**Example:**
```bash
# Refresh all instances
mix deploy_ex.autoscale.refresh my_app

# Refresh with lower availability requirement
mix deploy_ex.autoscale.refresh my_app --min-healthy-percentage 50
```

#### Check Instance Refresh Status
```bash
mix deploy_ex.autoscale.refresh_status <app_name> [options]
```

Shows the status of instance refreshes for an autoscaling group.

**Options:**
- `--environment, -e` - Environment name (default: Mix.env())

**Example:**
```bash
mix deploy_ex.autoscale.refresh_status my_app

Instance Refresh Status for my-app-asg-dev
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Refresh ID: abc123-def456
Status: InProgress
Progress: 50%
Instances to update: 2
Started: 2024-01-15T10:30:00Z
```

### Autoscaling Instance Setup

Autoscaled instances receive full setup automatically via user-data and Lambda:

**Basic Setup (in user-data):**
- **BEAM Linux Tuning:** File descriptor limits (65536), kernel parameters
- **IPv6/Dualstack:** AWS dualstack endpoint configuration
- **Log Management:** Aggressive log rotation (daily, 4 rotations) and weekly cleanup
- **EBS Volume Management:** Dynamic attachment/detachment with filesystem detection
- **Release Discovery:** Queries existing instances or S3 for current version
- **Application Start:** Downloads release and starts systemd service

**Advanced Setup (via Lambda + SSM):**
- **Prometheus Exporter:** Metrics collection for monitoring
- **Loki Promtail:** Log aggregation to Loki
- **Additional Ansible Roles:** Any roles configured in your setup playbook

**How Lambda Setup Works:**
1. Instance boots and triggers SNS notification
2. Lambda function invokes on SNS event
3. Lambda downloads Ansible roles from DeployEx GitHub releases
4. Lambda runs Ansible setup via SSM Run Command
5. Instance completes setup and starts application

**No manual intervention needed** - all setup is automated and consistent.

### Connecting to Autoscaled Instances

The `mix deploy_ex.ssh` command supports autoscaled instances:

```bash
# List all instances and their IPs
mix deploy_ex.ssh my_app --list

# Connect to specific instance by index
mix deploy_ex.ssh my_app --index 0

# Connect to random instance (default)
mix deploy_ex.ssh my_app

# View logs from specific instance
mix deploy_ex.ssh my_app --index 1 --log

# Connect to IEx on specific instance
mix deploy_ex.ssh my_app --index 2 --iex
```

**Instance Selection:**
- `--list` - Shows all instances with indices and IPs
- `--index N` - Connects to instance at index N (0-based)
- No flag - Prompts for selection or connects to random instance with `-s`

## QA Nodes

QA nodes are standalone EC2 instances that can be spun up with a specific git SHA release for testing purposes, independent of any Auto Scaling Group or Terraform-managed infrastructure. They're ideal for:

- Testing specific commits before merging
- A/B testing different versions
- Staging environments for QA review
- Debugging production issues with a specific release

### Quick Start

```bash
# Create a QA node with a specific SHA
mix deploy_ex.qa.create my_app --sha abc1234

# List all QA nodes
mix deploy_ex.qa.list

# Deploy a different SHA to existing QA node
mix deploy_ex.qa.deploy my_app --sha def5678

# Attach to load balancer for traffic testing
mix deploy_ex.qa.attach_lb my_app

# Get SSH connection info
mix deploy_ex.qa.ssh my_app

# Destroy when done
mix deploy_ex.qa.destroy my_app
```

### QA Node Commands

#### Create a QA Node
```bash
mix deploy_ex.qa.create <app_name> --sha <git_sha> [options]
```

**Options:**
- `--sha, -s` - Target git SHA (required)
- `--instance-type` - EC2 instance type (default: t3.small)
- `--skip-ami` - Skip app AMI lookup and use base AMI (runs full setup)
- `--skip-setup` - Skip Ansible setup after creation
- `--skip-deploy` - Skip deployment after setup
- `--attach-lb` - Attach to load balancer after deployment
- `--force, -f` - Replace existing QA node without prompting
- `--quiet, -q` - Suppress output messages

**AMI Behavior:**
- By default, uses the app's pre-configured AMI if available (faster, skips setup)
- With `--skip-ami`, uses base Debian AMI and runs full Ansible setup
- Release is auto-deployed via cloud-init user-data script

**Example:**
```bash
# Create with all defaults
mix deploy_ex.qa.create my_app --sha abc1234

# Create and attach to load balancer
mix deploy_ex.qa.create my_app --sha abc1234 --attach-lb

# Create without setup/deploy (just provision instance)
mix deploy_ex.qa.create my_app --sha abc1234 --skip-setup --skip-deploy
```

#### Destroy QA Nodes
```bash
mix deploy_ex.qa.destroy <app_name> [options]
mix deploy_ex.qa.destroy --instance-id <id>
mix deploy_ex.qa.destroy --all
```

**Options:**
- `--instance-id, -i` - Destroy by specific instance ID
- `--all` - Destroy all QA nodes
- `--force, -f` - Skip confirmation prompt
- `--quiet, -q` - Suppress output messages

#### List QA Nodes
```bash
mix deploy_ex.qa.list [options]
```

**Options:**
- `--app, -a` - Filter by app name
- `--json` - Output as JSON
- `--quiet, -q` - Minimal output

**Example output:**
```
QA Nodes:
--------------------------------------------------------------------------------
my_app
  Instance ID: i-0abc123def456
  SHA: abc1234
  State: running
  Public IP: 54.123.45.67
  IPv6: 2600:1f18:...
  LB Attached: no
  Created: 2024-01-15T10:30:00Z
--------------------------------------------------------------------------------
Total: 1 QA node(s)
```

#### Deploy to QA Node
```bash
mix deploy_ex.qa.deploy <app_name> --sha <git_sha> [options]
```

Deploy a different release SHA to an existing QA node without recreating it.

**Options:**
- `--sha, -s` - Target git SHA (required)
- `--quiet, -q` - Suppress output messages

#### Attach to Load Balancer
```bash
mix deploy_ex.qa.attach_lb <app_name> [options]
```

Attach a QA node to the app's load balancer target groups to receive production traffic.

**Options:**
- `--target-group` - Specific target group ARN (default: auto-discover)
- `--port` - Port to register (default: 4000)
- `--wait` - Wait for health check to pass
- `--quiet, -q` - Suppress output messages

#### Detach from Load Balancer
```bash
mix deploy_ex.qa.detach_lb <app_name> [options]
```

Remove a QA node from load balancer target groups.

**Options:**
- `--target-group` - Specific target group ARN (default: all attached)
- `--quiet, -q` - Suppress output messages

#### SSH to QA Node
```bash
mix deploy_ex.qa.ssh <app_name> [options]
```

Get SSH connection info for a QA node.

**Options:**
- `--short, -s` - Output command only (for eval)
- `--root` - Connect as root
- `--log` - View application logs
- `--iex` - Connect to remote IEx
- `--quiet, -q` - Suppress output

**Example:**
```bash
# Get SSH command
mix deploy_ex.qa.ssh my_app

# Connect directly
eval "$(mix deploy_ex.qa.ssh my_app -s)"

# View logs
eval "$(mix deploy_ex.qa.ssh my_app -s --log)"

# Connect to IEx
eval "$(mix deploy_ex.qa.ssh my_app -s --iex)"
```

#### Check Health Status
```bash
mix deploy_ex.qa.health [app_name] [options]
```

Check load balancer health status for QA nodes.

**Options:**
- `--all` - Check health for all apps (not just QA nodes)
- `--watch, -w` - Continuously monitor (refresh every 5s)
- `--json` - Output as JSON
- `--quiet, -q` - Minimal output

**Example output:**
```
Load Balancer Health Status
===========================

Target Group: my-app-tg-dev
  ✓ my-app-dev-0 (i-0abc123) - healthy
  ✓ my-app-dev-1 (i-0def456) - healthy
  ✗ my-app-qa-abc123 (i-0ghi789) [QA] - unhealthy
    Reason: Target.FailedHealthChecks

Summary: 2 healthy, 1 unhealthy
```

#### Cleanup Orphaned QA Nodes
```bash
mix deploy_ex.qa.cleanup [options]
```

Detect and clean up orphaned QA nodes (S3 state without instance, or instance without S3 state).

**Options:**
- `--dry-run` - Show what would be cleaned up without taking action
- `--force, -f` - Skip confirmation prompt
- `--quiet, -q` - Suppress output messages

### How QA Nodes Work

**State Management:**
- QA node state is stored in S3 at `qa-nodes/{app_name}/{instance_id}.json`
- Supports multiple QA nodes per app simultaneously
- State includes instance ID, target SHA, IPs, and load balancer attachment status
- State is always verified against AWS before operations

**Infrastructure Discovery:**
- QA nodes use the same security group, subnet, and IAM profile as production instances
- AMI is auto-discovered: first checks for app-specific AMI (tagged with `App`, `Environment`, `ManagedBy: DeployEx`), falls back to base Debian AMI
- No Terraform state dependency - uses AWS APIs directly
- Cloud-init automatically deploys the target SHA on boot

**Ansible Integration:**
- QA nodes are tagged with `QaNode: true` and `InstanceGroup: {app_name}`
- Normal `mix ansible.deploy` excludes QA nodes by default
- Use `--qa` flag to target only QA nodes: `mix ansible.deploy --only my_app --qa`
- Use `--include-qa` flag to include QA nodes along with production nodes
- QA nodes can be targeted individually via `--limit` flag
- QA releases are stored under `qa/{app_name}/` in the release bucket
- QA release state is stored under `release-state/qa/{app_name}/`

**Load Balancer:**
- QA nodes can be attached to existing target groups
- Useful for A/B testing or gradual rollouts
- Health checks work the same as production instances

### QA Node Tags

QA nodes are tagged with:
- `Name`: `{app_name}-qa-{short_sha}-{timestamp}`
- `Group`: Same as production (for clustering)
- `InstanceGroup`: `{app_name}` (for Ansible targeting)
- `QaNode`: `true` (for filtering)
- `TargetSha`: Full git SHA
- `ManagedBy`: `DeployEx`
- `SetupComplete`: `true/false`

### Commands with QA Support

Several commands support QA-specific flags:

```bash
# Deploy only to QA nodes
mix ansible.deploy --only my_app --qa

# Deploy to both production and QA nodes
mix ansible.deploy --only my_app --include-qa

# Run setup on QA nodes too
mix ansible.setup --only my_app --include-qa

# Check health of QA instances only
mix deploy_ex.instance.health --qa

# SSH to a QA node
mix deploy_ex.ssh my_app --qa
```

**Flag Summary:**
- `--qa` - Target only QA nodes (excludes production)
- `--include-qa` - Include QA nodes along with production nodes

## Ansible Options
- `inventory` (alias: `e`) - [Ansible inventories](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html)
- `limit` (alias: `i`) - [Ansible limiting/filtering](https://docs.ansible.com/ansible/latest/inventory_guide/intro_patterns.html#patterns-and-ad-hoc-commands) to target specific servers
- `extra_vars` (alias: `e`) - Add extra variables (E.G. bucket_name="my_bucket")

## Connecting to your nodes
You can use `mix deploy_ex.ssh <app_name>` to connect to your nodes. By itself it will return the command, but can be
combined with eval using the `-s` flag

App name can be a partially complete form of app_name, so you can shorten it, and it will use a regex to find the match

#### Authorizing for SSH
By default, all nodes are non accessable over ssh, unless you whitelist your IP using `mix deploy_ex.ssh.authorize`. Alternatively if you
want to turn this safeguard off, you can go to `deploys/terraform/network.tf` and on line `36` add the `ssh-tcp` back to the end of that list

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

###### Options

- `short` - get short form command
- `root` - get command to connect with root access
- `log` - get command to remotely monitor logs
- `log_count` - sets log count to get back
- `all` - gets all logs instead of just ones for the app
- `iex` - get command to remotley connect to running node via IEx

Bash:
```bash
alias my-app-ssh='pushd ~/Documents/path/to/project && mix compile && eval "$(mix deploy_ex.ssh $@)" && popd'
```

Fish:
```fish
function my-app-ssh
  pushd ~/Documents/path/to/project &&
  set ssh_command (mix deploy_ex.ssh $argv -s) &&
  eval $ssh_command &&
  popd
end
```


## Monitoring
Out of the box, deploy_ex will generate Prometheus, Grafana UI, Grafana Loki and Sentry (WIP) into the application

To use these however there are a few steps to getting started currently (this will change in the future so it's painless)

### Setting up Grafana UI
This one is pretty easy. It should just work out of the box on the `grafana_ui` app listed in `mix terraform.output`
If it's not you can deploy it by using `mix ansible.setup --only grafana_ui`
By default Loki & Prometheus will be configured as Data Sources within Grafana and the default username and password are both `admin`

### Setting up Loki for Logging
Loki will by default come installed and setup within Grafana UI. Loki by default takes up the private IP `10.0.1.50`.

If `loki` is not deployed you can run `mix ansible.setup --only loki` to setup and start the loki log aggregator

### Setting up Prometheus for Metrics
Prometheus by default will come setup on all the nodes you create and be automatically connected in grafana. By default takes up the private IP `10.0.1.50`.

If `prometheus_db` not deployed you can run `mix ansible.setup --only prometheus_db` to setup and start the database on a provisioned node.

By default it will generate with an elastic IP
that can be used to access it. To add a custom domain go to `deploys/ansible/roles/grafana_ui/defaults/main.yaml` and swap the `grafana_ui_domain` to the domain of your choosing, and point an `A` record to the Elastic IP


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

The github action will automatically run terraform build and anisble build to keep your releases in the mix.exs in line
with instances and other setup. If you have a custom config for terraform or ansible you'll want to pull the build commands out
of the github action file that gets generated.

By default the github action will not redeploy unchanged applications, it will run a diff in git to determine changes and only
change on the following conditions:
- Code change in the app
- Code change in a related umbrella app
- Dependency changes in mix.lock
- The release hasn't been uploaded to S3 already

To redeploy a node you can run `mix ansible.deploy --only <app>` with ansible installed to redeploy all nodes in the app

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
  <summary>Ansible setup is hanging forever</summary>

  With debian 13 the tmp folder behaviour changed and small nodes sometimes run out of space. Ssh onto the server using `eval "$(mix deploy_ex.ssh -s --root app)"`and check the /tmp folder with `df -h`. If 100% run `rm -rf /tmp/*`

</details>

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
  <summary>I'm getting timeouts trying to ssh into the nodes</summary>

  By default SSH access is closed and you need to run `mix deploy_ex.ssh.authorize` to whitelist your current IP.

  See [Authorizing for SSH](https://github.com/MikaAK/deploy_ex#authorizing-for-ssh) for more information

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
  <summary>Autoscaling: Instances not joining the cluster</summary>

  Check that instances have proper tags for libcluster discovery:
  - Verify `Group` and `InstanceGroup` tags are set on instances
  - Check libcluster configuration uses `EC2Tag` strategy
  - Ensure security groups allow inter-instance communication
  - Run `mix deploy_ex.autoscale.status <app>` to see instance states

</details>

<details>
  <summary>Autoscaling: User-data script failures</summary>

  Check user-data execution logs:
  ```bash
  # SSH to instance
  mix deploy_ex.ssh my_app --index 0
  
  # Check user-data logs
  sudo cat /var/log/user-data.log
  sudo journalctl -u cloud-final
  ```

  Common issues:
  - IAM role missing S3 or EC2 permissions
  - Release file not found in S3 bucket
  - SSH key not available for release discovery
  - Network connectivity issues

</details>

<details>
  <summary>Autoscaling: Terraform desired_capacity drift</summary>

  If Terraform shows drift on `desired_capacity`, this is expected. The ASG has `lifecycle { ignore_changes = [desired_capacity] }` to allow AWS to manage capacity dynamically without Terraform interference.

</details>

<details>
  <summary>Autoscaling: Scale-in not happening</summary>

  Check these settings:
  - Verify `min_size` allows scale-in (not equal to `max_size`)
  - Check CPU is actually dropping below target percentage
  - Review `scale_in_cooldown` period (default 300s)
  - Ensure no scale-in protection on instances
  - Check CloudWatch metrics for actual CPU utilization

</details>

<details>
  <summary>Autoscaling: New instances get wrong version</summary>

  The user-data script queries existing instances for the current release version from `/srv/current_release.txt`. If this fails, it falls back to the latest release in S3. Check:
  - Ensure SSH keys are properly configured in Launch Template
  - Check security groups allow SSH between instances
  - Verify `/srv/current_release.txt` exists on running instances (created by Ansible)
  - Verify releases exist in S3 bucket
  - Check `/var/log/user-data.log` for release discovery details

</details>

<details>
  <summary>Autoscaling: EBS volumes not attaching</summary>

  Check:
  - Volume pool size equals `max_size` (one volume per potential instance)
  - Volumes are in the same AZ as instances
  - IAM role has `ec2:AttachVolume` and `ec2:DescribeVolumes` permissions
  - Check `/var/log/user-data.log` for attachment errors
  - Verify volumes have correct `InstanceGroup` tag

</details>

<details>
  <summary>RDS major version upgrade (e.g. Postgres 16 → 18)</summary>

  DeployEx's RDS module includes `allow_major_version_upgrade = true` and a
  `create_before_destroy` lifecycle on the parameter group, so most major-version
  upgrades work with a single `mix terraform.apply`. However, if Terraform tries
  to change both the engine version **and** the parameter group family in the same
  apply, AWS will reject it because a `postgres18` parameter group cannot be
  applied to an instance still running `postgres16`.

  **Fix — two-step apply:**

  1. **Step 1: Upgrade the engine only.**
     In your `deploys/terraform/modules/aws-database/main.tf` (or the generated
     copy), temporarily comment out the custom parameter group reference and add
     `apply_immediately`:

     ```hcl
     # parameter_group_name       = aws_db_parameter_group.rds_database_parameter_group.name
     allow_major_version_upgrade = true
     apply_immediately           = true
     ```

     Run `mix terraform.apply`. This upgrades the engine and lets AWS assign the
     default parameter group. The upgrade can take **10–20+ minutes**.

  2. **Step 2: Re-attach the custom parameter group.**
     Once the upgrade completes, uncomment `parameter_group_name` and remove
     `apply_immediately` (or set it to `false`):

     ```hcl
     parameter_group_name        = aws_db_parameter_group.rds_database_parameter_group.name
     allow_major_version_upgrade = true
     ```

     Run `mix terraform.apply` again. Terraform will create the new
     version-suffixed parameter group (e.g. `my-app-db-dev-params-18`) and attach
     it to the upgraded instance, then delete the old one.

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

## Goals
- [x] Deploy Rollbacks
- [ ] Canary Deploys
- [ ] Automated IP Whitelist removal lambda (from `mix deploy_ex.ssh.authorize`)
- [ ] Sentry Integration
- [ ] Vault Integration
- [ ] Static way to setup redis from apps
- [x] Subnet a-z dispersal in networking layer
- [x] S3 Backed Terraform State
  - [x] Needs a command run before to generate bucket
- [ ] Automated Terraform & Ansible install on command runs
