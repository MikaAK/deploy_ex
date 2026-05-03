# System Architecture

## Architectural Layers

```mermaid
graph TD
    subgraph CLI["CLI Layer"]
        Tasks["Mix Tasks (68)"]
        Helpers["DeployExHelpers"]
        TUI["TUI: Wizard, Dashboard, DiffViewer, Progress"]
    end

    subgraph Core["Core"]
        Config["DeployEx.Config"]
        Context["DeployEx.ProjectContext"]
        Utils["DeployEx.Utils"]
    end

    subgraph AWS["AWS Wrappers"]
        Machine["AwsMachine"]
        ASG["AwsAutoscaling"]
        Infra["AwsInfrastructure"]
        LB["AwsLoadBalancer"]
        DB["AwsDatabase"]
        SG["AwsSecurityGroup"]
        Bucket["AwsBucket"]
        DDB["AwsDynamodb"]
        IPW["AwsIpWhitelister"]
    end

    subgraph Release["Release"]
        Uploader["ReleaseUploader"]
        Validator["UpdateValidator"]
        Tracker["ReleaseTracker"]
        Lookup["ReleaseLookup"]
    end

    subgraph IaC["Infrastructure"]
        TF["Terraform"]
        TFState["TerraformState"]
        Ansible["Ansible + AnsibleRoles"]
        SSH["SSH"]
        Systemd["SystemdController"]
    end

    subgraph QA["QA Pipeline"]
        QaNode["QaNode"]
        QaHost["QaHostRewrite"]
        QaPB["QaPlaybook"]
        Git["GitOperations"]
        GHA["GitHubActions"]
    end

    subgraph PrivPipe["Priv Pipeline"]
        Renderer["PrivRenderer"]
        Planner["ChangePlanner"]
        Diff["Diff"]
        LLM["LLMMerge"]
        Manifest["PrivManifest"]
    end

    subgraph Misc["Other"]
        K6["K6Runner"]
        Grafana["Grafana"]
        Tool["ToolInstaller"]
        IPF["IpFinder"]
    end

    Tasks --> Helpers
    Tasks --> TUI
    Helpers --> Config
    Helpers --> Context
    Helpers --> Utils
    Tasks --> AWS
    Tasks --> Release
    Tasks --> IaC
    Tasks --> QA
    Tasks --> PrivPipe
    Tasks --> Misc
    Release --> AWS
    QA --> AWS
    QA --> Release
    QA --> PrivPipe
    PrivPipe --> Helpers
    IaC --> Utils
```

## Deployment Data Flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Mix as Mix Tasks
    participant Git as Git
    participant S3 as S3 (release bucket + state)
    participant TF as Terraform
    participant AnsibleAS as Ansible
    participant EC2 as EC2 / ALB

    Dev->>Mix: mix deploy_ex.release
    Mix->>Git: git diff (change detection)
    Mix->>S3: fetch remote releases
    Mix->>Mix: UpdateValidator.filter_changed
    Mix->>Mix: Mix.Task.run("release") for each changed app
    Dev->>Mix: mix deploy_ex.upload
    Mix->>S3: upload .tar.gz artifacts (parallel)
    Mix->>S3: ReleaseTracker.set_current_release
    Dev->>Mix: mix ansible.deploy
    Mix->>AnsibleAS: app_playbook.yaml (target_sha resolved)
    AnsibleAS->>S3: download release tarball
    AnsibleAS->>EC2: extract, configure systemd, restart
```

## Template Pipeline

```mermaid
flowchart LR
    Templates["priv/terraform/*.tf.eex<br/>priv/ansible/*.yaml.eex"]
    Vars["DeployEx.Config<br/>+ Mix releases<br/>+ feature flags"]
    EEx["EEx.eval_file<br/>(DeployExHelpers.write_template)"]
    Output["./deploys/terraform/*.tf<br/>./deploys/ansible/*.yaml"]
    Manifest[".deploy_ex_manifest.exs<br/>(SHA256 per file)"]
    CLI["terraform apply<br/>ansible-playbook"]

    Templates --> EEx
    Vars --> EEx
    EEx --> Output
    Output --> Manifest
    Output --> CLI
```

`mix deploy_ex.export_priv` writes the rendered tree to `./deploys/` and records every file's SHA256 in `.deploy_ex_manifest.exs`. After that, you own those files. `mix deploy_ex.upgrade_priv` re-renders to a temp dir and uses `ChangePlanner` to figure out what changed.

## Priv Upgrade Pipeline

```mermaid
flowchart TD
    Render["PrivRenderer.render_to_temp"]
    Plan["ChangePlanner.plan<br/>(jaro distance + LLM disambiguation)"]
    Backup["copy modified files to backup dir"]
    Mode{"Mode?"}
    Inter["Interactive<br/>per-hunk DiffViewer"]
    Review["--ai-review<br/>LLM proposes per file"]
    Auto["--llm-merge<br/>LLM applies all"]
    Apply["write merged files<br/>update manifest"]

    Render --> Plan
    Plan --> Backup
    Backup --> Mode
    Mode --> Inter
    Mode --> Review
    Mode --> Auto
    Inter --> Apply
    Review --> Apply
    Auto --> Apply
```

`ChangePlanner` classifies each upstream file vs. user file as one of: `:identical`, `:update`, `:rename`, `:split`, `:merge_files`, `:new`, `:removed`, `:user_only`. High Jaro similarity (>= 0.8) → rename; split (>= 0.65) → split; moderate (0.4-0.8) → ask the LLM; everything else → new/removed.

## Release Change Detection

```mermaid
flowchart TD
    Start["filter_changed(release_states)"]
    GitDiff["git diff --name-only<br/>current_sha..last_sha"]
    LockDiff["MixLockFileDiffParser"]
    DepTree["MixDepsTreeParser<br/>(mix deps.tree)"]
    CodeChange{"Code change in<br/>apps/&lt;app&gt;/?"}
    DepChange{"Dependency<br/>changed?"}
    LocalDep{"Local dep<br/>changed?"}
    Rebuild["Include in rebuild"]
    Skip["Skip rebuild"]

    Start --> GitDiff
    GitDiff --> LockDiff
    GitDiff --> DepTree
    GitDiff --> CodeChange
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

## QA Pipeline

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Lookup as ReleaseLookup
    participant Rewrite as QaHostRewrite
    participant Git as GitOperations
    participant GHA as GitHubActions
    participant Node as QaNode
    participant Ansible as Ansible

    Dev->>Lookup: pick SHA (interactive)
    Lookup->>Dev: SHA
    opt --public-ip-cert
        Dev->>Rewrite: scan_candidates(umbrella_root, app, prefix)
        Rewrite->>Dev: proposals (LLM-suggested rewrites)
        Dev->>Rewrite: accept/reject
    end
    Dev->>Node: create_instance(SHA, params)
    opt --wait-for-build
        Dev->>Git: commit_and_push QA branch
        Dev->>GHA: find_build_workflow + wait_for_run
        GHA->>Dev: success | failure (4-option recovery)
    end
    Node->>Ansible: app_setup_playbook (unless --use-ami)
    Node->>Ansible: app_playbook (target_sha)
    opt --attach-lb
        Node->>Node: attach_to_load_balancer
    end
```

State for every QA node is persisted to S3 at `qa-nodes/<app>/<instance_id>.json` and mirrored on the EC2 tags (`UsePublicIpCert`, `TargetSha`, `InstanceTag`, …). Multiple developers see the same fleet.

## QA Node Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Validating: qa.create
    Validating --> HostRewrite: --public-ip-cert
    Validating --> Creating: skip rewrite
    HostRewrite --> Creating: proposals applied
    Creating --> Running: EC2 launched
    Running --> SetupComplete: ansible.setup
    SetupComplete --> Deployed: ansible.deploy
    Deployed --> WaitingBuild: --wait-for-build
    WaitingBuild --> Deployed: build success
    WaitingBuild --> RecoveryPrompt: build failure
    RecoveryPrompt --> Terminated: rollback
    RecoveryPrompt --> Deployed: revert + repush
    Deployed --> LBAttached: qa.attach_lb
    LBAttached --> Deployed: qa.detach_lb
    Deployed --> Redeployed: qa.deploy --sha NEW
    Redeployed --> Deployed
    Deployed --> Terminated: qa.destroy
    LBAttached --> Terminated: qa.destroy (auto-detach)
    Terminated --> [*]
```

## S3 Bucket Layout

| Bucket | Content | Key pattern |
|--------|---------|-------------|
| `<project>-elixir-deploys-<env>` | Release artifacts | `[qa/]<app>/<timestamp>-<sha>-<filename>.tar.gz` |
| `<project>-elixir-release-state-<env>` | Release tracking + QA state | `release-state/[qa/]<app>/current_release.txt`, `release-state/[qa/]<app>/release_history.txt`, `qa-nodes/<app>/<instance-id>.json` |
| `<project>-backend-logs-<env>` | Loki-managed app logs | (managed by Loki) |
| `<project>-terraform-state-<env>` | Terraform state | `<env>/terraform.tfstate` |

QA artifacts and state share the same buckets but use the `qa/` prefix so prod tooling can ignore them.

## Tooling Layer

```mermaid
flowchart LR
    Detect["ToolInstaller.detect_platform"]
    Plat{"Platform?"}
    Mac["macOS<br/>Homebrew"]
    Deb["Debian/Ubuntu<br/>HashiCorp apt + pip3"]
    Alp["Alpine<br/>apk"]
    AL["Amazon Linux<br/>HashiCorp yum + pip3"]
    Win["Windows<br/>(unsupported)"]
    Tools["terraform, ansible, gh"]

    Detect --> Plat
    Plat --> Mac --> Tools
    Plat --> Deb --> Tools
    Plat --> Alp --> Tools
    Plat --> AL --> Tools
    Plat --> Win
```

`mix ansible.deploy` and `mix deploy_ex.qa.create --wait-for-build` call `ToolInstaller.ensure_installed(:ansible)` and `:gh` respectively before doing real work.

## See also

- [Code Standards](code_standards.md)
- [Mix Tasks Reference](../reference/mix_tasks.md)
- [Configuration Reference](../reference/configuration.md)
- [Codebase Summary](../reference/codebase_summary.md)
