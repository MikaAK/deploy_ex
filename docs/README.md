# DeployEx Documentation

Documentation follows the [Diataxis](https://diataxis.fr/) framework. Guides live in `guides/`.

## Tutorials (learning-oriented)

- [Getting Started](../guides/tutorials/getting_started.md) — install, setup, first deploy

## How-to Guides (task-oriented)

- [Deploying Releases](../guides/how-to/deploying_releases.md) — build, upload, deploy, rollback, CI/CD
- [QA Nodes](../guides/how-to/qa_nodes.md) — ephemeral test instances
- [Load Testing](../guides/how-to/load_testing.md) — k6 runner lifecycle
- [Autoscaling](../guides/how-to/autoscaling.md) — refresh, scale, strategies
- [Database Operations](../guides/how-to/database_operations.md) — dump, restore, passwords
- [Connecting to Nodes](../guides/how-to/connecting_to_nodes.md) — SSH, logs, IEx, authorize
- [Managing Infrastructure](../guides/how-to/managing_infrastructure.md) — terraform, ansible, templates, teardown

## Reference (information-oriented)

- [Mix Tasks](../guides/reference/mix_tasks.md) — all 73 tasks with options
- [Configuration](../guides/reference/configuration.md) — config keys, env vars, redeploy config
- [Codebase Summary](../guides/reference/codebase_summary.md) — module inventory, dependencies
- [Testing](../guides/reference/testing.md) — test structure, conventions, fixtures

## Explanation (understanding-oriented)

- [Introduction](../guides/introduction.md) — what deploy_ex is, key abstractions
- [Architecture](../guides/explanation/architecture.md) — layers, data flows, diagrams
- [Code Standards](../guides/explanation/code_standards.md) — error handling, config, AWS, style
