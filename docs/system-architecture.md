# System Architecture

## Architectural Layers

```mermaid
graph TD
    subgraph CLI["CLI Layer"]
        Tasks["Mix Tasks (73)"]
        Helpers["DeployExHelpers"]
        TUI["TUI (Wizard, Dashboard, Progress)"]
    end

    subgraph Core["Core Layer"]
        Config["DeployEx.Config"]
        Context["DeployEx.ProjectContext"]
        Utils["DeployEx.Utils"]
    end

    subgraph AWS["AWS Layer"]
        Machine["AwsMachine"]
        Bucket["AwsBucket"]
        Database["AwsDatabase"]
        ASG["AwsAutoscaling"]
        LB["AwsLoadBalancer"]
        SG["AwsSecurityGroup"]
        Infra["AwsInfrastructure"]
        DDB["AwsDynamoDB"]
        IP["AwsIpWhitelister"]
    end

    subgraph Release["Release Layer"]
        Uploader["ReleaseUploader"]
        Validator["UpdateValidator"]
        Tracker["ReleaseTracker"]
        AwsMgr["AwsManager (S3)"]
        State["State"]
    end

    subgraph IaC["Infrastructure Layer"]
        TF["Terraform"]
        TFState["TerraformState"]
        SSH["SSH"]
        Systemd["SystemdController"]
        Ansible["Ansible"]
    end

    subgraph Specialized["Specialized"]
        QA["QaNode"]
        K6["K6Runner"]
        Grafana["Grafana"]
        LLM["LlmMerge"]
    end

    Tasks --> Helpers
    Tasks --> TUI
    Helpers --> Config
    Helpers --> Context
    Helpers --> Utils
    Tasks --> AWS
    Tasks --> Release
    Tasks --> IaC
    Tasks --> Specialized
    Release --> AWS
    Specialized --> AWS
    IaC --> Utils
```

## Deployment Data Flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Mix as Mix Tasks
    participant Git as Git
    participant S3 as AWS S3
    participant TF as Terraform
    participant Ansible as Ansible
    participant EC2 as EC2 Instances

    Dev->>Mix: mix deploy_ex.release
    Mix->>Git: git diff (change detection)
    Mix->>S3: fetch remote releases
    Mix->>Mix: UpdateValidator.filter_changed
    Mix->>Mix: Mix.Task.run("release")
    Dev->>Mix: mix deploy_ex.upload
    Mix->>S3: upload .tar.gz artifacts
    Dev->>Mix: mix ansible.deploy
    Mix->>Ansible: run playbooks
    Ansible->>S3: download release
    Ansible->>EC2: deploy + restart service
```

## Template Pipeline

```mermaid
flowchart LR
    Templates["priv/terraform/*.tf.eex\npriv/ansible/*.yaml.eex"]
    Config["DeployEx.Config\n+ Mix releases"]
    EEx["EEx.eval_file\n(DeployExHelpers.write_template)"]
    Output["./deploys/terraform/*.tf\n./deploys/ansible/*.yaml"]
    CLI["terraform apply\nansible-playbook"]

    Templates --> EEx
    Config --> EEx
    EEx --> Output
    Output --> CLI
```

Template files in `priv/` are rendered with project-specific variables (app names, AWS region, bucket names, feature flags) into `./deploys/`. Once generated, these files are user-owned — deploy_ex tracks modifications via SHA256 manifest (`.deploy_ex_manifest.exs`) for intelligent upgrades.

## Release Change Detection

```mermaid
flowchart TD
    Start["filter_changed(release_states)"]
    GitDiff["git diff --name-only\ncurrent_sha..last_sha"]
    FileDiffs["file_diffs_by_sha_tuple"]
    LockDiff["MixLockFileDiffParser\n(mix.lock changes)"]
    DepTree["MixDepsTreeParser\n(mix deps.tree)"]
    CodeChange{"Code change in\napps/app_name/?"}
    DepChange{"Dependency\nchanged?"}
    LocalDep{"Local dep\nchanged?"}
    Rebuild["Include in rebuild"]
    Skip["Skip rebuild"]

    Start --> GitDiff
    GitDiff --> FileDiffs
    FileDiffs --> LockDiff
    FileDiffs --> DepTree
    FileDiffs --> CodeChange
    LockDiff --> DepChange
    DepTree --> DepChange
    DepTree --> LocalDep
    CodeChange -->|yes| Rebuild
    DepChange -->|yes| Rebuild
    LocalDep -->|yes| Rebuild
    CodeChange -->|no| DepChange
    DepChange -->|no| LocalDep
    LocalDep -->|no| Skip
```

For single-app projects, code changes are detected via `lib/`, `test/`, `priv/` paths instead of `apps/<name>/`.

## QA Node Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Validating: qa.create
    Validating --> Creating: SHA exists in S3
    Creating --> Running: EC2 instance launched
    Running --> SetupComplete: ansible.setup
    SetupComplete --> Deployed: ansible.deploy (QA prefix)
    Deployed --> LBAttached: qa.attach_lb
    LBAttached --> Deployed: qa.detach_lb
    Deployed --> Redeployed: qa.deploy --sha NEW
    Redeployed --> Deployed
    Deployed --> Terminated: qa.destroy
    LBAttached --> Terminated: qa.destroy (auto-detach)
    Terminated --> [*]
```

QA node state is persisted to S3 at `qa-nodes/{app_name}/{instance_id}.json`.

## S3 Bucket Layout

| Bucket | Content | Key Pattern |
|--------|---------|-------------|
| `{project}-elixir-deploys-{env}` | Release artifacts | `{app_name}/{timestamp}-{sha}-{filename}.tar.gz` |
| `{project}-elixir-release-state-{env}` | Release tracking | `release-state/{prefix}/{app_name}/current_release.txt` |
| `{project}-backend-logs-{env}` | Application logs | Loki-managed |

## Module Size by Subsystem

| Subsystem | Modules | LOC | Key Files |
|-----------|---------|-----|-----------|
| AWS | 9 | ~1,950 | aws_machine.ex (446), aws_autoscaling.ex (406) |
| TUI | 7 | ~1,630 | command_registry.ex (866), wizard.ex (394) |
| Specialized | 5 | ~1,140 | qa_node.ex (603), k6_runner.ex (428) |
| Infrastructure | 8 | ~700 | terraform.ex (175), ssh.ex (134), utils.ex (187) |
| Release | 8 | ~430 | release_uploader.ex (149), update_validator.ex (256) |

See also: [Code Standards](code-standards.md) | [API Reference](api-reference.md) | [Configuration Guide](configuration-guide.md)
