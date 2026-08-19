---
name: deploy-ex-priv-templates
description: "Use when customizing, exporting, or upgrading the generated ./deploys/ templates — mix deploy_ex.export_priv, mix deploy_ex.upgrade_priv, --llm-merge, --ai-review, the .deploy_ex_manifest.exs hash manifest, template drift, a hand-edited deploys file getting overwritten by a build, restoring from .backup, or deciding whether a file in ./deploys is safe to edit. Triggers on: customize the terraform/ansible templates, my template change disappeared, merge upstream template changes after upgrading deploy_ex, manifest corrupted, where did my edits go. NOT for writing new .eex templates inside deploy_ex itself (deploy-ex-dev)."
---

# deploy_ex Priv Template Lifecycle

How generated `./deploys/` files are owned, tracked, and upgraded — and which ones are safe to hand-edit.

## Two ownership modes

- **Internal (default):** build tasks render templates straight from the deploy_ex dependency's `priv/`. You own nothing; upgrades are automatic.
- **User-managed:** `mix deploy_ex.export_priv` renders everything into `./deploys/` and flips builds to read from there. You own the files; upgrades go through `upgrade_priv`.

`DeployExHelpers.priv_folder/1` resolves `./deploys/` first, then falls back to the dependency.

## The manifest

`./deploys/.deploy_ex_manifest.exs` — SHA-256 per exported file, written by `upgrade_priv` (`DeployEx.PrivManifest`). It's an Elixir term file evaluated with `Code.eval_file/1`. Classification during upgrade:

| File state | Upgrade behavior |
|-----------|------------------|
| New upstream file | Copied in automatically |
| Hash matches manifest (you never touched it) | Overwritten silently |
| Hash differs (you modified it) | Backed up, then merged per mode |

"Manifest corrupted" error → re-run `mix deploy_ex.upgrade_priv` to rebuild it.

## Upgrading after a deploy_ex bump

```bash
mix deploy_ex.upgrade_priv               # interactive: DiffViewer, hunk-level accept/reject
mix deploy_ex.upgrade_priv --ai-review   # LLM proposes accept/reject per file; you confirm
mix deploy_ex.upgrade_priv --llm-merge   # LLM applies everything autonomously
```

Pipeline: render upstream templates to a temp dir → diff against `./deploys/` → **backup modified files to `./deploys/.backup/<timestamp>/`** → apply per mode → rewrite manifest. Restore = copy the file back out of `.backup/`.

LLM modes need `config :deploy_ex, llm_provider: ...`.

## Drift traps — why your edit disappeared

- **`terraform.build` / `ansible.build` re-render `.eex` outputs every run.** A hand edit to a rendered file (`ec2.tf`, a playbook) survives only until the next build unless the build prompts — and prompts are **silently skipped when stdin isn't a TTY** (agent shells, CI): the task exits 0 with your file untouched *or* stale depending on direction. Use `--force` deliberately, never accidentally.
- **Ansible roles sync by directory copy on every build.** Files under `./deploys/ansible/roles/` are not prompt-protected — a customized role file (e.g. an sname template) gets clobbered by the next `ansible.build`. Customize via `group_vars`/role defaults instead of editing synced role files.
- **Provider seeding syncs every build** (`DeployEx.Cloud.PrivFileSet`): only the active `--provider`'s file set lands in `./deploys/terraform/`, and its static (non-`.eex`) files are refreshed each build.

Safe places for customization, in order: project config (`config :deploy_ex, ...`) → `group_vars`/tfvars → exported files that the upgrade flow tracks (manifest-listed). Anything synced-by-copy is upstream's.

## Quick reference

```bash
mix deploy_ex.export_priv [--force]      # go user-managed
mix deploy_ex.upgrade_priv [--ai-review | --llm-merge]
ls deploys/.backup/                       # timestamped pre-upgrade backups
cat deploys/.deploy_ex_manifest.exs       # what's tracked + hashes
```

Internals: `lib/deploy_ex/priv_manifest.ex`, `lib/deploy_ex/priv_renderer.ex`, `lib/deploy_ex/llm_merge.ex`, `lib/mix/tasks/deploy_ex.upgrade_priv.ex`.
