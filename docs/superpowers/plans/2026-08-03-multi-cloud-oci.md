# Multi-Cloud Provider Support — OCI First — Design & Phased Plan

> Status: **APPROVED — adversarial quorum PASSED at v18 under the GCP/Azure assumption**
> (round 17: 3/3 PASS across mechanism, compat, and completeness lenses in one round;
> zero blocking findings). v19 = v18 + the round-17 reviewers' certified-MINOR polish
> only, each fix reviewer-prescribed, no outcome changes.
> History: v9 passed the ORIGINAL quorum 3/3 (rounds 1–9); v10 = polish; the plan was then
> REOPENED at v11 when GCP & Azure became anticipated providers; v11 = N-provider redesign;
> v12–v19 = fixes from rounds 10–17. Seventeen review rounds, 51 adversarial reviews.
> Evidence basis: full-codebase discovery 2026-08-03 (3 mapping agents) + round-1 reviewer
> verification (tree abc18c6). file:line cites are MEASURED. OCI platform facts labeled
> ASSUMED where they carry a verification spike.

**Goal:** deploy_ex provisions, deploys to, and operates Elixir releases on OCI with the
same UX as AWS today (`mix terraform.*`, `mix ansible.*`, `mix deploy_ex.*`, generated
GitHub Actions CI), selected by one config key, with zero behavior change for existing AWS
users.

**Provider trajectory (v11 — replaces the old "two data points" non-goal):** GCP and
Azure are ANTICIPATED. What that changes: contracts and conventions that are expensive to
retrofit are made N-provider-proof NOW — the `providers/<name>/` layout convention (one
complement rule, one gate wording), the canonical-tag encoding contract (§3.0.2), the
provider descriptor (§3.0.3), the 4-column design check (§3.0.1), and
optional-capability marking for provider-specific mechanisms (object tagging, tag-write
markers). What it does NOT change: zero GCP/Azure implementation code, templates,
spikes, or CI in ANY phase of this plan — their columns in the 4-column check are
paper-only, sourced from public API knowledge, labeled ASSUMED, and verified by their
own future phase trains. Phases 0–5, the MVP line, all gates, and the AWS freeze are
unchanged.

**Non-goals (YAGNI):**
- No GCP/Azure/Hetzner implementation in this plan (design columns only, per above).
- No Kubernetes/containers. Same VM + systemd + release-tarball model.
- No rewrite of the AWS path. AWS modules keep their names; terraform state addresses and
  all AWS-rendered template bytes stay identical (verified by the Phase-0 render harness,
  §7 P0.0); AWS tests keep passing untouched.

---

## 1. Current-State Coupling (MEASURED summary)

Scale:
- 18 files call `ExAws` directly (145 `ExAws.` reference lines — v15 recount). 44 of 69
  mix tasks touch AWS (predicate: a direct ExAws call, an `Aws*` wrapper call, or a
  `Config.aws_*` read — NOT a bare `grep -li aws`, which returns 56 by matching prose and
  flag names; v16 predicate statement).
- 14 of 24 `DeployEx.Config` keys are AWS-specific (`config.ex:8-70` — v5 count fix);
  `aws_region` ~100 call sites, `aws_release_bucket` 35.
- 7 AWS deps (6 `ex_aws_*` at `mix.exs:38-43` + `configparser_ex` at `:44`) +
  `hackney`/`sweet_xml`/`elixir_xml_to_map` supporting.
- `--auto-pull-aws` credential path: `ansible.build.ex:107,:142-163` regex-reads
  `~/.aws/credentials` into group_vars; exposed via `full_setup.ex:35` and TUI
  (`command_registry.ex:609`). Validation error on any provider != `:aws` (v13 polarity;
  would inject AWS keys into a non-AWS group_vars). [v4 census addition.]

Coupling tiers:

**Tier A — clean AWS wrappers.** 10 leaf modules: `AwsMachine` (446L), `AwsBucket`,
`AwsDynamodb`, `AwsAutoscaling` (406L), `AwsLoadBalancer`, `AwsSecurityGroup`,
`AwsIpWhitelister`, `AwsInfrastructure` (374L), `AwsDatabase`, `ReleaseUploader.AwsManager`.

**Tier B — leaky domain modules.** `QaNode` (1218L, 35 ExAws lines), `K6Runner`,
`ReleaseTracker`, `TerraformState`, + 4 mix tasks with inline ExAws (`instance.health`,
`instance.status`, `create/delete_ebs_snapshot`).

**Tier C — non-Elixir surface.**
- `priv/terraform/`: AWS provider, `module.ec2_instance` (815L), VPC registry modules,
  `iam.tf`, S3 backend + DynamoDB lock, AWS-native cloud-init
  (`cloud_init_data.yaml.tftpl:54-223` — IMDSv1, `aws s3 cp`, `aws ec2 associate-address`).
- `priv/ansible/`: `aws_ec2` dynamic inventory is the ONLY inventory mechanism
  (`aws_ec2.yaml.eex:1`); `awscli` role in every playbook (incl. 4 STATIC setup playbooks
  `setup/{redis,prometheus_db,grafana_ui,loki_log_aggregator}.yaml:4-5`); `deploy_node`
  fetches via `aws s3 cp` under instance-profile auth; IMDS in `letsencrypt` + `save_ami`;
  Prometheus `ec2_sd_configs`; Loki S3.
- **CI/CD**: `priv/github-action.yml.eex:32-33` injects AWS env secrets;
  `priv/github-action-setup-nodes.yml.eex:23` uses `configure-aws-credentials` (v5 cite
  fix) and `:91` shells raw `aws ec2 create-tags` (bypasses the Elixir seam); rendered by
  `mix deploy_ex.install_github_action` with no provider gate; `full_setup.ex:15-18`
  documents CI as THE deploy path. [Added in v2 — round-1 R3 finding.] The installer
  also copies TWO shell scripts VERBATIM into `./.github/`
  (`install_github_action.ex:80-89`): `github-action-secrets-to-env.sh` (invoked on the
  live deploy path, `github-action.yml.eex:61,:94`) and
  `github-action-maybe-commit-terraform-changes.sh` — provider-NEUTRAL today (jq over
  `__DEPLOY_EX__*`; git commit), so the OCI CI set INHERITS them rather than forking
  (v13 census addition; §5.1's "CI sets = providers/<name>/ only" rule reads
  "provider-specific CI files only — the shared scripts stay shared").
- **Cluster discovery (v16 — round-14 blocking finding: the plan was SILENT, which is the
  defect; the decision itself is small)**: `guides/how-to/clustering.md:3,25,34` and
  `how-to/troubleshooting.md:236` make the `Group`/`InstanceGroup` tags the discovery
  contract for libcluster's `Cluster.Strategy.EC2Tag`, which queries the EC2 API — so a
  multi-node non-AWS deployment would provision, deploy and RUN while never forming a BEAM
  cluster. deploy_ex ships no libcluster config (the only `libcluster` hits in `lib/`+`priv/` are 3 comments —
  `qa_host_rewrite.ex:368`, `qa_node.ex:95,:606`), so this is USER-SIDE config: `EC2Tag` stays AWS-only; the non-AWS MVP
  documents `Cluster.Strategy.Gossip`/`DNSPoll` in the getting-started guide; a
  per-provider strategy is post-MVP (§4). Named, not silently inherited.
- **Reference docs (`guides/`, 20-file Diataxis tree — v14, round-12 blocking finding)**:
  `guides/reference/configuration.md` is a Config Keys reference table (21 key rows, 44
  aws-containing lines — v15 count fix) invalidated the moment §3.5's `cloud_provider`/`oci: [...]`/`ssh_user`/neutral
  accessors land; `guides/reference/mix_tasks.md` documents the flag surface P0.3 edits;
  `guides/explanation/architecture.md` + `guides/reference/codebase_summary.md` describe
  the AWS-only seam P0 replaces; and **`guides/reference/terraform_variables.md`** — the
  most provider-coupled file of the tree (v15 — round-13 finding): it calls
  `deploys/terraform/variables.tf` "the source of truth for everything per-app", documents
  the `deploys/terraform/` layout (`ec2.tf`, `iam.tf`, `providers.tf`,
  `modules/aws-instance/`, `modules/aws-s3-upload-bucket/`) that §5.1's flatten-on-render
  replaces for non-AWS, and documents `instance_type`/`instance_ami`/`use_latest_ami`/ASG
  blocks — i.e. it is the reference for the very schema §3.0.6 forks per provider. Owned
  by P4.6 (variables page owned jointly with §3.0.6). Also provider-coupled:
  `guides/introduction.md:3` ("adds full AWS deployment capabilities… manages releases
  through S3") + its Project-Structure module tree that P0.1's `lib/deploy_ex/cloud/**`
  invalidates; `guides/tutorials/getting_started.md:10,42-46` (prereq "AWS credentials";
  the `full_setup` sequence P4.5 provider-filters); `guides/how-to/clustering.md` (see the
  cluster-discovery entry above). **Census predicate, stated once so this stops being
  patched file-by-file (v16 — three rounds added files one at a time; WIDENED v17):** the
  P4.6 docs list is **DERIVATION-based, not path-enumerated (v18 — round-16 blocking
  finding; enumerating paths is what made this the fourth file-by-file patch):**
  `git ls-files '*.md'` minus `docs/superpowers/`, filtered by
  `grep -liE "aws|ec2|s3|iam"`, re-run at execution time, minus files whose only hits are
  prose examples. A TRACKED doc is therefore in the census by construction. **ATTRIBUTION is part of the
  same derivation (v19 — v18 derived membership but hand-picked ownership): partition the
  hits into (a) IMPLEMENTER-INSTRUCTION files — `.claude/skills/**`, `.windsurf/**`,
  `**/Agents.md`, `guides/explanation/code_standards.md` — owned by the phase that
  INVALIDATES them, and (b) user docs owned by P4.6. The predicate runs at P0 with that
  classifier, not only at P4.6.** Measured (a)-class duplicates of the same
  soon-to-be-wrong ExAws idiom: `guides/explanation/code_standards.md:49-53` (byte-identical
  to the skill's), `.windsurf/rules/aws.md:8`, `.windsurf/workflows/review.md:161,:271` (a
  reviewer CHECKLIST item — it would fail the very PRs P0.2/P1 produce), `Agents.md:10`,
  `lib/deploy_ex/Agents.md:8`.
  **This surfaces `.claude/skills/{deploy-ex-dev,deploy-ex-infra,deploy-ex-ops}/SKILL.md`
  (git-tracked, symlinked as `skills/`), which no earlier census reached — and one of them
  actively MIS-INSTRUCTS the implementer of this plan (v18):**
  `deploy-ex-dev/SKILL.md:96-99` prescribes "Include explicit region on every ExAws
  request" with `ExAws.request(region: opts[:aws_region] || Config.aws_region())` — the
  exact pattern P0's expected-ExAws-file list rejects and §3.2's P1 defaulting grep fails
  on — and its own trigger is "Always use when modifying files in `lib/deploy_ex/`,
  `lib/mix/tasks/`, `priv/`, `test/`". It is therefore owned by **P0.2/P0.3, NOT P4.6**
  (it is wrong the moment the seam lands, three phases before P4.6).
  `deploy-ex-infra/SKILL.md:146-156` (config reference) and `:28` (the `--aws-bucket`/
  `--aws-log-bucket` GHOST flags §3.2 measured as never existing, fixed in moduledocs by
  P0.3) and `:178` (`Group` from `Config.aws_resource_group()`, a §3.0.2 canonical-tag
  consumer) get a P4.6 row beside `guides/reference/configuration.md`; every hit either gets a
  P4.6 row or an explicit "AWS-specific by design" note. **`README.md` was outside the v16
  predicate and is the front door (v17 — round-15 blocking finding):** it carries the
  config example (`:347-349` `aws_region`/`aws_resource_group`/`aws_release_bucket`), the
  CI secret table (`:156-157` `DEPLOY_EX_AWS_ACCESS_KEY_ID`/`_SECRET_ACCESS_KEY`, which
  §6.5 forks into two credential sets), Prerequisites "AWS credentials" (`:219`), the
  `full_setup` bootstrap sequence P4.5 provider-filters (`:96`), and — the loudest
  out-of-repo consumer of the canonical tag values §3.0.2 calls user-visible —
  `README.md:51`: "deploy_ex tags every instance with `Group` and `InstanceGroup`. Pair
  with `libcluster_ec2_tag_strategy`…".
- **CDN upload buckets**: `priv/terraform/modules/aws-s3-upload-bucket/` (CloudFront
  distribution + key groups + Secrets Manager signing key; wired at `bucket.tf:36-60` off
  `var.upload_buckets`, schema at `variables.tf.eex:88-103` with `enable_cdn`/`cdn_*`).
  AWS-only permanently unless demanded — see §4 deferrals. [Added in v3 — round-2 R3.]

Cross-cutting hazards (each has a plan answer):
1. **XML parsing is caller-side** (`aws_infrastructure.ex:203-342`,
   `instance.status.ex:252`). OCI returns JSON → behaviours return normalized structs. (§3)
2. **Terraform addresses baked into Elixir** — `terraform.ex:104-135` (v14 cite sync
   with §5.4; `:137-154`'s SG literal is a dead reader, cut from scope),
   `terraform.replace.ex:67-73`, AND `terraform.ex:41-54` (`build_target_string/1` expands
   `--target <app>` into `module.ec2_instance[...]` for every terraform task). AWS
   addresses FROZEN; OCI gets its own address map covering all three sites. (§5.4)
3. **Priv distribution is whole-tree copy in SIX places** (v3 census) —
   (1) first-run terraform seed (`terraform.build.ex:122-141` `File.cp_r!`);
   (2) first-run ANSIBLE seed (`ansible.build.ex:91-113` — whole `priv/ansible` `cp_r!`
   at :99-101; the seed itself removes only `group_vars/all.yaml.eex` at :103, other
   `.eex` are removed later conditionally at `:183-185,:208-210,:228-229,:361-371`; fires
   for every fresh project AND for existing users via `full_drop.ex:27`
   `rm_rf!("./deploys")` → `full_setup.ex:43,:46`);
   (3) per-build ansible role sync (`ansible.build.ex:346-356` +
   `deploy_ex_helpers.ex:34-41` — EVERY `mix ansible.build`);
   (4) `DeployEx.AnsibleRoles.sync/1` on every QA playbook run (`qa_playbook.ex:42`);
   (5) template render (`terraform.build.ex:280` glob);
   (6) PrivRenderer temp-tree copy feeding export_priv/upgrade_priv
   (`priv_renderer.ex:45,:132,:360-364`; upgrade copies `{:new,...}` unconditionally at
   `deploy_ex.upgrade_priv.ex:727-731`; ChangePlanner jaro rename detection at
   `change_planner.ex:138-191` can false-match OCI files against user customizations —
   data-loss path under `--llm-merge`). Without filtering, EVERY new OCI file leaks into
   every AWS user's `./deploys/`. → Provider-aware priv file-set registry, §5.1.
   Corollary: **shared AWS role files are byte-frozen** — roles are copied verbatim, never
   rendered, so any in-role provider branch ships to every AWS user (§6.2). (v2, v3)
4. **Renders are nondeterministic today** — `pem_app_name` embeds
   `:crypto.strong_rand_bytes` in BOTH renderers (`terraform.build.ex:44,:68`;
   `priv_renderer.ex:86,:105`); `generate_db_password` uses `Enum.random`
   (`terraform.build.ex:273-275`); no `--dry-run` exists; `terraform.build` runs
   `terraform init` unconditionally (`:90-93`). "AWS output unchanged" is unverifiable
   until a deterministic render harness exists. → §7 P0.0. (v2)
5. **No presigned URLs; instance auth = ambient instance-profile** (`iam.tf:34-42`). OCI
   equivalent: instance principals via dynamic groups. (§6)
6. **SSH user `"admin"` hardcoded** (`ssh.ex:2`, `ansible.cfg.eex`); OCI has no official
   Debian platform images [ASSUMED, spike S3]. (§6)
7. **The Elixir↔terraform data seam is NOT the outputs contract** the v1 plan claimed:
   `terraform.ex:156-180` reads only top-level `public_ips`/`ipv6_addresses` and has zero
   callers in lib/; the shipped `outputs.tf.eex` nests values under `output "instances"`.
   The REAL seams are raw-tfstate reads by resource TYPE:
   `terraform.generate_pem.ex:42-43` (`tls_private_key`, `aws_key_pair`),
   `TerraformState.get_resource_attribute_by_tag` (show_password, `aws_database`,
   `qa_node.ex:576`). (§5.3, v2 correction)

---

## 2. Approaches Considered

**A. Capability behaviours + config-selected provider (CHOSEN).** Formalize the Tier-A
seam into behaviours, AWS modules as first impls, OCI added alongside; provider-parallel
template sets selected at render time; staged so every phase lands green on AWS first.
- Pro: smallest diff per step; AWS untouched; matches repo DI/test style; Tier-A already
  defines the method surface.
- Con: behaviours shaped by AWS semantics may fit OCI imperfectly (mitigated: callbacks
  designed from CALLER need; 4-column AWS/OCI/GCP/Azure design check per §3.0.1 before
  the PR that adds or changes a callback merges, in any phase — v14).

**B. Separate provider hex packages.** Rejected (v11: still rejected at N=4
anticipated — in-tree descriptor modules scale fine; hex split is packaging, revisit
only on a real out-of-tree provider need).

**C. Shell-out everything via provider CLIs.** Rejected wholesale (discards 10 tested
wrapper modules) but adopted selectively: OCI compute/network via `oci` CLI (no viable OCI
Elixir SDK; draft-cavage request signing not worth hand-rolling), OCI object storage via
ExAws S3-compatibility API. This hybrid is the load-bearing decision.

---

## 3. Provider Abstraction Design (Elixir)

### 3.0 N-Provider Design Rules (v11 — GCP/Azure anticipated)

These rules N-proof the contracts without writing a line of GCP/Azure code:

**3.0.1 — 4-column design check (BLOCKING, EVENT-triggered — v13).** Trigger is an
EVENT, not a phase: ANY behaviour callback ADDED OR CHANGED in ANY phase — including the
Phase-5 extractions of `Autoscaling`/`LoadBalancer`/`Database`/`StateLock`/QaNode/
K6Runner, and any callback added to an MVP behaviour after P0 merges — requires a
4-column row in `2026-08-03-provider-columns.md` before ITS PR merges. A callback merged
without a row is a defect in this doc, not an exemption (same universalization the
integration rule needed at v6). Every callback must have a plausible mapping in all four
columns — AWS, OCI, GCP, Azure. AWS/OCI columns are the implemented truth; GCP/Azure columns are
paper-only (public API knowledge, labeled ASSUMED, verified by their own future trains).
A callback with no plausible mapping in a column is redesigned or marked an OPTIONAL
capability (§3.0.4). Known column facts the check must confront: GCP has no
per-instance security groups (VPC firewall rules + network tags); Azure Blob has NO
S3-compatible API; GCP "labels" are constrained (below); all four have metadata/user-data
and a CLI with JSON output (`aws`/`oci`/`gcloud`/`az`).

**3.0.2 — Canonical tag map + provider encoding layer.** Callers always use the
canonical tag map (`Group`, `Environment`, `InstanceGroup`, `GitBranch`, ...); the
provider impl OWNS the encoding to/from the provider-native representation, and
round-trip fidelity is part of the behaviour contract. This exists because the v9 "tags
are the portability contract" rule breaks at GCP: labels allow only
`[a-z0-9_-]`, max 63 chars, keys start lowercase — `Group = "CFX Web"` (space, caps)
and `GitBranch = "feat/foo"` (slash) are ILLEGAL label values. The GCP column's paper
answer: filterable slugified labels + full-fidelity canonical map in instance metadata;
AWS/OCI impls are identity encodings. The encoding layer is a behaviour-contract clause
NOW (cheap) so GCP doesn't force a caller-side rewrite later (expensive). Three contract
clauses:
- (v16) canonical tag VALUES have OUT-OF-REPO consumers — `Group` feeds user-side
  libcluster `EC2Tag` config (`guides/how-to/clustering.md:25`) and billing rollups — so a
  LOSSY encoding is a user-visible contract change, not an internal detail: the provider
  train that introduces one must document the encoded form its users must configure
  against. In-repo round-trip fidelity is necessary, not sufficient.
- (v18) a LOSSY provider has TWO encoders, not one: the Elixir impl AND that provider's
  terraform templates, which SEED the canonical tags at create time (AWS precedent:
  `modules/aws-instance/main.tf` writes `Group`/`InstanceGroup`). An HCL encoder that
  disagrees with the Elixir decoder breaks §6.1 inventory groups while both halves stay
  individually conformant — so that provider's train pins `encode(HCL) ≡ decode(Elixir)`
  on the canonical keys, and the pin is a §3.0.3 census row. Free for AWS/OCI (identity).
- (v12) the canonical map is OPEN — encoding governs REPRESENTATION, never membership;
  unknown keys (`SetupComplete`, `MonitoringKey`, `UsePublicIpCert`, ...) round-trip
  verbatim under identity encodings.
- (v12) lossy-encoded filters are PRE-filters — slugs are non-injective (`feat/foo` vs
  `feat_foo` collide), so impls post-verify matches against the decoded canonical map
  before returning.
- **(v14 — round-12 blocking finding) THE ENCODING LAYER HAS A TEST OWNER.** Both
  implemented columns are identity encodings, so a `both providers' fakes` contract test
  cannot distinguish "callers route through the seam" from "callers pass raw provider
  tags" — the N-proofing purchase would not actually be made. P0 Done carries this as a LITERAL bullet
  (v16 — v15 asserted it here but never added it to the criterion, which is the same
  describe-vs-bind defect this doc has now caught four times): a contract test that drives
  **CALLERS**, not behaviours, against a **test-only LOSSY fake provider descriptor**
  (slugify + metadata sidecar — a test double, NOT GCP code, so the zero-implementation
  non-goal holds). Caller-level is the whole point: a behaviour-level test pins impl
  round-trip properties and still cannot distinguish "callers route through the seam" from
  "callers pass raw provider tags" (v14's version had this defect).
  **Injection seam (v16 — round-14: none existed; `Application.put_env` is banned in tests
  and Mix tasks call `AwsMachine.` directly at `find_nodes.ex:44,:48,:53` and
  `instance.status.ex:112`):** P0.1 threads a `provider:` opt into `DeployEx.Cloud`
  capability lookups and the descriptor registry accepts a test-only entry.
  **Entry point, named (v17 — round-15: "internal opt, never a CLI switch" was
  UNREACHABLE from a test: `OptionParser.parse!` SILENTLY DROPS undeclared switches
  (MEASURED, Elixir 1.17.3), so a test passing `--provider=fake_lossy` to
  `find_nodes.ex:67-79` gets `[]` and exercises the DEFAULT `:aws` identity encoding —
  passing VACUOUSLY, the exact defect this test exists to kill; and `instance.status`'s
  filter path takes no opts at all, `display_instance_details/2` → `find_instances_by_tags/1`
  at `:106,:112`):** each swept caller's filter/post-verify path is promoted to a
  `@doc false` public function taking `opts` (repo precedent:
  `Mix.Tasks.Ansible.Setup.derive_branch/2`, `ansible.setup.ex:243-244`) and the test
  drives THAT. An additive undocumented `--provider` switch is also permitted (§11 allows
  additive flags — P0.0 already adds `--render-dir`), but the `@doc false` entry is primary
  because it needs no CLI surface. **Non-vacuity is asserted:** the fake descriptor RECORDS
  that it was consulted and the test FAILS if it wasn't, so a dropped opt fails instead of
  going green. This one seam serves the encoding test, §5.1 gate 5's fake `Machine`,
  and the P0.2 conformance tests. The test-only descriptor DELEGATES its `inventory`/file-set slots to
  `Providers.Oci` and overrides only `capabilities.machine` (v19 — gate 5 needs OCI's file
  set together with a FAKE machine, and one selector must serve both without contending).
  **It ALSO selects the `PrivFileSet` across the six copy paths (v18 — round-16: file-set selection is not a capability lookup, so gate 5 had the
  same unreachable-entry defect v17 fixed for the encoding test), which means
  `terraform.build`/`ansible.build` DECLARE the additive `--provider` switch
  (`terraform.build.ex:100-117` and `ansible.build.ex:69-87` are `switches:`-mode, which
  silently drops undeclared flags; §11 permits additive flags). Owner: P2.1, where gate
  5's `:oci` fixture first makes it load-bearing (v19). NO alias — `p` is free in both
  today but `deploy_ex.ssh.ex:85` already binds `p: :pem`, so the switch stays long-form
  only.**
  Minimum caller set at P0: `find_nodes` (filter list, `find_nodes.ex:86-95`) and
  `instance.status` (regex arm, `instance.status.ex:107-110`). The §6.1 inventory
  group/hostvar composition joins at **P4 Done** (v16 — the static generator does not
  exist until P4.1; at P0 AWS inventory is still the `aws_ec2` plugin). Pinned clauses: unknown-key round-trip
  (`SetupComplete`), `Group = "CFX Web"` and `GitBranch = "feat/foo"` survival,
  `feat/foo` vs `feat_foo` post-verify rejection, `%Regex{}` degrading to full-fetch +
  post-verify. (Only `Cloud.Machine`'s tag-filter/tag-CRUD callbacks and
  `Cloud.ObjectStore.tag` carry canonical tags — `Infrastructure` and `Security` have no
  tag argument, so "the four behaviours" was the wrong scoping.)
- **(v13 — round-11 blocking finding) FILTER VALUES ARE MATCHERS, not scalars.** The
  live AWS filter API is a LIST of `{key, matcher}` where matcher is
  `scalar | [scalar] | Regex.t()` (`aws_machine.ex:372-380` — `has_tag?/3` has a
  `%Regex{}` arm), and a live caller depends on the regex arm:
  `instance.status.ex:107-110` passes `{"InstanceGroup", ~r/#{Regex.escape(app_name)}/}`
  because the terraform tag value is `"<snake_app>_<env>"`
  (`modules/aws-instance/main.tf:647`) — an exact-match spec returns ZERO instances for
  every ASG-path instance. So `Cloud.Machine`'s filter argument is typed
  `[{String.t(), scalar | [scalar] | Regex.t()}]`; only EXACT scalar/list matchers may be
  pushed down into a provider-native query, and non-literal matchers (regex) are
  evaluated CLIENT-SIDE against the decoded canonical map — the same post-decode pass the
  slug pre-filter already requires (under a lossy encoding a regex cannot be slugified,
  so it degrades to full-list fetch + post-verify). P3 adds
  `mix deploy_ex.instance.status <app>` to its live AWS smoke and a unit pin asserting a
  `%Regex{}` `InstanceGroup` matcher still matches `"<app>_<env>"`.

On NON-AWS providers, inventory group/hostvar composition consumes the DECODED canonical
tags (via the static-inventory generator, §6.1) so group names stay provider-independent;
AWS keeps its frozen `aws_ec2` plugin reading raw tags — identity encoding, so the two
agree (v13 scope fix).

**3.0.3 — Provider descriptor.** Each provider is one module
(`DeployEx.Cloud.Providers.<Name>`) declaring: capability impl map (feeds the §3.1
dispatcher), config schema (NimbleOptions, validated at TASK START — §3.5), backend
template id
(§5.5), completion-marker strategy (§6.3), inventory strategy + template path + rendered
filename (§6.1),
default SSH user (§3.5), CLI adapter
(§3.4). Registering a provider = one descriptor module + one dispatcher entry + that
provider's rows in the small per-provider data tables a train also touches (v12,
honest census): terraform address table (§5.4), resource-type map (§5.3),
`full_setup` command list (P4.5), TUI provider enum (P4.6), ToolInstaller (P3.3), its
getting-started guide + rows in the provider-coupled `guides/` reference docs + CI secret
list (P4.6 does this for OCI), its `PrivFileSet` source→dest entries (§5.1) + one gate-3
per-PR clause + one gate-5 fixture row (v14) + its §3.0.6 omitted-variable DENY LIST
(v17 — fail-open if forgotten, so it must be on the census), its `encode(HCL) ≡
decode(Elixir)` pin if its encoding is lossy (v18), and PROMOTING its column
in `2026-08-03-provider-columns.md` from ASSUMED paper to implemented truth (v13). The
descriptor is where provider-specific CHOICES live; the tables are mechanical rows. Single
owner for the inventory TEMPLATE PATH and RENDERED FILENAME: the descriptor's inventory
slot declares both (v16 — was half-split);
the §5.1 registry READS it (v13 — was double-homed).

**3.0.4 — Optional capabilities, portable defaults.** Mechanisms that exist on some
providers only are OPTIONAL capabilities with a portable default: object tagging
(S3-only; portable default = key-prefix encoding — AWS keeps tagging FROZEN for compat,
§3.3); tag-write completion markers (portable default = bucket-object marker, already
IAM-granted everywhere ObjectStore works, §6.3). New providers get the portable default
unless their train justifies the native mechanism.

**3.0.5 — Shared CLI runner.** One `DeployEx.Cloud.CliRunner` (exec via
`DeployEx.Utils.run_command_with_return/3`, Jason parse, fixture-test harness) with thin
per-provider adapters that supply the arg list INCLUDING the JSON flag — `oci`/`aws`/`az`
take `--output json`, `gcloud` takes `--format=json` (v13: the runner knows NO provider
flags; baking `--output json` in would leak an OCI-ism into the shared layer, the CLI
instance of §3.3's no-S3-ism rule). `Cloud.Oci.Cli` is the first adapter; `gcloud`/`az`
are future descriptor slots. Built in Phase 3 with the first consumer — shared-by-design,
not speculative code.

**3.0.6 — Variables sets omit unimplemented features (v14 — promoted out of a CDN
aside).** A provider's terraform variables set OMITS every feature that provider does not
implement. Enforcement, stated honestly (v15 — round-13: `terraform.build` never parses
tfvars, so it had no seam, and tofu only WARNS on an undeclared var in a var-file): the
check errors when a var-file sets a variable the ACTIVE provider's rendered set does not
declare. **Scoped to non-AWS providers (v16 — round-14 blocking finding: "the `:aws` set omits
nothing" does NOT imply the check is a no-op — undeclared vars survive in real `.tfvars`
files precisely BECAUSE tofu only warns, and `Config.terraform_default_args/1`
(`config.ex:81-97`) can inject `--var-file` on every invocation, so a stale var in an
existing `prod.tfvars` would start failing production applies).** Under `:aws` the check
does not run at all. Implementation is a per-provider DENY LIST of omitted variable NAMES
(`upload_buckets`, `cdn_*`, `resource_databases`) matched against the var-file — no HCL/
JSON parser needed, same signal (v16). It lives in `DeployEx.Terraform.parse_args/2`
(`terraform.ex:2-5,:15-17`), the ONE shared site — seven caller FILES / eight call sites (v18 recount):
`plan.ex:51`, `apply.ex:54`, `drop.ex:31`, `output.ex:28`, `replace.ex:35,:55` (an
apply-path), `init.ex:47`, `refresh.ex:27`. It resolves the `--var-file` value against
`Config.terraform_folder_path()` (tofu resolves it relative to the terraform folder, not
the Elixir cwd — v17) and RAISES (`Mix.raise`, precedent at `terraform.ex:116,:128`) rather
than changing the return type — so no call site gains error handling — while each of the
eight sites passes `opts[:directory]` as a NEW THIRD ARGUMENT (v19 wording fix: adding an
argument does touch all eight; a defaulted `\\ nil` third arg would be the fail-open trap
this plan rejects elsewhere). The third argument is the resolved terraform directory (v18 — `parse_args/2` never receives
`opts[:directory]`, which all seven tasks accept and pass as tofu's cwd, e.g.
`terraform.plan.ex:26,:38-40,:52`, and its `strict:` list discards `--directory`); an
UNREADABLE var-file is SKIPPED, not raised (v18 — the false-positive arm is worse than the
fail-open one here, and P2.2's negative pin covers both arms). Owner: P2.2, named in its item
text. Applies uniformly (OCI omits `upload_buckets`/`cdn_*`/`resource_databases`;
a future GCP set omits whatever it lacks).

### 3.1 Selection + dispatch

```elixir
def cloud_provider, do: Application.get_env(:deploy_ex, :cloud_provider, :aws)
```

The dispatcher is DERIVED from provider descriptors (§3.0.3): `DeployEx.Cloud` holds NO
capability/behaviour-module literals — the ONLY permitted literals are the `@providers`
registry keys, one line per provider (v14 wording fix: v13's "no hardcoded provider
literals" was unexecutable against a registry the same doc requires; an implementer would
either fail the pin or over-build module auto-discovery). Adding a provider = one `@providers` line + one descriptor module (DISPATCHER cost only
— the full registration census in §3.0.3 is larger; v18):

```elixir
defmodule DeployEx.Cloud.Providers.Aws do
  @behaviour DeployEx.Cloud.Provider
  def capabilities, do: %{machine: DeployEx.AwsMachine,
                          object_store: DeployEx.Cloud.S3ObjectStore,
                          infrastructure: DeployEx.AwsInfrastructure,
                          security: DeployEx.AwsSecurityGroup}
  # v13: `security` points at the LEAF module. There is no `Cloud.Aws.Security` façade —
  # `AwsSecurityGroup` absorbs `AwsIpWhitelister`'s two ExAws calls at P0.2, after which
  # `aws_ip_whitelister.ex` holds NONE, so it leaves the P0 expected-ExAws-file list with
  # that same commit (v17 — leaving it listed would let a half-done absorption pass).
  def config_schema, do: @schema        # NimbleOptions, validated at TASK START (§3.5);
                                        # the :aws schema is permissive by contract
  def backend_template, do: :s3         # §5.5 slot
  def completion_marker, do: :ci_tag    # §6.3 slot
  def inventory, do: %{strategy: :aws_ec2_plugin,
                       template: "ansible/aws_ec2.yaml.eex",   # source path
                       filename: "aws_ec2.yaml"}               # rendered name
                                        # §6.1 slot; SINGLE owner of BOTH (v15 — two of
                                        # the six census sites consume the TEMPLATE path,
                                        # `ansible.build.ex:222` + `priv_renderer.ex:157`,
                                        # so one field couldn't source them). The §5.1
                                        # registry READS these. Non-AWS: :static_generator
                                        # + `providers/<name>/<name>.yaml.eex`.
  def default_ssh_user, do: "admin"     # §3.5 slot (v14); OCI per spike S3
  def cli_adapter, do: nil              # §3.4 slot
end

defmodule DeployEx.Cloud do
  @providers %{aws: DeployEx.Cloud.Providers.Aws, oci: DeployEx.Cloud.Providers.Oci}
  # capability lookup reads the descriptor; a capability the descriptor omits =>
  # {:error, ErrorMessage.not_implemented(...)}. OCI's descriptor fills per-phase:
  # object_store P1; backend_template + completion_marker P2 (default_ssh_user decided
  # by spike S3 at P2, threaded P3.3); machine/infrastructure/security + cli_adapter P3;
  # inventory (strategy/template/filename) P4.
end
```

- Missing capability → `{:error, %ErrorMessage{code: :not_implemented}}`; tasks surface it
  and exit 1. OCI ships incrementally with honest errors.
- Test override via injected impl args (existing DI style, `ProjectContext.type/1`
  pattern); never `Application.put_env` in tests.

### 3.2 Behaviours — MVP set only (v2 scope trim)

Phase 0 defines and conforms ONLY the four capabilities Phases 1–4 consume:

| Behaviour | Extracted from | OCI impl |
|---|---|---|
| `Cloud.Machine` — find/describe by TAG FILTER LIST (§3.0.2 matcher types, v14 — not a map: `find_nodes.ex:71,:86-97` builds a LIST via `Keyword.get_values(:tag)`, and a map would silently turn today's AND-semantics `--tag Env=a --tag Env=b` → `[]` into "returns Env=b"), start/stop/terminate/run, IP lookup (ipv6-first), tag CRUD | `AwsMachine` | `oci` CLI |
| `Cloud.ObjectStore` — get/put/delete/list(paginated)/upload_file/tag + bucket lifecycle (`create_bucket`/`delete_bucket`/`list_buckets` — needed by `create_state_bucket`/`drop_state_bucket`/`full_setup.ex:41`) | `AwsBucket` + `AwsManager` + S3 calls in `ReleaseTracker`/`TerraformState` | shared S3-compat impl (§3.3) |
| `Cloud.Infrastructure` — discover network/subnet/keys/image/instance-identity for ad-hoc launch | `AwsInfrastructure` | `oci` CLI |
| `Cloud.Security` — SG/NSG lookup + ingress authorize/revoke | `AwsSecurityGroup` + `AwsIpWhitelister` | `oci` CLI (NSG rules) |

NOT behaviour-ized in Phase 0 (round-1 R3 YAGNI finding — no Phase 0–4 Done criterion
consumes them): `AwsAutoscaling`, `AwsLoadBalancer`, `AwsDatabase`, `AwsDynamodb` stay
exactly as they are (AWS-only Tier-A wrappers); `QaNode`/`K6Runner` internal ExAws stays
put (QA/k6 are AWS-only until Phase 5). Their behaviours are extracted when their Phase-5
item is greenlit. On OCI, their tasks fail fast with `:not_implemented` via a provider
guard at task entry (small, explicit, per-task).

Behaviour design rules (blocking Phase-0 review criteria):
- **Normalized structs only** (`%Cloud.Instance{id, name, state, public_ip, ipv6,
  private_ip, tags, type, launched_at, qa_node?}` — `qa_node?` is REQUIRED, v15: derived
  from `tags["QaNode"]` at `aws_machine.ex:238`, consumed by `find_instance_details/3`'s
  filter at `:262-263`, which `deploy_ex.ssh.ex:150` sets unconditionally. THREE SEMANTIC
  clauses of `find_instance_details/3` are part of the callback contract, not incidental
  (v16 — round-14 added the first, the one whose loss is worst): results are restricted to
  (1) the PROJECT SCOPE `fetch_instances_by_tag("Group", opts[:resource_group] ||
  Config.aws_resource_group())` applied UNCONDITIONALLY at `aws_machine.ex:228-230` —
  unlike `resource_group_filter/1` (`:414-416`) which returns `[]` when the opt is nil, so
  an implementer flattening this into the uniform filter list would stay
  contract-conformant while making `deploy_ex.ssh`/`restart_app`/`download_file`/ebs/db
  tasks target OTHER PROJECTS' instances in the same account, undetectable on a
  single-project smoke; the P0.2 conformance test therefore includes a DECOY instance
  carrying a foreign `Group` tag — (2) `instanceState.name === "running"` and (3) non-nil
  `InstanceGroup` (`aws_machine.ex:240-241`) — these decide which hosts `deploy_ex.ssh`
  and `restart_app` target today, in files with zero test coverage, and the caller-sweep
  contract finds SHAPES but cannot recover a dropped FILTER. P0.2 conformance tests assert
  both); all XML/JSON parsing inside impls; caller-side
  parsers (`instance.status.ex:239-259`, `instance.health.ex:69-76`) move behind the seam.
- **Callbacks shaped by caller need** (e.g. `find_instance_details/3` — the call the
  helpers actually make at `deploy_ex_helpers.ex:163,:190`, returning rich
  `%Cloud.Instance{}` structs feeding `prompt_for_instance_choice`), not by EC2 response
  shape.
- **Caller-sweep transition contract (v7 — the raw-map consumer census is ~15 files, not
  2):** map-`Access` on a struct raises, so EVERY commit that normalizes a producer's
  return shape sweeps ALL of that producer's callers in the SAME commit. The caller
  census is grep-defined at execution time — `grep -rn "AwsMachine\." lib/` (39 raw
  lines incl. aliases) **UNION the INTRA-MODULE consumers inside `aws_machine.ex` itself,
  which a module-qualified grep is structurally blind to (v17 — round-15 blocking finding:
  that file contains exactly ONE `AwsMachine.` string, yet holds nine internal consumers of
  the producers P0.2 normalizes — `:17`/`:45` `wait_for_started`/`wait_for_stopped` →
  `find_instances_by_id` → `instance_started?/1` at `:68-70` reading
  `instance["instanceState"]["name"]`; `:274` `find_instance_ips` → `find_instance_details`
  then `&1[:ipv6] || &1[:ip]`; plus `:94,:112,:230,:286,:330,:344,:421`. The trap:
  `find_instance_ips/3`'s OWN return contract is unchanged, so sweeping its callers — which
  the grep DOES see, e.g. `deploy_ex.ssh.ex:151` — finds nothing to edit while its BODY
  ships broken, raising Access-on-struct for every AWS user running `mix deploy_ex.ssh
  <app>` at the P0.2 merge, caught by no gate: neither file has tests and `deploy_ex.ssh`
  is not smoked until P3)** plus the raw-shape readers it feeds (measured concentration: `ansible.setup.ex
  :213-235`, `load_balancer.health.ex:100-127`, both ebs-snapshot tasks (`:93-117`,
  `:161-181`), `grafana.ex:16`, `qa.cleanup.ex:83,:113`, `qa_node.ex:359,:451,:1088`,
  `k6_runner.ex:130`, `instance.health.ex:64-188`, `instance.status.ex:112,:126-129`,
  `select_node.ex:57`, `find_nodes.ex:44-53`) — note these concentrate in files with ZERO
  test coverage today. NO legacy raw-map function survives P0.2 **on the normalized
  producers**; there is no dual-shape transition period there.
  **One documented split (v15 — round-13 finding):** `QaNode.build_qa_node_from_instance/1`
  (`qa_node.ex:945-965`, reads `instance["tagSet"]`, `instance["instanceState"]["name"]`,
  `get_in(instance, ["placement","availabilityZone"])`) has TWO producers — the
  P0.2-normalized `AwsMachine.find_instances_by_id` (via `ansible.setup.ex:210-213`) and
  QaNode's OWN P5-frozen `ExAws.EC2.describe_instances` (`:824,:870,:885`). It cannot be
  both swept and frozen. Resolution: `ansible.setup` stops routing through it — but it
  consumes that output TWICE, so the split must carry BOTH values (v16 — round-14: v15
  named only the limit pattern and would have silently dropped release-SHA pinning).
  `resolve_targets/3` (`ansible.setup.ex:187-201`) feeds `ansible_limit_pattern/1` AND
  `derive_branch/2` (`:200`, reads `&1.git_branch`, `:244-262`), and `targets.branch`
  drives `resolve_release_shas/3` — whose nil clause (`:264`) yields NO
  `target_release_sha` extra-var (`build_release_extra_vars/2`, `:176-181`), so a dropped branch silently unpins the QA
  release. So (ONE shape — v17, v16 stated it two ways): the id path produces
  `{instance_id, git_branch}` TUPLES from `%Cloud.Instance{}` (`{i.id, i.tags["GitBranch"]}`);
  `resolve_targets/3` builds the id-path limit pattern LOCALLY (`"#{id}*"`) rather than
  calling `QaNode.ansible_limit_pattern/1`, whose only head matches
  `%QaNode{instance_id: ...}` (`qa_node.ex:230-233`) and would raise on the new shape;
  `derive_branch/2`'s per-element ACCESSOR (`& &1.git_branch`, `ansible.setup.ex:247`)
  gains a `{_id, branch}` case beside the struct read — the function itself is ONE clause
  over a LIST, not a multi-head (v18 cite correction), so the existing pin at
  `test/mix/tasks/ansible_setup_test.exs:68-110` keeps passing unmodified; and the id-path
  patterns are built from `id_nodes` BEFORE the `++` at `:193`, since `:197` maps
  `ansible_limit_pattern/1` over the merged list and PRESERVES the multi-instance
  "Conflicting GitBranch" `Mix.raise` (`:260`);
  `verify_instances_found/2` (`:234-241`, reads `&1["instanceId"]`) is swept with them;
  `derive_branch/2` joins the P0.2 sweep list with a unit pin driven from the new
  producer. `build_qa_node_from_instance/1` then becomes private-to-QaNode, staying raw
  until its P5 item.
- **Behaviours filter by the §3.0.2 tag filter LIST only** (never provider-native filter
  syntax, never a bare map — v14) — **canonical tags are the portability contract, via the
  §3.0.2 encoding layer** (v11
  — raw provider tags are NOT portable; GCP labels reject `Group`'s spaces/caps and
  `GitBranch`'s slashes). Canonical keys: `Group`/`Environment`/`ManagedBy`/`Type`/
  `InstanceGroup`/`QaNode`/... as OCI freeform tags; behaviours filter by tag map only.
- **Region/bucket flag threading (v2–v6):** the census:
  - `--aws-region`, working, 9 tasks: `deploy_ex.upload.ex:68`, `terraform.build.ex:107`,
    `qa.create.ex:651`, `qa.deploy.ex:487`, `release.ex:99`, `restart_machine.ex:52`,
    `ansible.setup.ex:331`, both ebs-snapshot tasks.
  - `--aws-release-bucket`, working, 4 tasks (v6 — these are LIVE overrides via
    `put_new`/`opts[...] ||`): `upload.ex:34,:69`, `release.ex:50,:100`,
    `qa.create.ex:454,:652`, `qa.deploy.ex:159,:488`. Plus `ansible.build.ex:79` where
    the opt is currently DEAD after its `put_new` at `:44` — preserve, don't "revive".
  - Moduledoc drift, fixed in P0.3 with no switch changes:
    `view_current_release.ex:47-48` / `list_app_release_history.ex:53-54` already use
    neutral `--region`/`--bucket`; `upload.ex:23` and `release.ex:41` document
    `aws-bucket` vs actual `aws_release_bucket` switch (v6).
  Additional census notes (v7): `find_nodes.ex:71-80` (+ `ssh`/`restart_machine`
  `--resource-group`) already use NEUTRAL `region:`/`resource_group:` switches — keep
  working, add one already-neutral task to the pinning test; `instance.health`'s
  documented `--region` has no declared switch (`:50-55` — CLI-dead today, record as dead
  like ansible.build's bucket flag); `terraform.build.ex:17` (`aws-bucket`) and `:18`
  (`aws-log-bucket`) document flags that have never existed (switch list `:102-116` has
  neither) — P0.3 moduledoc-fix list gains both (v8).
  All WORKING flags keep working. The threading rule covers BOTH flag families on
  behaviour-consuming tasks: flags thread as neutral `region:`/`bucket:` opts honored by
  impls over their config defaults; only the `Keyword.put_new(:aws_*, ...)` defaulting
  moves into impls. The task-level pinning test covers region AND bucket overrides (v6).
  Task-side storage-defaulting sites that move impl-side in Phase 1 are a GREP-DEFINED
  class (v7/v8; predicate WIDENED v15 — round-13 blocking finding): every
  `Config.aws_region()` / `Config.aws_release_bucket()` / **`Config.aws_release_state_bucket()`**
  call — the third key has 3 live defaulting sites the old predicate could not see
  (`terraform_state.ex:40` → impl-side-permanent after P0.2 absorption;
  `terraform.create_state_bucket.ex:28` and `drop_state_bucket.ex:23` → P1-moves, beside
  the region lines at `:29`/`:24` the allowlist already cites — so the gate was clearing
  those two tasks by their region default while their state-bucket default stayed
  task-side), with a
  FULL allowlist carrying per-phase attribution (v8 — the v7 predicate was unsatisfiable
  against the plan's own freezes; each entry names when it clears, so the gate is
  executable AND nothing silently escapes):
  - Moves impl-side at P1 (the gate's target set — MVP storage tasks/modules):
    `release_lookup.ex:196-197`, `ansible.rollback.ex:37-38`,
    `ansible.deploy.ex:301-302,:358-359,:371-372`, `ansible.setup.ex:267-268`,
    `list_available_releases.ex:24-25`, `view_current_release.ex:25-26`,
    `list_app_release_history.ex:27-28`, `deploy_ex.upload`, `deploy_ex.release`,
    `terraform.create_state_bucket.ex:29`, `terraform.drop_state_bucket.ex:24` (bucket
    tasks are ObjectStore consumers per §5.5/P1.3 — v9). Single move timing: P0.3 wires
    flag THREADING only; the storage `put_new` moves land here at P1 with the ObjectStore
    port — no dual timing (v9).
  - Impl-side permanently (the gate ACCEPTS hits here — these ARE the config readers):
    the three ExAws-backed impl files (`aws_machine.ex`, `aws_infrastructure.ex`,
    `aws_security_group.ex`) + `S3ObjectStore`. `aws_ip_whitelister.ex` is NOT on the list
    (v16): P0.2 absorbs its two calls into `AwsSecurityGroup`, after which it holds neither
    ExAws calls nor a defaulting site — leaving it listed would let a leftover
    `Config.aws_region()` there pass the P1 grep. The
    P0.2-absorbed modules' defaulting sites (`aws_bucket.ex`, `release_tracker.ex`,
    `terraform_state.ex:42` — `aws_manager.ex` is absorbed too but has no defaulting
    sites, region/bucket are caller-passed) migrate INTO that set at P0.2 — a P1 hit
    remaining in an absorbed module is a gate failure by design (v9).
  - Exempt permanently (template-param feeders / inline ExAws):
    `config.ex` itself, `terraform.build` (module attrs `:5,:7` + the state-bucket/
    log-bucket (`:32`)/lock-table `put_new`s at `:33`+ — v16 census), `ansible.build`
    (`:42-45`), `priv_renderer.ex`; both ebs-snapshot tasks + both state-LOCK-table
    tasks (AWS-only per §5.5).
  - Clears at P3 (machine-ops sweep — all four tasks are in P3.2):
    `deploy_ex.ssh.ex:155`, `find_nodes.ex:37`, `instance.health.ex:63`,
    `instance.status.ex:237` (v9).
  - Clears at P4 (ansible.setup OCI port): `ansible.setup.ex:189` — the `--instance-id`
    machine-lookup path in `resolve_targets`, feeds `QaNode.ansible_limit_pattern` (v9).
  - Clears at P5 with its item (frozen until then per §3.2/§4): `qa_node.ex`,
    `k6_runner.ex`, `qa.create`, `qa.deploy`, `aws_autoscaling.ex`,
    `aws_load_balancer.ex`, `aws_database.ex`, `aws_dynamodb.ex`.
  The P1 exit runs the grep and requires EVERY hit to be in the P1-moved set (now
  impl-side) or in an attributed bullet above; each later phase re-runs it and clears
  its own entries. Doc-interpolation/module-attribute residuals in moved task files
  (`upload.ex:22-23`, `release.ex:40-41`) are attributed EXEMPT — display defaults in
  moduledocs, not runtime defaulting (v10). **Correction (v15 — round-13):
  `release.ex:6-7` is NOT exempt** — those attributes are consumed at `release.ex:50-51`
  (`Keyword.put_new(:aws_release_bucket, @default_aws_release_bucket)`), i.e. real
  compile-time-frozen runtime defaulting; it moves with the P1 set. A MIS-attributed hit
  is worse than an unattributed one: it passes the gate silently instead of triggering a
  plan amendment. An unattributed hit is a plan amendment,
  never an ad-hoc pass (v9).

### 3.3 Object storage: S3-compat is impl #1, not the contract (v11 reframe)

The `Cloud.ObjectStore` BEHAVIOUR is provider-neutral; `S3ObjectStore` is its
first implementation, parameterized by per-provider endpoint config, and covers AWS +
OCI (and, paper-column, GCS via its S3-interop XML API + HMAC keys). Azure Blob has NO
S3-compatible API — its future train adds an `ObjectStore.AzureBlob` impl (az CLI or
REST) behind the same behaviour; nothing upstream changes. No S3-ism may leak into the
callbacks (4-column check, §3.0.1).

OCI: S3-compat endpoint
(`https://<namespace>.compat.objectstorage.<region>.oraclecloud.com`, Customer Secret
Keys). [ASSUMED — spike S1.] ExAws per-call `host`/`region` overrides carry it (per-call
`ExAws.request(op, region: ...)` is already repo-wide practice; host-override signing
against OCI is what S1 proves). Ports in one move: release upload/list, release tracker,
TF state reads, state-bucket bootstrap, (later) QA state + k6 registry.

Object tagging is an OPTIONAL capability (§3.0.4): S3-specific (GCS has no object tags;
Azure blob tags differ). AWS keeps `put_object_tagging` for the qa=true release marker —
FROZEN behavior (`aws_manager.ex:57`, `release_uploader.ex:134-159`). **On every other
provider the `tag` callback is a documented NO-OP (v13 correction — "key-prefix
encoding behind the behaviour" overstated it): the qa marker is ALREADY carried in the
object key by `ReleaseUploader.State`** — `release_path_prefix/2` (`state.ex:136-138`)
emits `qa/<app>/…` from `release_prefix/1` (`:129-133`), consumers filter on that prefix
(`state.ex:85-94`, `release_lookup.ex:191-192`, inventory `release_prefix` at
`aws_ec2.yaml.eex:30-31`), and `upload_release/2` (`release_uploader.ex:100-105`) hands
ObjectStore an already-prefixed key — so there is nothing for an impl to encode. The
`qa` object TAG itself has ZERO readers repo-wide (no `get_object_tagging` anywhere in
`lib/`); it is a write-only AWS artifact kept for compat. S1 still probes tagging, but
informationally only.

Known-risky S3-compat calls (S1 checklist): multipart `S3.upload` streaming
(`aws_manager.ex:49`), `delete_multiple_objects` (`aws_bucket.ex:41`), conditional
writes (for S2), bucket lifecycle + compartment placement. Fallback pre-designed:
multipart → single-put loop for <5GB.

### 3.4 CLI runner (shared) + OCI adapter

`DeployEx.Cloud.CliRunner` (§3.0.5) — exec via
`DeployEx.Utils.run_command_with_return/3`, JSON flag supplied by the ADAPTER's arg list
(§3.0.5 — the runner knows no provider flags; v14 half-applied-edit fix) and
`stderr_to_stdout: false` passed via `extra_opts` (v15 — `run_command_with_return/3`
defaults it TRUE at `utils.ex:76`, so any `oci` python warning would corrupt the Jason
parse; `extra_opts` wins the `Keyword.merge` at `:80`), Jason-parsed;
`Cloud.Oci.Cli` is its first thin adapter (gcloud/az are future descriptor slots, no
code now). Auth: `~/.oci/config` profile
(config `oci: [profile: ...]`). Testing: committed JSON fixtures + injected fake runner
(UpdateValidator parser-test style). Preflight: clear ErrorMessage when `oci`/`~/.oci/
config` missing; `ToolInstaller` learns `oci` CLI (it already installs ansible/boto3,
`tool_installer.ex:124,:177`).

### 3.5 Config surface

```elixir
config :deploy_ex,
  cloud_provider: :oci,
  oci: [
    region: "us-phoenix-1", profile: "DEFAULT",
    compartment_id: "ocid1.compartment....",
    namespace: "...",                    # object storage namespace
    availability_domain: nil,            # nil = first
    base_image: [os: "Canonical Ubuntu", version: "24.04"],  # or custom image OCID
    shape: "VM.Standard.E5.Flex", shape_ocpus: 1, shape_memory_gbs: 8,
    # storage/naming keys P1 needs (v15 — a STRICT :oci schema would otherwise reject
    # exactly the keys §3.3's port requires):
    release_bucket: nil, release_state_bucket: nil, log_bucket: nil, log_region: nil,
    resource_group: nil        # nil => fall back to the aws_* value (cross-provider
                               # source until a provider needs its own)
  ],
  ssh_user: "admin"   # neutral OVERRIDE; when unset, falls back to the descriptor's
                      # default_ssh_user slot (§3.0.3) — AWS "admin" (preserves ssh.ex:2),
                      # OCI per spike S3 ("ubuntu" on Ubuntu images). v14: a single global
                      # default would be wrong on the second provider.
```

Provider config namespaces generalize as-is (`config :deploy_ex, :gcp, [...]` later);
each provider's NimbleOptions schema lives in its descriptor (§3.0.3) and validates at
TASK START (single wording — v14; not "dispatch entry", because terraform tasks shell out
to tofu and may never hit a capability lookup, and the promise here is that a typo'd
`compartment_id` fails fast, not mid-apply).
**The `:aws` schema is PERMISSIVE by contract (v14 — round-12 blocking finding):** today's
config is a FLAT `Application.get_env(:deploy_ex, key)` namespace (`config.ex:4-90`)
carrying non-AWS keys (`iac_tool`, `env`, `tui_enabled`, `llm_provider`,
`terraform_default_args`, `terraform_backend`, `deploy_folder`, `qa_state_prefix`) and
legitimately-nil keys (`aws_iam_instance_profile:48-50`, `aws_security_group_id:64-66`).
The validation HOOK is `DeployExHelpers.check_valid_project/0` (v15/v16 — the only
near-universal task entry point: 58 of 69 task files call it. MEASURED non-callers:
`deploy_ex.ex`, `find_nodes`, `load_test`, `load_test.init`, `qa`, `restart_app`,
`restart_machine`, `start_app`, `stop_app`, `terraform.generate_pem`,
`terraform.restore_database`. v16 correction: SIX of those are provider-DEPENDENT and
named in this plan's own phases — `find_nodes`/`restart_machine`/`restart_app`/
`start_app`/`stop_app` are in P3.2 and `generate_pem` is in the P2 smoke — so "exempt by
construction" was false. Those six ADD the `check_valid_project/0` call as part of their
own phase item — `generate_pem` attaches to P2.4, which already owns its §5.3 resource-type
reads (v17); the failure path is explicit `Mix.raise(to_string(error))`, since a bare
`with :ok <- ...` would exit 0 silently (v17) — (smallest diff; it is already the near-universal entry). The genuinely
exempt remainder is the four dispatcher/umbrella tasks `deploy_ex.ex`, `deploy_ex.qa.ex`,
`load_test.ex`, `load_test.init.ex`, plus `terraform.restore_database` which clears with
its P5 DB item). Its INPUT per provider (v15): `:aws` reads
`Application.get_all_env(:deploy_ex)` (the FLAT legacy namespace); every other provider
reads `Application.get_env(:deploy_ex, <name>)`, absent ⇒ `[]`, not an error.
`nimble_options` must be added to `mix.exs` deps — today it is only a transitive lock
entry via `finch` (`mix.lock:32`), not a direct dep (v15).
NimbleOptions rejects unknown keys by default and `required: true` would reject working
setups — so the `:aws` descriptor's schema accepts everything that works today
(`keys: [*: [type: :any]]`, no `required`), and P0.1 carries a unit pin: task start with
today's full flat env PLUS one arbitrary unknown key returns no validation error. Strict
per-key schemas are for NEW provider namespaces (`oci: [...]`), which have no legacy.

- All `aws_*` keys/functions unchanged. Neutral accessors (`Config.region/0`,
  `release_bucket/0`, `resource_group/0` — verified no IN-REPO name collisions today)
  delegate per active provider. No deprecation warnings. **Cross-provider name hazard
  recorded now (v14):** on Azure, "resource group" is a mandatory containing SCOPE for
  every resource, unrelated to this repo's tag-group meaning — so `Config.resource_group/0`
  will read as the Azure concept to an Azure implementer. Logged in
  `2026-08-03-provider-columns.md` as a naming collision; the Azure train either renames
  to `Config.group/0` then or lives with the documented clash. Renaming now would churn
  12 AWS call sites for a provider with no train.
- `ssh_user` threading: `ansible.cfg.eex:2` currently hardcodes `remote_user = admin` —
  it becomes a templated assign defaulting `"admin"`, render-identical for AWS (harness-
  verified). Full `"admin"` hardcode census (v9): P3.3 sweeps `ssh.ex:2,:101` (jump
  host), `deploy_ex.ssh.ex:291,:296` (printed/run ssh command), `download_file.ex:89`
  (scp); `qa.create.ex:1191` + `load_test.exec:152`/`load_test.upload:148` clear with
  their P5 items.
- TUI wizard: provider field + neutral labels for 24 of the 25 AWS-labeled `input(...)`
  fields in `lib/deploy_ex/tui/wizard/command_registry.ex` (`:auto_pull_aws` at `:609`
  stays AWS-labeled — v15 count sync with P4.6) — Phase 4.

---

## 4. MVP line

**MVP (Phases 0–4):** on OCI — bootstrap state storage; `terraform.build/init/apply` a full
environment (instances, VCN, NSG, identity, buckets, reserved IPs); `ansible.build/setup/
deploy`; `deploy_ex.upload`; `deploy_ex.ssh` + `ssh.authorize`; `find_nodes`/`select_node`;
`restart_app`/`restart_machine`; `instance.health`/`instance.status`; release
view/rollback; monitoring stack (prometheus file_sd + loki on OCI object storage);
**generated GitHub Actions CI workflows** (v2); `full_setup` end-to-end (v2). Single
instances + reserved public IPs; apt-based images.

**Explicitly post-MVP (Phase 5, each gated on real need, honest `:not_implemented` until
then):** QA node subsystem; k6 load testing; autoscaling (instance pools); managed load
balancer; `save_ami` → custom-image capture (+ bucket-hosted image pointer replacing SSM);
managed database (incl. `dump/restore_database` AND `terraform.show_password`);
a per-provider CLUSTER-DISCOVERY strategy (v17 — `EC2Tag` is AWS-only; non-AWS MVP
documents Gossip/DNSPoll, per §1); EBS-snapshot tasks (AWS-only permanently unless
demanded); **CDN upload buckets**
(`aws-s3-upload-bucket` module: CloudFront + signed key groups) — AWS-only permanently
unless demanded; see §3.0.6. For OCI the omitted set is `upload_buckets`/`cdn_*` AND
`resource_databases` (`variables.tf.eex:44` — v7).

Rationale: QA subsystem alone is 1218L shaped by EIP/ELB/AMI mechanics; porting before core
deploy works is inverted priority. Mika's QA workflows run against the AWS prod cluster and
keep working unchanged through every phase (Phase-0 exit gate includes a live AWS QA smoke).

---

## 5. Terraform Strategy

### 5.1 Provider-aware priv distribution (v2 — round-1 R2 blocking finding)

New template layout (additive; zero AWS-path files move or change hash):

```
priv/terraform/            # AWS files — UNTOUCHED
  providers/oci/           # providers/variables/instance/network/identity/bucket/
                           # outputs/key-pair (.eex + statics) + modules/oci-instance/
                           # (v11/v12: ALL non-AWS providers live under providers/<name>/
                           # — gcp/, azure/ land beside oci/ with ZERO changes to the AWS
                           # complement rule or gates; each adds only its own additive
                           # file-set entries, derived by one generic rule: non-AWS
                           # ansible set = shared base ⊕ providers/<name>/ variant-wins;
                           # terraform/CI sets = provider-specific files only, shared
                           # CI scripts stay shared. v13 precision: gates 1,2,4,6 are
                           # provider-count-proof as written; gate 3's per-PR clause and
                           # gate 5 INSTANTIATE once per provider — one fixture row each,
                           # no rule rewrite)
priv/ansible/              # AWS files — UNTOUCHED
  providers/oci/           # oci.yaml.eex inventory, oci setup playbooks, roles/oci_cli,
                           # oci deploy_node script variants
priv/github-action*.yml.eex        # AWS CI — UNTOUCHED
priv/providers/oci/github-action*.yml.eex   # OCI CI variants
```

**Mechanism — a provider file-set registry** (`DeployEx.PrivFileSet`): maps
`cloud_provider` → an explicit allowlist of **source → destination entries** (v4 — a bare
path filter is not enough; non-rendered OCI files must FLATTEN into the locations ansible
and tofu actually resolve: `providers/<name>/roles/*` → `roles/*` (ansible `roles_path = ./roles`,
`ansible.cfg.eex:4`, cwd `./deploys/ansible` per `ansible.setup.ex:140`/
`ansible.deploy.ex:129`), `providers/<name>/setup/*` → `setup/*` (enumerated at
`ansible.setup.ex:126-130`), `providers/<name>/*.tf(.eex)` → terraform root (tofu loads
root-level `.tf` only), `providers/<name>/modules/*` → `modules/*`). AWS = everything not
under a `providers/` directory — ONE complement rule, written once, valid for every
future provider (v11; the v4 `oci/`-exclusion rule would have needed re-touching per
provider, repeating the leak risk each time). For OCI, same-name variant entries (e.g. `letsencrypt`) REPLACE the
shared entry — merge semantics are "variant wins", defined in the registry, and the OCI
sync-equality gate asserts against this merged expected tree. ALL SIX priv copy/render
paths (§1 hazard 3 census) consume the registry, **including
`PrivRenderer.render_to_temp` itself (`priv_renderer.ex:45,:132`) — the filter lives at
that choke point, NOT only in ChangePlanner, so `export_priv` (which copies all temp files
with no planner, `export_priv.ex:71-93`, and builds the manifest from the temp tree,
`:96-111`) is covered too (v4)**:

| # | Copy path | Today | Change |
|---|---|---|---|
| 1 | first-run terraform seed | whole-tree `cp_r!` (`terraform.build.ex:122-141`) | seed only the provider's file set |
| 2 | first-run ansible seed | whole-tree `cp_r!` (`ansible.build.ex:91-113`) | seed only the provider's file set |
| 3 | ansible role sync (every build) | verbatim `cp_r!` (`ansible.build.ex:346-356`) | sync only the provider's roles, byte-equality asserted |
| 4 | `AnsibleRoles.sync/1` (every QA playbook run) | verbatim copy (`qa_playbook.ex:42`) | same provider-filtered sync as #3 |
| 5 | template render | glob `*.eex` root-only (`terraform.build.ex:281-282`) | glob the provider set; OCI templates FLATTEN on render (`providers/oci/providers.tf.eex` → `./deploys/terraform/providers.tf`) so tofu, run in `Config.terraform_folder_path()`, reads them; PrivManifest records the flattened dest mapping; inventory filename (`ansible.build.ex:39`, asserted at `ansible.deploy.ex:97`/`ansible.setup.ex:120`/`ansible.ping.ex:25,:28`, AND hardcoded in the render path at `priv_renderer.ex:157-158` and the template-source path at `ansible.build.ex:222` — v6/v7) sourced from the registry, not hardcoded `aws_ec2.yaml` |
| 6 | export_priv / upgrade_priv temp tree | whole-tree copy (`priv_renderer.ex:45,:132,:360-364`) | PrivRenderer + ChangePlanner operate on the provider set only — OCI files invisible to an `:aws` user's upgrade flow (kills the jaro false-rename data-loss path, `change_planner.ex:109-191`) |

**Gates (all land in the PR that adds the first OCI priv file; CI-permanent):**
1. **Seeded-fixture zero-action** — a seeded `:aws` fixture runs `upgrade_priv` after a
   non-AWS provider's files exist in priv (v14 wording — the trigger is any provider,
   not OCI specifically) → ZERO planned actions; role sync → ZERO diffs.
2. **Fresh-project fixture** (v3/v5 — seeded fixtures short-circuit both `File.exists?`
   seed guards at `terraform.build.ex:122` / `ansible.build.ex:92`) — an EMPTY fixture
   runs `terraform.build` + `ansible.build` first-run seeding post-OCI-files and asserts
   the seeded trees match **the registry's AWS file set derived from CURRENT priv** —
   The `providers/*` predicate is a path-COMPONENT test (`"providers" in Path.split(rel)`),
   never a substring/prefix match — every AWS tree legitimately contains a rendered
   `providers.tf` at the terraform root (v13; gate 6 pins that classification).
   PATH-SET equality for all entries + byte-equality for NON-RENDERED entries only
   (rendered files' bytes are owned by the P0.0 harness; a rendered `ansible.cfg` can
   never byte-equal its `.eex` source — v8). No frozen pre-OCI baseline (v5). Zero
   `providers/*` paths (v11 wording — provider-count-proof). Covers the
   `full_drop` → `full_setup` re-seed route (`full_drop.ex:27`). Runs under P0.0's
   `--render-dir` mode, and the render dir MUST NOT pre-exist — the seed guards are
   `File.exists?(directory)` (`terraform.build.ex:123`, `ansible.build.ex:92`), so a
   harness that pre-creates it short-circuits the seed the gate exists to check; the
   task's own `mkdir_p` creates it (v18). (Else `terraform init` at `:90-93` creates
   `.terraform/providers/**`
   — a literal `providers` dir — tripping the wording; render-only also frees GATE 2 of
   the tofu dependency — v12/v13 wording: CI still installs tofu for P2.5's
   `tofu validate`).
3. **Role-sync byte-equality** (v3/v4/v6 — "zero NEW files" is insufficient; roles sync
   verbatim, so an EDIT to a shared role ships to every AWS user) — synced AWS role tree
   byte-equals the CURRENT `priv/ansible/roles` tree (pins sync fidelity; a base-commit
   freeze would fail on every future legitimate AWS role fix), PLUS the per-PR rule:
   `<provider>`-scoped PRs show ZERO diff under `priv/ansible/roles/**` AND
   `priv/github-action*` (v13: the glob covers the two verbatim-copied `.sh` scripts too,
   not just `*.yml.eex` — they have no other byte gate; and the clause is worded per
   provider, not OCI-specific, so future trains inherit it). Sync
   semantics stay
   ADDITIVE/overwrite-only exactly as today (`ansible.build.ex:355`/`ansible_roles.ex:24`
   never delete) — "byte-equals" applies to the synced set, never mirror-delete; a fixture
   containing a user-custom role asserts its survival (v6).
4. **export_priv fresh-fixture byte-equality** (v4/v5 — export bypasses the planner
   entirely) — `mix deploy_ex.export_priv` into an empty `:aws` fixture post-OCI-files
   matches **the registry's AWS file set derived from CURRENT priv** (path-set equality;
   byte-equality for non-rendered entries, per gate 2's v8 formulation; zero
   `providers/*` paths — v11) AND `.deploy_ex_manifest.exs` lists exactly that set (no frozen pre-OCI
   baseline — v5).
5. **OCI merged-tree equality** (v6/v12 — the variant-wins claim needs an owner) — an
   `:oci` fixture's seeded/synced tree matches the registry's merged variant-wins OCI
   set: path-set equality + byte-equality for NON-RENDERED entries (gate-2's v8
   carve-out applies here too); the GENERATED inventory file is produced via an injected
   fake `Machine` impl (§10 bans live-cloud calls in CI). Activates with the first OCI
   priv file (Phase 2, terraform set) and extends to the ansible role/setup variants at
   Phase 4.
6. **Registry classification unit test** (v12) — pins lexical edge cases to the right
   set: `priv/terraform/providers.tf.eex` (an AWS ROOT file whose name merely resembles
   the `providers/` dir convention) → AWS set, and its RENDERED output `providers.tf` →
   an allowed AWS output, not a `providers/*` leak (v13). Division of labor, stated: gates 1–5
   detect provider-file LEAKS into AWS trees; the P0.0 harness tree-diff detects AWS-file
   DROPS (a misclassifying registry passes its own gates — the harness is the
   independent oracle). Lands in P2.1.

Renderer duplication hazard: params built in BOTH `terraform.build.ex:50-86` and
`priv_renderer.ex:74-120` — Phase 2 extracts one shared params function (with the
determinism injection from P0.0) so assigns can't drift. Known divergences the extraction
must handle (v5): `db_password` (generated vs `"placeholder"`); **`pem_file_path` (v17):
`ansible.build.ex:198` passes the glob RESOLVED to a real `../terraform/<name>.pem` while
`priv_renderer.ex:142-144` passes the literal glob `"../terraform/<kebab>*pem"`, and P0.0
adds a third value (`RENDER_DIR_PLACEHOLDER.pem`) — three values for one assign. Gate 1 is
the only net on the PrivRenderer side, and it holds only because export/upgrade hash the
RENDERED temp tree (`export_priv.ex:55,:106-111`, `upgrade_priv.ex:79`), so gate 1's
fixture is export_priv-seeded**; and the group_vars loki assigns — `ansible.build.ex:172-173` passes `loki_logger_s3_region`/`bucket` SWAPPED
while `priv_renderer.ex:166-167` doesn't, harmless only because
`group_vars/all.yaml.eex:8-9` ignores both and reads `DeployEx.Config` directly. Treat
them as DEAD assigns; "fixing" the swap into the template would change AWS users'
rendered group_vars bytes (the P0.0 harness would flag it — don't fight the harness).

### 5.2 OCI resource mapping

| AWS today | OCI target |
|---|---|
| `aws_instance` + gp3 root | `oci_core_instance`, flex shape (`shape_config`) |
| VPC registry module (10.0.0.0/16) | plain `oci_core_vcn` + subnets + IGW + route table; same CIDR layout so `10.0.1.40/.50/.60` in group_vars keep meaning |
| security-group web module | `oci_core_network_security_group` + rules |
| `aws_eip` | `oci_core_public_ip` (reserved) |
| `aws_key_pair` + tls/local pem | same `tls_private_key`/`local_file`; pubkey via instance `ssh_authorized_keys` metadata |
| `iam.tf` role/profile | `oci_identity_dynamic_group` + `oci_identity_policy`: read release-bucket objects, write `release-state/*`, **instance-update grant for the `CloudInitComplete` freeform-tag write** (v4 — see §6.3; spike S5 tests instance self-tag-update; fallback = marker as bucket object write, already granted). No public-IP grant for instances — terraform attaches the reserved IP, instances never self-associate (v4, dead-grant fix) |
| log/release S3 buckets | `oci_objectstorage_bucket` |
| `data.aws_ami` debian-13 | data `oci_core_images` (Ubuntu platform) or custom-image OCID passthrough — spike S3 |
| ASG/launch-template/LB blocks | absent from `oci-instance` module (Phase 5) |
| EBS extra volume `/dev/sdh` | `oci_core_volume` + attachment, `/dev/oracleoci/oraclevdb` in cloud-init |

### 5.3 Elixir↔terraform data seam (v2 correction — round-1 R1 finding)

The seam is raw-tfstate reads by resource type + tag, NOT the outputs block:
- `terraform.generate_pem.ex:42-43` reads `tls_private_key` AND
  `get_resource_attribute(state, "aws_key_pair", "key_pair", "key_name")` — and §5.2's OCI
  row DELETES the key-pair resource (pubkey rides `ssh_authorized_keys` metadata), so
  there is no OCI resource type for that map row (v13, round-11 blocking finding —
  "works unchanged" was wrong). The `key_name` is also what names the PEM on disk
  (`key-pair-main.tf.eex:14-17` sets `local_file.ssh_key.filename` from it) and
  `ansible.build.ex:240` globs `terraform/<kebab-app>*pem` for it. OCI mechanism: the OCI
  `key-pair-main.tf.eex` synthesizes `local_file.ssh_key.filename` directly from
  `@pem_app_name` (same glob shape), and `generate_pem` reads the PEM filename from
  `local_file.ssh_key` + the private key from `tls_private_key` — a per-provider map row
  of `{resource_type, resource_name, attribute, :basename | :filename}` (v15 adds the
  resource NAME — `TerraformState.get_resource_attribute/4` requires it and it differs per
  row: AWS `"key_pair"` vs OCI `"ssh_key"`; v14 UNITS fix: AWS's
  `aws_key_pair.key_name` is a BASENAME and `generate_pem.ex:46` appends `.pem`, while
  OCI's `local_file.ssh_key.filename` already carries `.pem` — a two-element row would
  yield `<x>.pem.pem`). AWS row frozen at `{"aws_key_pair", "key_pair", "key_name", :basename}`.
  **Protection (v14 — round-12 blocking finding: v13 table-ized a live AWS path with no
  pin and no smoke):** §11's freeze list extends from addresses to these resource-TYPE
  strings; P2.4's byte-verbatim unit pin covers the §5.3 map rows as well as the address
  table; and `mix terraform.generate_pem` joins the P2 live AWS smoke (idempotent —
  `generate_pem.ex:53-54` prints "PEM file exists and is the same already").
- `TerraformState.get_resource_attribute_by_tag` (show_password → `aws_db_instance` —
  v4 type-name fix) → resource-type map entry per provider; DB lookup is Phase 5.
- `TerraformState.read_state/1`'s BACKEND dispatch (`terraform_state.ex:17-24`, literal
  `:s3` vs `:local` from the user-facing `Config.terraform_backend/0`, `config.ex:79`) is
  a fourth seam (v15): the key's value space is provider-dependent (§5.5's paper columns
  name native `gcs`/`azurerm`). It works for OCI by accident — OCI's backend IS s3-typed.
  Reconciliation: the descriptor's `backend_template` slot declares the tofu backend
  block; `Config.terraform_backend/0` stays the user override and its accepted value set
  becomes per-provider (validated by the descriptor's schema, §3.5).
- `TerraformState.find_instance_display_name` (`terraform_state.ex:158-177`, called via
  `get_app_display_name` from `qa_node.ex:576`) hardcodes resource type `"aws_instance"`
  AND `resource["module"] =~ app_name` — a FOURTH address/type coupling site. QA-only →
  Phase-5 address-map backlog, recorded here so the census is complete. (v3 cite fix)
- `outputs.tf.eex` nests under `output "instances"`; `terraform.ex:156-180` has ZERO
  callers (dead reader) — so NO cross-provider shape-parity test (v4 YAGNI cut): the OCI
  outputs file is written freely for human `tofu output` use; the dead reader is left
  untouched on AWS.

### 5.4 Address map (all three MVP sites; 4th QA-only site in §5.3 → Phase 5)

Three sites get the per-provider address table (v14 sentence repair): `terraform.ex:41-54`
(`build_target_string/1` — `--target` expansion), `terraform.ex:104-135` (instance/ASG
state parsing), and `terraform.replace.ex:67-73`. The SG literal at `:137-154`
(`security_group_id/1`) is CUT from that scope (v13): zero callers repo-wide, same YAGNI
basis §5.3 used for the dead outputs reader — AWS text stays frozen, no OCI row needed.
AWS strings frozen verbatim (state compat):
`:aws → module.ec2_instance["app"].aws_instance.ec2_instance`,
`:oci → module.oci_instance["app"].oci_core_instance.instance`. Each provider row carries
TWO types — instance and ASG (`terraform.ex:104-135` parses both;
`terraform.replace.ex:67-73` has both clauses). OCI's ASG entry is `nil` until P5
(instance pools), which the filter must treat as "yields `[]`", not as a missing row
(v14).

### 5.5 Backend + locking (spike S2 — blocks Phase 1 exit)

Backend choice is a provider-descriptor slot (§3.0.3, v11): aws = `s3`+DynamoDB
(frozen); oci = below; future paper columns: gcp = native `gcs` backend, azure = native
`azurerm` backend — both first-class in tofu, so OCI's compat workaround is the hard
case, not the pattern.

Preferred for OCI: terraform `backend "s3"` → OCI compat endpoint (`skip_credentials_validation`,
`skip_region_validation`, `skip_requesting_account_id`, `skip_metadata_api_check`,
`use_path_style`, `endpoints.s3`); locking via native S3 lockfile (`use_lockfile`,
OpenTofu ≥ 1.10) instead of DynamoDB. [ASSUMED — conditional-write support on OCI compat
unverified.]
- Fallback: no lock + documented single-operator constraint (precedent: `:local` backend,
  `config.ex:79`).
- `create/drop_state_lock_table` on OCI: `{:ok, :skipped}` no-op with a printed notice
  (NOT an error — see §7 P4 full_setup gating). `create_state_bucket` AND
  `drop_state_bucket` work via ObjectStore bucket-lifecycle callbacks (§3.2, v4).

---

## 6. Ansible Strategy

### 6.1 Inventory

The CONTRACT is the invariant, provider-independent — FOUR parts, not two (v13,
round-11 blocking finding: v11 cited only `:12-34`, the keyed_groups/compose half, and a
generator built to that contract would break `--limit`):
1. **Group names** — `group_<app>`, `monitoring_*`, `database_*`, `qa_*`
   (`aws_ec2.yaml.eex:12-23`).
2. **Composed hostvars** — `ansible_host` ipv6-first, plus the SEVEN tag-derived vars at
   `:28-34` (`ansible_host` itself is the eighth compose entry, `:27`): `release_prefix`, `release_state_prefix`, `git_branch`, `qa_node`,
   `qa_node_suffix` (v14 — consumed by
   `roles/deploy_node/templates/erlang_systemd.service.j2:15` as `RELEASE_NODE_SUFFIX`;
   MVP-safe only because `roles/deploy_node/defaults/main.yaml:6` defaults it to `""` and
   QA is P5 — recorded so the P5 QA train doesn't rediscover it), `instance_tag`,
   `letsencrypt_use_public_ip`.
3. **Hostname composition** — LOAD-BEARING in MVP scope, and the ONE place this plan
   must NOT copy the repo's own claim (v14, round-12 blocking finding).
   `ansible.setup.ex:184` `build_limit_args/1` emits `--limit '<pattern>,'` from
   `QaNode.ansible_limit_pattern/1` (`qa_node.ex:229-232`) = `"#{instance_id}*"`, a GLOB
   on an instance-id PREFIX, and `qa_node.ex:220-223` asserts the `aws_ec2` plugin
   composes hostnames as `"<instance-id>-<Name tag>"`. **MEASURED contradiction:**
   `aws_ec2.yaml.eex:6-7` sets `hostnames: - tag:Name`, which yields the BARE Name tag
   (`"${var.instance_name}-${var.environment}-${count.index}"`,
   `modules/aws-instance/main.tf:180`) with no instance-id prefix — so the docstring
   claim is unverified and probably wrong, and `--limit` may be matching zero hosts on
   AWS TODAY. Two consequences, both owned here:
   (a) **P0 gains a MEASURED verification** (cheap, AWS-side, no OCI needed) — note the
   failure is LOUD, not silent (v15): a `--limit` matching nothing in the inventory exits
   1 → `Mix.raise`, so if AWS hostnames are bare Name tags this path is already
   hard-broken rather than quietly mis-targeting:
   `ansible-inventory -i deploys/ansible/aws_ec2.yaml --list` against the live cluster,
   record the actual hostnames in this doc. If they are bare Name tags, that is a
   PRE-EXISTING AWS BUG in `ansible.setup --instance-id` / `qa.deploy` targeting — report
   it, do not silently inherit it.
   (b) **The OCI generator does not inherit the assumption**: it emits
   `hostname = "<instance-id>-<Name>"` BY CONSTRUCTION (`Cloud.Instance.id` +
   `tags["Name"]`), making the instance-id glob true by design rather than by hope. If
   (a) shows AWS lacks the prefix, §6.5's `ANSIBLE_STDOUT_CALLBACK=json` recap alternative
   is already the PRIMARY producer regardless (§6.5, v15) — (a) is therefore a
   bug-report obligation, not a conditional (v16 stale-conditional fix).
4. **Project scope filter** (`:9-10`, `filters: tag:Group: "<Project> Backend"`) — the
   generator applies the equivalent canonical-tag scope, or an unrelated project's
   instances enter the inventory.
So playbooks — and `--limit` targeting — work unmodified on any provider.

**Mechanism (v11 — DECISION CHANGED from v9's plugin-primary under the N-provider
assumption): static YAML inventory generated from `Cloud.Machine.find_instances` is the
STANDARD non-AWS mechanism.** One generator serves every provider: canonical decoded
tags (§3.0.2) feed group/hostvar composition Elixir-side, so per-provider inventory
plugins, galaxy collections, control-machine SDKs, and per-provider constructed-features
spikes all disappear from the N-provider cost curve — and the GCP label-encoding problem
never reaches inventory. Ordering already supports it: machine ops are Phase 3, before
ansible (Phase 4). Tradeoff, stated: static inventory is stale on instance churn and
must be regenerated (`mix ansible.build`) after scale/create events — acceptable for the
MVP's static-instance model; consumers of that regen duty: operators after any
instance change AND both CI workflows, which regen as their first ansible step (§6.5,
v12); the QA subsystem (dynamic churn) is Phase 5, which decides
per its own contract whether to regenerate-per-run (QaPlaybook already builds temp
playbooks per run) or adopt the `oracle.oci.oci` plugin. AWS keeps the `aws_ec2` plugin
FROZEN (zero AWS change).
- S4 reframed (v11/v13): spike proves the GENERATOR hits ALL FOUR contract parts against
  a live OCI tenancy — group names, compose vars, ipv6-first host selection, AND the
  discriminating measurement **`--limit '<instance-id>*'` matches the generated host**
  (v13; without it S4 passes while every `ansible.setup --instance-id` run matches zero
  hosts) plus project-scope filtering. The `oracle.oci.oci` plugin is the
  fallback/deferred option, not the primary.
- `ansible.build` renders the generated inventory + `ansible.cfg.eex` gains templated
  `inventory =` / `enable_plugins =` lines (`ansible.cfg.eex:3,:11` — .eex already, no
  manifest exception needed); `enable_plugins` renders EMPTY on the static path (v13).
- Naming (v13): `providers/oci/oci.yaml.eex` is the RENDER TEMPLATE for the generated
  static inventory (assigns supplied by `Cloud.Machine`), NOT an `oracle.oci.oci` plugin
  config — the plugin config ships no priv file unless the S4 fallback is taken.
  (Its AWS sibling `aws_ec2.yaml.eex` IS a plugin config; the parallel is layout, not
  mechanism.)

### 6.2 On-instance toolchain + release fetch

**Ground rule (v3 — round-2 blocking finding): shared AWS role files are BYTE-FROZEN.**
Roles are copied verbatim, never EEx-rendered (`ansible.build.ex:346-356`,
`qa_playbook.ex:42`), so ANY in-role provider branch would ship to every AWS user's
`./deploys` on the next build. Provider divergence happens ONLY at two layers (v5
wording fix — these are distinct mechanisms, not alternatives):
(a) playbook `.eex` render chooses role NAMES (`awscli` → `oci_cli`; `save_ami` omitted)
and playbook-level `environment:` vars; (b) SAME-NAME role variants (`letsencrypt`,
`ipv6`, `deploy_node`, `prometheus_db`, `grafana_loki`) are delivered as BYTES by the
§5.1 registry's variant-wins flatten (`providers/oci/roles/<name>` → `roles/<name>`) — a playbook
cannot select between two roles with one name. Enforced by the §5.1 role-sync gates.

- `oci_cli` role (OCI role tree); OCI playbook renders list it instead of `awscli`. The 4
  STATIC setup playbooks hardcoding `awscli`
  (`setup/{redis,prometheus_db,grafana_ui,loki_log_aggregator}.yaml:4-5`) get additive OCI
  copies under `priv/ansible/providers/oci/setup/`; `ansible.setup`'s playbook enumeration reads the
  provider file set (§5.1).
- **`save_ami` gating (v3 — round-2 blocking finding):** `app_setup_playbook.yaml.eex:18`
  lists `save_ami` unconditionally and its role fires IMDSv1 + `aws ec2 create-image` +
  `aws ssm put-parameter` with `save_ami_enabled | default(true)`
  (`roles/save_ami/tasks/main.yaml:93`) — the OCI render of `app_setup_playbook` OMITS the
  `save_ami` role line (playbook-layer gate; role file untouched). Without this, OCI
  `ansible.setup` hard-fails at its last role.
- `deploy_node` fetch: OCI role variant (its `tasks/main.yaml` + scripts) under
  `priv/ansible/providers/oci/roles/` uses `oci os object ... --auth instance_principal` (instance
  principals do NOT work with the S3-compat API → native CLI on-instance; ExAws S3-compat
  on control machine). AWS role byte-untouched. Both keyless.
- `ipv6` role: the AWS-env line lives in the ROLE (`roles/ipv6/tasks/main.yaml:5`), not a
  template — so OCI gets an `ipv6` role variant without it; the playbook-level
  `AWS_USE_DUALSTACK_ENDPOINT` env (`app_playbook.yaml.eex:3` AND
  `app_setup_playbook.yaml.eex:3` — v4 cite fix) is dropped from both OCI playbook
  renders. (v3 — v2's ".eex-gated role lines" claim was mechanically impossible.)
- `--auto-pull-aws` (`ansible.build.ex:107,:142-163`): validation error on any
  provider ≠ `:aws` (§1 census, v4/v12).

### 6.3 IMDS + cloud-init

- OCI cloud-init tftpl written fresh (`providers/oci/modules/oci-instance/`): OCI IMDS
  `169.254.169.254/opc/v2/*` with `Authorization: Bearer Oracle`; no EIP-association step
  (reserved IP attached by terraform); `/dev/oracleoci/*` devices. **On-boot toolchain
  (v5):** Ubuntu ships no `oci` CLI in default archives (the AWS tftpl gets awscli via
  `packages:`, `cloud_init_data.yaml.tftpl:3-6`) — the OCI tftpl installs it first (Oracle
  install script or pipx), an accepted boot-time cost + network dependency; release fetch
  and the marker write below both depend on it.
  **Completion marker (v4/v5; v11 — a provider-DESCRIPTOR slot, §3.0.3, with the
  bucket-object marker as the portable default per §3.0.4; OCI chooses the freeform tag
  because `find_nodes`-style filtering reads instance tags):** cloud-init writes a
  DISTINCT `CloudInitComplete` freeform tag (`oci compute instance update --freeform-tags`; grant
  §5.2, spike S5; fallback bucket-object marker). `SetupComplete` keeps its AWS meaning —
  "ansible setup ran". Writer census (v5 correction): on AWS the tag is SEEDED at create
  (`modules/aws-instance/main.tf:186,:447,:607` — `"true"` only when reusing a
  setup-complete AMI; `qa_node.ex:72` seeds `"false"`; `k6_runner.ex:284` self-tags its
  own single-purpose nodes) and set to `"true"` post-ansible by the CI setup-nodes
  workflow (`github-action-setup-nodes.yml.eex:87-96`); cloud-init only READS it
  (`cloud_init_data.yaml.tftpl:215-232`). On OCI: instances carry NO SetupComplete seed —
  absent reads as incomplete (`aws_machine.ex:368` parses the tag; `:384` is the
  `setup_complete?/1` `=== "true"` test — v13/v16 cite fix) — and the
  §6.5 CI mirror is its sole writer. AWS tftpl untouched.
- `letsencrypt`: an OCI role VARIANT under `priv/ansible/providers/oci/roles/letsencrypt/` with the
  OCI IMDS public-IP path; selected by the OCI playbook render. The AWS role file stays
  byte-frozen — its IMDSv2 IPv4 block (`roles/letsencrypt/tasks/main.yml:98-120`) was
  deliberately stabilized for QA cert lineage (97f4224, abc18c6). The v1 "read
  ansible_host for both" idea stays DROPPED, and v2's "in-role OCI branch" is replaced by
  the variant (an in-role branch would sync to every AWS user — §6.2 ground rule). (v3)

### 6.4 Monitoring

The AWS coupling lives INSIDE role templates, which the §6.2 ground rule freezes —
`prometheus_db/templates/prometheus.yaml.j2:10-31` hardcodes `ec2_sd_configs` +
`__meta_ec2_*` relabels; `grafana_loki/templates/loki-config.yaml.j2:37-42` hardcodes the
`aws:` storage block + `:60` `delete_request_store: aws`; template `src:` paths resolve
from the role's own templates dir (`prometheus_db/tasks/main.yaml:11`,
`grafana_loki/tasks/main.yaml:33`), so group_vars alone CANNOT port them. Therefore (v4 —
round-3 blocking finding):
- **`prometheus_db` OCI role variant**: `file_sd` scrape config (targets file generated at
  setup from inventory groups). AWS role untouched. **`file_sd` is the STANDARD non-AWS
  mechanism (portable default, §3.0.4), not an OCI workaround** (v13) — mirroring §6.1's
  inventory decision: OCI has no native Prometheus SD, but GCP (`gce_sd_configs`) and
  Azure (`azure_sd_configs`) do, and a provider train substitutes native SD only with its
  own justification, so the fork is decided ONCE here instead of per train.
- **`grafana_loki` OCI role variant**: S3-compat endpoint storage block +
  `delete_request_store` for OCI; customer secret keys via group_vars (static keys are
  already the AWS pattern, `all.yaml.eex:3-5`; existing debt, not worsened). AWS role
  untouched.
- Both variants join the §6.2 variant census and the P4.2 list.
- Alloy/node_exporter/Grafana UI: portable as-is.

### 6.5 GitHub Actions CI (v2 — round-1 R3 blocking finding)

- Additive OCI workflow templates `priv/providers/oci/github-action.yml.eex` +
  `github-action-setup-nodes.yml.eex`: oci-CLI install step, release upload via
  `mix deploy_ex.upload` (ObjectStore handles endpoint), setup-nodes' raw
  `aws ec2 create-tags` (`github-action-setup-nodes.yml.eex:91`) mirrored as the
  equivalent `oci compute instance update` call **writing `SetupComplete` after
  `mix ansible.setup` — the sole writer of that tag on OCI, consistent with §6.3's
  marker split (v4). This CI write carries the same freeform-tags-REPLACE hazard S5
  guards for `CloudInitComplete`: it MUST read-merge-write, or it clobbers
  Group/InstanceGroup/GitBranch and breaks §6.1 inventory groups (v9)**. AWS workflow
  templates byte-untouched.
- **Inventory regeneration in CI (v12; MECHANISM CORRECTED v13 — round-11 blocking
  finding):** AWS workflows never regenerate inventory because the `aws_ec2` plugin
  resolves hosts live at each ansible run; the v11 static-inventory decision makes the
  committed file STALE after any node churn. Both OCI workflow mirrors therefore
  regenerate BEFORE `ansible.setup`/`ansible.deploy` — but the v12 prescription (bare
  `mix ansible.build`) is a SILENT NO-OP in CI and would have shipped the staleness it
  was added to fix: `create_ansible_hosts_file` → `DeployExHelpers.write_template/4`
  (`deploy_ex_helpers.ex:44-53`) sets `opts[:message]` when the file exists, so
  `write_file/3` (`:56-72`) needs `opts[:force] || Mix.Generator.overwrite?/2`, and
  `overwrite?` prompts via `IO.gets` → `:eof` on CI stdin → **false → skipped, exit 0**.
  Bare `ansible.build` ALSO `Mix.raise`s on the PEM glob (`ansible.build.ex:235-254`);
  setup-nodes has no PEM step at all and `github-action.yml.eex` writes one only at
  `:105-108`. **Prescription: `mix ansible.build --force --host-only`** — `--force`
  defeats the prompt gate; `--host-only` short-circuits config/group_vars/playbooks
  (`ansible.build.ex:166,:192,:260`) so CI needs no PEM and cannot clobber
  user-customized `./deploys/ansible/playbooks/*` + `group_vars/all.yaml`. Roles ARE
  still synced (`sync_ansible_roles` runs at `ansible.build.ex:52`, before the host_only
  gates, ungated) — intended and consistent with §6.2's byte-frozen ground rule + §5.1
  gate 3, stated here so "cannot clobber" is not read as "touches nothing" (v14). If
  `--host-only` is ever dropped, the regen step must sit AFTER the PEM step.
- **`SetupComplete` write needs a per-host producer (v13 — round-11 blocking finding):**
  v12 said "gate on ansible having actually reached the host", but no such signal exists:
  `mix ansible.setup` runs per setup-playbook/app (`ansible.setup.ex:126-149`) and
  surfaces one aggregate `{:ok,_} | {:error,_}`, while the tag loop is per-instance
  (`github-action-setup-nodes.yml.eex:90-96`) — an aggregate exit cannot discriminate a
  limit-no-match host. (Today's AWS workflow is not "unconditional" either: it carries
  `if: steps.check.outputs.node_count > 0` + GHA implicit `success()`; the uncovered case
  is precisely the per-instance one.) **Mechanism (v15 — round-13 MEASURED correction; exit code alone is NOT sufficient):**
  the OCI mirror loops `mix ansible.setup --instance-id <id>` per instance (the switch
  exists, `ansible.setup.ex:187-208`) **and gates the tag write on
  `ANSIBLE_STDOUT_CALLBACK=json` recap parsing — the host must appear with `ok>0`.**
  Producer prerequisites (v16 — round-14 MEASURED: `ansible.setup` globs the FULL
  `setup/*.yaml` set, `ansible.setup.ex:126-130`, and runs them through
  `Task.async_stream(max_concurrency: 4)` (`deploy_progress.ex:33-36`), so two concurrent
  JSON docs line-interleave into an unparseable stream): the CI loop passes
  `--only <app> --parallel 1` (switches declared at `ansible.setup.ex:323,:327`; `--only`
  filters the setup glob via `filter_only_or_except`, `deploy_ex_helpers.ex:93`, and
  `--parallel` feeds `max_concurrency`, `:144` → `deploy_progress.ex:30` (console) / `:40` (tui); today's AWS
  CI already passes `--only <app>` at `github-action-setup-nodes.yml.eex:79-82`, so setup
  coverage is unchanged). Third prerequisite (v17): `run_command_streaming/4` HARDCODES
  `:stderr_to_stdout` in its port options (`utils.ex:133-138`, `extra_opts` carries only
  `:cd`), so ansible's `[WARNING]`/`[DEPRECATION WARNING]` lines ride the same stream as
  the JSON document — the recap parse ACCUMULATES the full stream — in the `line_callback`
  (the `deploy_progress.ex:35`/`:64` seam) for the Elixir-producer refinement, or in the CI
  step's stdout redirect for the bash version, since `run_command_streaming/4` itself
  returns `:ok | {:error, %ErrorMessage{}}` and discards output (`utils.ex:149-165`) —
  drops the leading non-JSON (ANSI-wrapped) lines, `Jason.decode`s the remainder and gates on `stats[<host>].ok > 0` — a per-line
  JSON filter yields nothing, because ansible's `json` callback emits ONE pretty-printed
  document at end-of-run, and `run_command_streaming` forces `FORCE_COLOR`/`PY_COLORS`/
  `ANSIBLE_FORCE_COLOR` (`utils.ex:116-131`) so warning lines arrive ANSI-wrapped (v18). The Elixir-producer refinement inherits
  the same constraint. Preferred
  refinement, same phase: make ELIXIR the producer — `run_console`'s callback
  (`deploy_progress.ex:35`) discards the per-playbook identity that `run_tui`'s already
  binds (`:64`), so parse the recap per playbook Elixir-side and have `ansible.setup`
  return `{host, ok_count}` instead of an aggregate.
  Exit code is necessary but not sufficient: MEASURED on ansible-core 2.18.4, a `--limit`
  matching nothing in the inventory exits 1 (caught), but a `--limit` matching a host the
  play's `hosts:` group does NOT contain prints "skipping: no hosts matched", empties the
  PLAY RECAP, and exits **0** — which is exactly the new failure mode §6.1's Elixir-side
  group composition introduces (mis-grouped host), and it would tag `SetupComplete=true`
  on a node ansible never configured, permanently invisible to
  `find_nodes --setup-incomplete`.
  CI is added to §6.1's staleness consumers. **Both CI mechanisms — the
  `--force --host-only` inventory regen and the per-instance + JSON-recap completion gate —
  are the STANDARD non-AWS CI mechanisms (v16), not OCI workarounds:** they follow from
  §6.1's static-inventory decision, so a GCP or Azure train inherits the same staleness and
  the same mis-grouped-host-exits-0 trap and substitutes only with its own justification
  (same generalization §6.1 and §6.4 already carry).
- **TWO credential sets in the OCI workflow (v3):** (a) `OCI_CLI_*` secrets (or config-file
  secret) for oci-CLI calls; (b) the S3-compat Customer Secret Keys exposed as AWS-shaped
  env (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) for BOTH `tofu init/apply` against the
  `backend "s3"` compat endpoint (§5.5) and `mix deploy_ex.upload` via ExAws (§3.3). Both
  named in the workflow template, not just the guide.
- `mix deploy_ex.install_github_action` renders the active provider's set (via §5.1
  registry).
- Documented secret list for OCI in the getting-started guide.

---

## 7. Phased Roadmap

Each phase = one PR train; AWS suite + render-equality harness green at every merge; full
sprint contracts (test-first steps) authored per-phase at execution time — this doc pins
scope + invariants, not function bodies.

**Integration rule — UNIVERSAL (v6; v5's enumeration kept drifting):** EVERY phase train
merges to the branch Mika's live AWS workflows consume ONLY after the live AWS smoke
named in that phase's Done passes on the assembled train — no phase is exempt, because
every phase in this plan rewires at least one live-consumed runtime path. DI-faked tests
and fixture gates gate each COMMIT; live-AWS truth gates the MERGE. Each phase's Done
below names its smoke — and the Done text is authoritative over this summary (v19 sync):
P0 = QA create→deploy→destroy round-trip + `deploy_ex.ssh <app>`; P1 = AWS storage
round-trip + a lookup consumer; P2 = `terraform.plan --target` + render-vs-render + QA
sync cycle + `generate_pem`; P3 = `restart_app` + `download_file` +
`grafana.install_dashboard` + `find_nodes` + `instance.status` (NOT `deploy_ex.ssh`, which
never opens a connection); P4 = full OCI loop + AWS `ansible.build`/`ansible.ping`. A phase
Done without a live AWS smoke is a defect in this doc, not an exemption.

### Phase 0 — Render harness + provider seam (pure refactor, AWS-only)

**P0.0 (FIRST, before any churn — v2/v3):** deterministic-render diff harness:
- Randomness injectable: `pem_app_name`/`generate_db_password` accept values via opts
  (both renderers), defaulting to today's random behavior at runtime.
- `mix terraform.build`/`ansible.build` gain `--render-dir <path>` (render-only: no
  `terraform init` — skip `:90-93` — no prompts, and no ToolInstaller preflight — skip
  `terraform.build.ex:41` so harness CI needs no tofu install — v8). The harness drives the ACTUAL task
  entry points, not `PrivRenderer.render_to_temp` (not equivalent until Phase 2.3's
  shared-params extraction: params built independently at `terraform.build.ex:50-86` vs
  `priv_renderer.ex:74-124`, e.g. `db_password` generated vs `"placeholder"`). (v3)
- `--render-dir` contract (v3; TIGHTENED v15 — round-13): it redirects **every write the
  task performs**, not just the three path defaults at `ansible.build.ex:39-41`. That
  includes `opts[:directory]` (`:37`) and therefore `sync_ansible_roles`
  (`:52,:346-356` — otherwise the "non-destructive" smoke still `cp_r!`s into the LIVE
  `./deploys/ansible/roles`), `build_host_playbook`/`build_host_setup_playbook`
  (`:263-264,:310,:329`), and `remove_usless_copied_template_folder`'s `File.rm!`
  (`:361-371`). It also SKIPS the pem glob (`pem_file_path/2`, `:235-253`) — returning the
  fixed literal `../terraform/RENDER_DIR_PLACEHOLDER.pem` so `ansible.cfg` STILL RENDERS
  (v16: the glob's only caller is `create_ansible_config_file/1`, `:191-206`, so "skip the
  glob" must not be read as "skip the cfg" — §11's zero-render-diff enforcement, §3.5's
  `remote_user` → `ssh_user` render-identity claim, and gate 2's PATH-SET equality all
  need that file rendered) — rather than
  relying on a fixture pem — a scratch dir has no sibling `terraform/*pem`, and the glob
  `Mix.raise`s at `:249` (MEASURED: an absolute render dir also renders a different
  `private_key_file` byte than the live tree, which is a second reason render-vs-live was
  unworkable).
- Harness renders AWS set with pinned inputs before/after a change and diffs. This is the
  mechanism behind every "AWS output unchanged" claim in this doc.

P0.1 `Config.cloud_provider/0` + `DeployEx.Cloud.Providers.Aws` and `.Oci` DESCRIPTOR
modules (§3.0.3) + a `DeployEx.Cloud` dispatcher DERIVED from them (no capability-module
literals) + per-provider NimbleOptions config schema validated at task start, with the
PERMISSIVE `:aws` schema + its unit pin (§3.5) + the
FOUR MVP behaviours (§3.2) with normalized structs. Slot fill schedule: OCI's
object_store P1; backend_template + completion_marker P2 (default_ssh_user decided by
spike S3 at P2, threaded at P3.3); machine/infrastructure/security + cli_adapter P3;
inventory strategy/template/filename P4 (v13 — round-11 blocking finding: the descriptor
had no phase item, so P0.1 would have built v9's inline map and the descriptor would
never exist).
P0.2 Conformance: `AwsMachine`/`S3ObjectStore` (absorbing `AwsBucket`+`AwsManager`+
`ReleaseTracker`/`TerraformState` S3 calls)/`AwsInfrastructure`/`Security` conform;
caller-side XML parsing moves inside; **each module gets behaviour-conformance tests
BEFORE its rewiring commit** (today `ReleaseTracker`/`TerraformState`/`AwsMachine`/
`AwsBucket` have ZERO test files — v2, round-1 R2 finding).
P0.3 Flag threading per §3.2 — the non-exempt flag tasks (§3.2's exempt list governs);
moduledoc-drift + ghost-flag fixes per the §3.2 census; **plus the `@doc false`
opts-taking caller entries the P0 encoding test drives (v17 described the seam, v18 gave
it an owner, v19 fixes the EXTRACTION LEVEL — it is filter-build + capability call +
post-verify and nothing else): `@doc false def find_instances(opts)` wrapping
`find_nodes.ex:41-53` (NOT `build_tag_filters/1` at `:86`, which is one layer too shallow —
the capability call lives in `run/1`, so a test driving it could never consult a descriptor
and the non-vacuity assert would be unsatisfiable), and
`@doc false def fetch_status_instances(app_name, environment, opts)` wrapping
`instance.status.ex:107-112` with `display_instance_details/2` calling it (NOT
`display_instance_details/2` itself at `:106`, which is one layer too broad — its `with`
continues into `fetch_elastic_ips()`'s inline `ExAws.request` at `:239-247` and
`AwsLoadBalancer.find_target_groups_by_app/1` at `:113-114`, colliding with §10's
no-live-cloud-in-CI rule), and the `deploy-ex-dev/SKILL.md:96-99` ExAws
region idiom, which contradicts the seam the moment P0.2 lands (v18)**. Threading ONLY — all storage
`put_new` moves land at P1 per §3.2, the single source of truth (v10).
P0.4 Per-task provider guards on AWS-only tasks (autoscale.*, load_balancer.*, qa.*,
load_test.*, ebs-snapshot, dump/restore_database, `terraform.show_password` — v3) →
`:not_implemented` on ANY provider ≠ `:aws` (v12 polarity — a `:gcp` train inherits the
guards for free, matching §3.1's missing-capability dispatch).

**Done:** direct `ExAws.` call sites confined to an EXACT expected-file list — the THREE
conforming AWS impls (`aws_machine.ex`, `aws_infrastructure.ex`, `aws_security_group.ex` —
they ARE the ExAws-backed behaviour implementations; `aws_ip_whitelister.ex` leaves the
list with the P0.2 commit that empties it — v6/v17) + the
non-behaviour-ized Tier-A wrappers + `S3ObjectStore` + QaNode/K6Runner internals + both
ebs-snapshot task files (inline ExAws permanently per §3.2/§4 — v5) —
checked-in list, compared in CI; not a bare grep, which false-positives on `tui.ex:7`'s
comment). The list is PHASE-ATTRIBUTED like the defaulting allowlist (v18 — round-16:
18 files hold `ExAws.` today and the list permits 12; the two inline-ExAws tasks
`instance.health.ex:69-70` (`DescribeInstanceStatus`) and `instance.status.ex:239-247`
(`DescribeAddresses`) map to no §3.2 MVP behaviour row, and their DEFAULTING sites are
already attributed clears-at-P3 — so their ExAws calls are attributed clears-at-P3 too,
not silently expected to vanish at P0); **caller-level tag-encoding contract test** (v16 literal bullet, §3.0.2): `find_nodes`
(filter list) and `instance.status` (regex arm) driven against a test-only lossy fake
descriptor injected via the internal `provider:` opt, pinning unknown-key round-trip
(`SetupComplete`), `Group = "CFX Web"` and `GitBranch = "feat/foo"` survival, `feat/foo`
vs `feat_foo` post-verify rejection, and `%Regex{}` degrading to full-fetch + post-verify;
`DeployEx.Cloud` contains NO capability/behaviour-module literals — pinned EXECUTABLY as
(a) every capability lookup delegates to `Providers.<X>.capabilities/0`, and (b) a source
test that the only `DeployEx.` references in `cloud.ex` are `DeployEx.Cloud.Providers.*`
and `DeployEx.Config` (v16 — the dispatcher must read `Config.cloud_provider/0`)
(v15 — "no provider literals" was never a test; the registry values are module literals
too); the DISPATCHER costs one `@providers` line + one descriptor module — see §3.0.3 for the
full registration census, which is larger (v17 scoping: the unqualified claim is the
overstatement §3.0.3 exists to correct); **the §3.0.1 4-column callback mapping
committed at
`docs/superpowers/plans/2026-08-03-provider-columns.md` (GCP/Azure columns ASSUMED-labeled;
the artifact the future GCP/Azure trains consume — v12, round-10 blocking finding)**;
full suite + credo --strict green; render harness shows zero AWS diff; live AWS
QA smoke = **`qa.create` → `qa.deploy` → `qa.destroy` round-trip on a scratch app** (v3 —
`qa.list` only exercised QA-state reads; the round-trip covers the biggest P0.2 rewires:
`gather_infrastructure` at `qa.create.ex:769`, AwsManager S3 listing at `qa.create.ex:733`
/ `qa.deploy.ex:164`, `wait_for_started` at `:877` — DI-faked conformance tests cannot
catch real-AWS response-shape drift; this smoke does. **`mix deploy_ex.ssh <app>` on the APP-NAME path is added to the P0 live smoke (v17)** —
it is the shortest path through `find_instance_ips` → `find_instance_details`, the
intra-module chain above. Consumers the smoke still does NOT reach
— `ansible.setup --instance-id`, `lb.health`, ebs tasks, grafana — are protected by the
§3.2 caller-sweep contract's same-commit sweep + conformance tests, v7 attribution fix).
**Risk:** biggest-churn phase even after the v2 trim (~20 files). Mitigation:
capability-per-commit, harness-gated, held-train merge per the all-phases integration
rule above (v4/v5).

### Phase 1 — Object storage portability + spikes
1. `S3ObjectStore` endpoint parameterization + `:object_store` provider config.
2. Spikes S1 + S2 against a real tenancy; results written back into this doc; locking
   fallback decided; tagging probe INFORMATIONAL only (key-prefix is the design per
   §3.3 — v12).
3. `terraform.create_state_bucket` on OCI; lock-table tasks → `{:ok, :skipped}` on OCI.

**Done:** `mix deploy_ex.upload` + `list_available_releases` + release-tracker round-trip
MEASURED against a real OCI bucket **AND against the real AWS bucket (the P1 live smoke —
endpoint parameterization touches every live storage path; v5), plus one lookup CONSUMER
on AWS (`view_current_release` + the `ansible.rollback` listing path) so task-side
opt-threading is exercised, not just the impl seam (v8)**; the §3.2 defaulting grep green
per its attributed allowlist; a scratch-name AWS bucket create→delete lifecycle check
covers the P1.3 state-bucket rewire (v10); S1/S2 recorded; AWS harness green.

### Phase 2 — Terraform OCI environment
1. `PrivFileSet` registry (source→dest mapping) + all SIX copy-path filters incl. the
   `PrivRenderer.render_to_temp` choke point + the SIX §5.1 gates (v4/v6/v12) — lands WITH
   the first OCI priv file.
2. `priv/terraform/providers/oci/` set (§5.2): providers/variables/instance module/VCN/NSG/identity/
   bucket/outputs/key-pair + OCI cloud-init tftpl; flatten-on-render. **Plus the §3.0.6
   omitted-variable deny-list check in `Terraform.parse_args/2`, non-AWS only (v16), with
   its verification pin (v17 — it can never be covered by an AWS smoke since it does not
   run under `:aws`): a negative unit test — `:oci` + a var-file setting `upload_buckets`
   ⇒ raise; `:aws` + the same var-file ⇒ no raise.**
3. Shared render-params extraction (build ↔ priv_renderer).
4. Address map, all three sites (§5.4); resource-type map (§5.3); a unit test pins the
   frozen AWS address strings AND the §5.3 resource-type map rows byte-verbatim
   (v6/v14).
5. Render tests: OCI shape asserts + `tofu validate` on rendered OCI set in CI; AWS
   render-equality regression.

**Done:** `terraform.build/init/apply` stands up a 1-app OCI environment (instance
running, cloud-init completes, **CloudInitComplete marker set** (v4), bucket + identity
live); `terraform.drop` tears down clean; all six §5.1 gates green; AWS harness green;
**live AWS smoke (v6 — P2 rewires the sync paths + terraform address code):** on the real
AWS project, `terraform.plan --target <app>` succeeds (exercises `build_target_string` +
state parsing against real state), `mix terraform.generate_pem` is a no-op-clean
(exercises the §5.3 resource-type reads — v14), **RENDER-vs-RENDER zero diff** (v15 — round-13 blocking finding, all three lenses
converged): render the real project at the merge-base and at the train HEAD into two
scratch dirs and diff THOSE —
at each SHA render BOTH renderers —
`mix ansible.build --render-dir <dir>` AND `mix terraform.build --render-dir <dir>` (v16:
P2.3 extracts the SHARED render params, and the terraform half is the one carrying the
`db_password`/`pem_app_name` divergences and the per-release variable blocks at
`terraform.build.ex:46-48`, which no fixture reproduces) — then `diff -r /tmp/a /tmp/b`.
Both renders run from the SAME consumer project dir against two deploy_ex checkouts wired
as `path:` deps with `mix deps.compile deploy_ex --force` between them (v16 — checking out
in the consumer's own cwd would diff the umbrella's history instead; discrimination is
proven once by injecting a canary byte into a template at HEAD).
Never render-vs-LIVE: `./deploys/ansible` additionally holds the seeded non-rendered tree
(19 `roles/`, `setup/`, `Agents.md`) plus user-customized playbooks and the
`--auto-pull-aws` credentials in `group_vars/all.yaml` that the `.eex` renders as
`"<INSERT_SECRET_OR_PRELOAD_ON_MACHINE>"` (`all.yaml.eex:4-5`; injected only on the
first-run seed path, `ansible.build.ex:107-135`), so a live diff can NEVER be zero and the
gate would simply get waved — the same non-discrimination v13/v14 each tried to fix from
the wrong end. Render-vs-render is non-destructive AND discriminating: it is exactly the
P0.0 harness, pointed at the real project's config/app set), and one QA playbook sync
cycle (`AnsibleRoles.sync/1` route) runs clean.

### Phase 3 — Elixir machine-ops parity (moved before ansible — v2, round-1 R1 finding)
1. `Cloud.Oci.Cli` + `Oci.Machine`/`Infrastructure`/`Security` (JSON fixtures + parser
   tests).
2. Task sweep: `deploy_ex.ssh`, `ssh.authorize`, `find_nodes`, `select_node`,
   `restart_machine`, `restart_app`/`start_app`/`stop_app` (reach AWS via
   `deploy_ex_helpers.ex:163,:190` — v4), `instance.health`, `instance.status`,
   `download_file`, `grafana.install_dashboard` on `:oci`.
3. `ssh_user` config threaded — the FIVE literals per §3.5's census (`ssh.ex:2`,
   `ssh.ex:101`, `deploy_ex.ssh.ex:291`, `:296`, `download_file.ex:89`) plus
   `ansible.cfg.eex` (v19 restatement — the earlier list mixed literals with consumers).
   `ssh.ex:101`'s jump-host literal FEEDS `grafana.ex:68`, `dump_database.ex:72`,
   `restore_database.ex:181`. NOTE
   (v18): `deploy_ex.ssh.ex:291,:296` are the PRINTED command string only — pin the string,
   not a connection. Unit pin: `Config.ssh_user()` returns `"admin"` under `:aws` with no
   `:ssh_user` key set. ToolInstaller learns `oci`.

**Done:** each swept task MEASURED against the Phase-2 live OCI instance; AWS harness +
suite green; live AWS smoke (v18 — round-16 blocking finding: `mix deploy_ex.ssh` NEVER
OPENS A CONNECTION; `connect_to_host/4` terminates at `log_ssh_command/4`
(`deploy_ex.ssh.ex:254-285`, connect commented out at `:274-284`), so it could not
discriminate the P3.3 `"admin"` sweep at all): **`mix deploy_ex.restart_app <app>`** — the
`deploy_ex_helpers.ex:188,:206` → `SSH.run_command/4` → `connect_to_ssh/4` route, where
`ssh.ex:2`'s `user \\ "admin"` default is the SOLE user source (`:37` calls it with three
args) — **plus `mix deploy_ex.download_file`** (scp literal, `download_file.ex:89`) **plus
`mix deploy_ex.grafana.install_dashboard`** — the only smoke that reaches `ssh.ex:101`'s
jump-host `"admin@..."` literal via `setup_ssh_tunnel/5` (`grafana.ex:68`; its other
consumers `dump_database.ex:72`/`restore_database.ex:181` are P5-deferred), which takes no
user argument today, so the sweep either adds one or reads Config inside; the
`"<user>@<host>"` build is extracted to a pure function and unit-pinned returning
`"admin@<ip>"` under `:aws` (v19), plus
`deploy_ex.ssh` + `find_nodes` + `instance.status <app>`
on the real AWS cluster (v6/v13 — `instance.status` is the only live caller of the
`%Regex{}` tag matcher, has no test file, and would silently return zero instances under
an exact-match filter spec), plus a unit pin asserting a `%Regex{}` `InstanceGroup`
matcher still matches `"<app>_<env>"` (§3.0.2).

### Phase 4 — Ansible + CI + polish (MVP exit)
1. Static-inventory generator from `Oci.Machine` (v11 primary, §6.1) + spike S4;
   `oracle.oci.oci` plugin config only as fallback; ansible.cfg/group_vars templating; `ansible.ping` + inventory-filename hardcodes
   sourced from the §5.1 registry (`ansible.ping.ex:25,:28`, `ansible.build.ex:39`,
   `ansible.deploy.ex:97`, `ansible.setup.ex:120` — v3).
2. OCI role variants per §6.2 ground rule (`oci_cli`, `deploy_node`, `ipv6`,
   `letsencrypt`, **`prometheus_db`, `grafana_loki`** — v4); OCI setup-playbook copies;
   **save_ami omitted from the OCI setup playbook render** (v3); playbook env gating;
   `--auto-pull-aws` validation error on any provider ≠ `:aws` (v4/v12).
3. Monitoring: prometheus file_sd + loki endpoint for OCI (§6.4).
4. GitHub Actions OCI templates + `install_github_action` gating (§6.5); unit test pins
   `:aws` template-path selection unchanged (writes land in `./.github/workflows`,
   outside the P0.0 harness scope — v6).
5. `full_setup` provider-gates its `@pre_setup_commands` pipeline (`full_setup.ex:40-47`
   runs CreateStateLockTable unconditionally and `Mix.raise`s on error at `:66-67` — the
   `{:ok, :skipped}` contract from §5.5 + an explicit provider-filtered command list make
   `mix deploy_ex.full_setup` work end-to-end on OCI — v2, round-1 R3 finding); unit test
   pins the `:aws` filtered command list == today's list verbatim (v6).
6. TUI wizard provider field + neutral labels (24 of the 25 AWS-labeled `input(...)`
   fields in `lib/deploy_ex/tui/wizard/command_registry.ex` — `:auto_pull_aws` stays
   AWS-labeled; v14 count fix); **docs updates = the §1 census PREDICATE re-run at execution time (v17 — replaces the
   v14 four-file enumeration, which kept needing patches): minimally
   `reference/configuration.md` (provider key + namespaces + neutral accessors),
   `reference/mix_tasks.md` (P0.3 flag + moduledoc deltas),
   `explanation/architecture.md` + `reference/codebase_summary.md` (provider seam),
   `reference/terraform_variables.md` (jointly with §3.0.6), `how-to/clustering.md`,
   `README.md` (config block, CI secret table, prerequisites, bootstrap sequence,
   clustering paragraph), `.claude/skills/deploy-ex-infra/SKILL.md` (config reference
   `:146-156`, ghost flags `:28`, `Group` `:178`), and
   `how-to/connecting_to_nodes.md` — whose `:97` says `--format ids` is
   "newline-separated" while `find_nodes.ex:153-157` joins with a SPACE, and `:100` says
   `select_node` "prints IP" while it prints the instance id; §11 now freezes the CODE
   behavior, so P4.6 corrects the DOC to match it (v18)**; getting-started-on-OCI guide (tenancy
   prereqs: compartment, customer secret keys, `~/.oci/config`, dynamic-group policy
   list, CI secrets, **and the cluster-discovery strategy — `Cluster.Strategy.Gossip` or
   `DNSPoll`; `EC2Tag` is AWS-only (v17, §1's MVP obligation bound here)**).

**Done (= MVP):** on a live tenancy, the FULL loop — `full_setup` → provision → setup →
upload → deploy → ssh → restart → health → rollback → CI workflow file renders — each
MEASURED, checklist committed as a doc; AWS harness + suite + live AWS QA smoke green;
**live AWS smoke (v7 — the QA path bypasses the `ansible.*` mainline P4.1 rewires):**
RENDER-vs-RENDER zero diff on the real AWS project (v15 — merge-base vs train HEAD into
two scratch dirs, same form as P2; never render-vs-live, never `--force` against the live
tree) + `mix ansible.ping` green on the real cluster, plus a unit pin asserting the `:aws`
**inventory-composition tag-encoding test (v17 LITERAL P4 bullet — §3.0.2 deferred this
caller here at v16 but never bound it, the fifth describe-vs-bind instance; and it is the
caller that carries the whole GCP story, since §6.1 rests on "canonical decoded tags feed
group/hostvar composition Elixir-side"): with the test-only lossy fake descriptor injected
via the `provider:` seam, drive the static-inventory generator and assert group names and
hostvars derive from DECODED canonical tags. **Discriminating pair only (v18 — round-16:
`group_<app>` comes from `keyed_groups: tags['InstanceGroup']`
(`aws_ec2.yaml.eex:16-17`), NOT from `Group` (`:9-10` is the project-scope filter), and
`InstanceGroup` is `"<snake_app>_<env>"` (`main.tf:647`) — already slug-safe, so a
`group_<app>` assertion cannot discriminate a raw-tag generator):** the `git_branch`
hostvar is `feat/foo` NOT `feat_foo`, AND project-scope matching succeeds on decoded
`Group = "CFX Web"` while rejecting a `cfx-web` post-verify collision, AND unknown-key
round-trip (`UsePublicIpCert` → the `letsencrypt_use_public_ip` compose var). THREE
clauses, not four (v19): the `%Regex{}` clause is P0-only — the generator's project scope
is an exact `Group` scalar (§6.1 part 4) and nothing hands it a `Regex.t()`; same four
pinned clauses (minus regex) as the P0 bullet. Nothing else can detect a generator composing from RAW
provider tags: both implemented columns are identity encodings and the live-tenancy loop
cannot discriminate it**; registry inventory TEMPLATE + FILENAME slots (v15 — split pin: the four runtime sites
assert `filename === "aws_ec2.yaml"`; `ansible.build.ex:222` and `priv_renderer.ex:157`
assert `template === "ansible/aws_ec2.yaml.eex"`), plus the rendered `ansible.cfg` lines
(`inventory = ./aws_ec2.yaml`, `enable_plugins = aws_ec2` — `ansible.cfg.eex:3,:11`, the
consumer that actually points ansible at the file — v15), across all SIX census sites
(v14 — v13's "four" dropped two the §5.1 row-5 census already lists):
`ansible.build.ex:39` and `:222`, `ansible.deploy.ex:97`, `ansible.setup.ex:120`,
`ansible.ping.ex:25,:28`, `priv_renderer.ex:157-158` — deploy/setup sit on the live CI path,
`github-action.yml.eex:111`, `github-action-setup-nodes.yml.eex:49-82`).

### Phase 5 — Extended parity (each item own go/no-go, no design here on purpose)
QA nodes; k6; autoscaling→instance pools; LB; save_ami→custom-image capture with
bucket-hosted image pointer; managed DB; EBS-snapshots. Behaviour extraction for
Autoscaling/LB/DB/StateLock happens with their item. Until then: honest `:not_implemented`.
Each P5 item's execution-time contract MUST name (a) its live AWS smoke per the universal
integration rule (the QaNode item = the QA round-trip), (b) its §3.0.1 4-column rows —
P5 extracts `Autoscaling`/`LoadBalancer`/`Database`/`StateLock`, the plan's LARGEST
callback batch — and (c) the §3.2 defaulting-grep entries it clears, (d) the §5.3/§5.4 address and
resource-type map rows it fills (`TerraformState.find_instance_display_name`,
`terraform_state.ex:158-177`, hardcoded `"aws_instance"` + `module =~ app_name`, is
explicitly deferred here), (e) a §5.1 gate-5 fixture row if the item ships priv files,
(f) REMOVAL of its §3.0.6 deny-list entry when the item IMPLEMENTS a previously-omitted
feature (v17 — else var-files legitimately setting the now-implemented variable start
hard-erroring on apply), (h) behaviour-conformance tests landing BEFORE each rewiring commit for every module the
item extracts — P0.2's rule, universalized here (v19), since P5 extracts
`Autoscaling`/`LoadBalancer`/`Database`/`StateLock`, the largest callback batch, and none
of those modules has a test file today — and (g) its `guides/` rows —
every P5 item owns one (`how-to/qa_nodes.md`, `explanation/autoscaling.md`,
`how-to/load_testing.md`, `how-to/database_operations.md`) which becomes wrong the moment
the item ports (v9/v14/v15/v16). P5 has no blanket Done, so all EIGHT universal rules bind at item level.

---

## 8. Spikes

| ID | Question | Phase | Fallback if NO |
|---|---|---|---|
| S1 | OCI S3-compat: multipart upload, object tagging, delete_multiple, ExAws host/region signing; bucket lifecycle incl. compartment placement (compat API creates in the tenancy's designated S3 compartment — cannot target `compartment_id`); instance-principal native read | 1 | tagging probe informational (key-prefix is the design, §3.3 — v12); multipart→single-put <5GB; per-call put loop; bucket create→native `oci os bucket create` one-off (v5) |
| S2 | TF s3 backend + `use_lockfile` on OCI compat (OpenTofu ≥1.10, conditional writes) | 1 | no-lock + single-operator doc |
| S3 | Base image: Ubuntu platform vs imported Debian; ssh_user implications | 2 | default Ubuntu (`ssh_user: "ubuntu"` for OCI), document Debian import |
| S4 | (v11 reframe, §6.1) static-inventory GENERATOR from `Oci.Machine` hits the inventory contract — group names, compose vars, ipv6-first — against a live tenancy | 4 | `oracle.oci.oci` plugin config (then its control-machine deps — galaxy collection + python `oci` SDK — enter ToolInstaller/preflight scope) |
| S5 | OCI IMDS v2 fields + instance-principal self-tag-update (`CloudInitComplete`). **Discriminating measurement (v8): `oci compute instance update --freeform-tags` REPLACES the whole tag map — S5 must prove all pre-existing freeform tags (Group/Environment/InstanceGroup/...) SURVIVE the marker write (read-merge-write), else §6.1 inventory groups break. A naive S5 passes while clobbering.** The OCI instance module also needs `lifecycle ignore_changes` on freeform tags for both markers (terraform drift). | 2 | completion marker = bucket object write (already granted) |

Spike results written back into this doc before the phase exits (Continuous Capture).
Same rule for the 4-column mapping artifact (P0 Done): any column fact a later phase
refutes is corrected in `2026-08-03-provider-columns.md` at that moment (v12).

## 9. Risks

| Risk | Mitigation |
|---|---|
| Phase 0 churn regresses AWS | P0.0 harness FIRST; capability-per-commit; conformance tests pre-rewire; live QA smoke at exit |
| OCI files leak into AWS users' deploys | PrivFileSet + fixture zero-action gate lands with first OCI file (§5.1) |
| S3-compat gaps late | S1/S2 at Phase 1 START, before Phase 2+ |
| Behaviours AWS-flavored | 4-column design check (§3.0.1): every callback mapped on paper against AWS/OCI/GCP/Azure before the PR that adds or changes it merges, in ANY phase (v14 — event trigger, not phase) |
| N-proofing turns speculative | GCP/Azure columns are paper-only + ASSUMED; zero absent-provider code; §3.0 rules bind contracts, not implementations (v11) |
| Renderer duplication drift | shared params extraction + render-equality test (Phase 2) |
| OCI CLI runtime dep (python) | preflight + ToolInstaller + ErrorMessage; only under `:oci` |
| Cert lineage churn on AWS QA | letsencrypt AWS path byte-frozen (§6.3) |
| Tenancy quirks poison e2e | paid-tier standard shape; free tier unsupported for verification |

## 10. Testing Strategy

- Unit: behaviour impls w/ injected fakes (existing DI style); OCI CLI parsers vs committed
  JSON fixtures; the tag-encoding contract test is CALLER-level, not behaviour-level (v17
  restatement — behaviour-level is the framing §3.0.2 declares cannot detect what it
  exists for): `find_nodes` + `instance.status` at P0, the inventory generator at P4, each
  driven against a test-only LOSSY fake descriptor **plus** the identity-encoded impls (v15 — "both providers' fakes" was insufficient: AWS and
  OCI are both identity encodings, so two identity fakes cannot pin the §3.0.2 encoding
  seam at all).
- Render: deterministic harness (P0.0) — AWS byte-equality regression + OCI shape asserts +
  `tofu validate` in CI; fixture-project zero-action upgrade/sync gates (§5.1).
- Live: per-phase MEASURED smoke on a real tenancy (manual gate, committed checklist); no
  live-cloud calls in CI suite; live AWS QA smoke at Phase 0 + MVP exits.
- `mix credo --strict` + `mix compile --warnings-as-errors` throughout.

## 11. Compatibility Contract (existing AWS users)

- No config change; `cloud_provider` defaults `:aws`.
- No terraform state migration; AWS addresses byte-frozen (all three parse sites) AND
  the §5.3 resource-TYPE strings byte-frozen at ALL read sites (v15 census:
  `tls_private_key` + `aws_key_pair`/`key_name` — `generate_pem.ex:42-43`;
  `aws_db_instance` — `show_password.ex:36` via TerraformState, `show_password.ex:60`
  INLINE, `aws_database.ex:122`; `aws_instance` — `terraform_state.ex:158-177`. The two
  inline reads stay frozen literals until their P5 item; `generate_pem`/`show_password`
  read these, not addresses).
- **Machine-readable task OUTPUT shapes are frozen for `:aws` (v17 — round-15 blocking
  finding; the compat contract covered CLI switches, config, state addresses, render bytes
  and CI files, but not output):** `mix deploy_ex.find_nodes --format json|ids`
  (documented at `find_nodes.ex:14-15,:22` and `guides/how-to/connecting_to_nodes.md:98`,
  emitted via `Jason.encode!` at `:149` over `AwsMachine.parse_instance_info/1`) keeps its
  exact key set — ELEVEN keys (v18 count fix, round-16 MEASURED by executing
  `parse_instance_info/1` through `Jason.encode!`): `app_name, environment, instance_id,
  instance_type, ipv6, launch_time, private_ip, public_ip, setup_complete, state, tags`
  (`aws_machine.ex:354-370`). The P0 pin SNAPSHOTS those 11 keys from
  `parse_instance_info/1` in the PRE-REWIRE commit into a test fixture (v19 — deriving them
  live would race the rewrite: once P0.2 normalizes the producer, that function's input
  shape stops existing, so P0.2 must also state its fate — retained as the struct BUILDER,
  or removed), not
  from this prose list (v18 — a pin written to a 10-key prose list would ACCEPT the
  regression of silently dropping `instance_type`). `%Cloud.Instance{}` renames three
  (`instance_id`→`id`, `launch_time`→`launched_at`, `instance_type`→`type`) and drops
  three (`app_name`, `environment`, `setup_complete`), and a bare struct raises `Jason.Encoder not implemented` — so P0.2
  either keeps `parse_instance_info/1` as the AWS display projection or remaps keys
  explicitly in `output_json`. Pinned by a P0 unit test asserting the exact JSON key set
  from a fixture instance (no test file exists today). The LOUDEST consumer is IN-repo and shipped (v19):
  `priv/github-action-setup-nodes.yml.eex:49` runs `--format ids` (and `:52`'s `wc -w`
  depends on the SPACE-joined form) while `:69-70` runs
  `--format json | jq -r '.[].app_name'` — and `app_name` is one of the three keys
  `%Cloud.Instance{}` drops. The P0 pin therefore asserts `app_name` and the space-joined
  `ids` form EXPLICITLY, not merely "the exact key set". Out-of-repo jq/CI consumers are
  the same "user-visible contract, not an internal detail" class §3.0.2 applies to tag
  values. **Three further machine-readable surfaces are frozen (v18):**
  `select_node --short` (documented "script-friendly", `connecting_to_nodes.md:101`;
  P3.2-swept) emits a bare instance id; `deploy_ex.ssh -s` (eval-consumed at
  `README.md:264`, `connecting_to_nodes.md:5,:25,:62`) emits one runnable ssh command;
  `load_balancer.health --json` (`mix_tasks.md:141`) keeps its key set — its producer
  reads raw `instance["instanceId"]`/`["tagSet"]` (`load_balancer.health.ex:100-124`) from
  a P0.2-normalized producer, and the P0 smoke does not reach it. The remaining JSON emitters (`qa.list`, `load_test.list`) are excluded because their
  PRODUCERS are P5-frozen (v19 — the earlier "they build explicit key literals" reason was
  wrong: `lb.health` builds literals too, `load_balancer.health.ex:208-226`; producer phase
  is the real discriminator).
  `terraform.output --short` is excluded correctly — it decodes tofu's own JSON
  (`terraform.output.ex:19,:53-58`), not an Elixir producer. **Chosen mechanism (v18, closing the
  v17 either/or): remap keys explicitly in `output_json`** — one provider-neutral
  projection, no per-provider "display projection" obligation and no new §3.0.3 census
  row.
- Zero render/seed/sync/export/upgrade diffs in `./deploys/` from any phase — enforced by
  the P0.0 render harness + the six §5.1 fixture gates (mechanisms named, not hoped).
- `aws_*` Config keys/functions remain; neutral keys additive; `--aws-region` AND
  `--aws-release-bucket` CLI flags keep their override semantics (§3.2, v6).
- Mix task CLI surface: no EXISTING flag changes semantics or disappears; ADDITIVE flags
  are permitted (v17/v19 — P0.0 adds `--render-dir`; P2.1 ADDS an undocumented
  `--provider` to both build tasks, long-form, no alias). No new task-entry PRECONDITION
  for `:aws` either, beyond the permissive config validation pinned at P0.1 (v19). New behavior only under `cloud_provider: :oci`;
  AWS-only subsystems fail fast with `:not_implemented` on OCI.
- Regenerated `.github/workflows` files byte-identical for `:aws` — enforced by the
  per-PR zero-diff rule on `priv/github-action*.yml.eex` + P4.4's template-path
  selection unit test (v10).

---

## Revision Log

**v19 (2026-08-03)** — QUORUM PASSED at v18: round 17 scored 3/3 PASS (mechanism, compat,
completeness) in one round, zero blocking findings. v19 applies only the round-17
certified-MINOR polish: `@doc false` extraction level corrected (wrapping the capability
call, not one layer above or below it); §3.0.6's third-argument contradiction resolved;
gate-5's test descriptor delegates file-set slots to `Providers.Oci`; JSON-recap
accumulator located in the `line_callback`/CI redirect; P3 smoke gains
`grafana.install_dashboard` (the only path reaching `ssh.ex:101`'s jump-host literal) plus
a pure-function pin; §11 names the IN-repo `find_nodes` consumer
(`github-action-setup-nodes.yml.eex:49,:69-70`) and pins `app_name` + the space-joined
`ids` form; `lb.health`'s exclusion reason corrected to producer-phase; `--provider`
switch owned by P2.1, long-form, no alias, and §11 says "adds" not "may add" plus a
no-new-precondition bullet; P4's inventory test restated as THREE clauses (regex is
P0-only) with unknown-key round-trip added; the P0 output pin SNAPSHOTS its oracle
pre-rewire and P0.2 states `parse_instance_info/1`'s fate; P5 gains clause (h)
(conformance tests before each rewiring commit — the largest callback batch has no test
files today); the integration-rule roster synced to the rewritten Done texts; P3.3's five
literals restated per §3.5's census; docs-census ATTRIBUTION derived like membership
(implementer-instruction files owned by the invalidating phase — `.windsurf/**`,
`code_standards.md:49-53`, `Agents.md` carry the same soon-wrong ExAws idiom, one of them
as a reviewer checklist); cite fixes (`terraform.build.ex:123`, log-bucket `:32`,
`deploy_progress.ex:30`/`:40`, `deploy_ex_helpers.ex:188,:206`, `change_planner.ex:138`).

**v18 (2026-08-03)** — adversarial round 16 (1 PASS — mechanism — / 2 FAIL):
- BLOCKING (compat): P3's live smoke could not discriminate the `ssh_user` sweep because
  `mix deploy_ex.ssh` NEVER CONNECTS (`connect_to_host/4` ends at `log_ssh_command/4`,
  connect commented out) → P3 Done gains `restart_app` (the real
  `SSH.run_command/4` → `connect_to_ssh/4` route) + `download_file`, a
  `Config.ssh_user()` unit pin, and P3.3 enumerates the five literals.
- BLOCKING (compat): §11's frozen `find_nodes --format json` key set listed 10 of the
  actual 11 keys (missing `instance_type`), so a pin written to the prose would ACCEPT the
  regression → 11 keys enumerated, pin derives from `aws_machine.ex:354-370`, and the
  v17 either/or is closed in favor of remapping in `output_json`.
- BLOCKING (completeness): the docs census predicate was PATH-ENUMERATED and missed
  git-tracked `.claude/skills/*/SKILL.md` — one of which actively mis-instructs THIS
  plan's implementer (`deploy-ex-dev/SKILL.md:96-99` prescribes the exact
  `ExAws.request(region: ...)` idiom P0 rejects) → predicate becomes DERIVATION-based
  (`git ls-files '*.md'`), the dev skill is owned by P0.2/P0.3 (not P4.6, three phases
  late), the infra skill gets a P4.6 row.
- MINOR: three more machine-readable surfaces frozen (`select_node --short`,
  `ssh -s`, `lb.health --json`); `provider:` also selects the `PrivFileSet` (gate 5 had
  the same unreachable-entry defect) so both build tasks declare the additive switch;
  P4's inventory test uses the DISCRIMINATING pair (`group_<app>` comes from
  `InstanceGroup`, already slug-safe, so it proves nothing); `derive_branch` edit
  relocated to its per-element accessor + id-patterns built before the `++`; §3.0.6 stale
  plan/apply sentence deleted, 7 files/8 sites, third directory arg, unreadable var-file
  SKIPPED; §3.1's unqualified "one line + one module" scoped; lossy providers have TWO
  encoders (HCL seeds tags) with an `encode ≡ decode` pin + census row; JSON recap
  ACCUMULATES (single end-of-run doc, ANSI-wrapped warnings); P0's ExAws list
  phase-attributed like the defaulting allowlist; gate 2's render dir must not pre-exist;
  `connecting_to_nodes.md` doc-vs-code corrections owned; cites
  (`find_nodes.ex:14-15,:22`, `:149`, `terraform.ex:116,:128`, `instance.status.ex:252`,
  `:126-129`).

**v17 (2026-08-03)** — adversarial round 15 (0/3 PASS):
- BLOCKING: the v16 `provider:` injection seam had NO test-reachable entry —
  `OptionParser.parse!` silently drops undeclared switches (MEASURED), and
  `instance.status`'s filter path takes no opts at all, so a test written to v16's words
  would exercise the DEFAULT identity encoding and pass VACUOUSLY → `@doc false`
  opts-taking entry per swept caller (repo precedent `derive_branch/2`), additive
  `--provider` switch permitted, §11 reworded to "additive flags permitted", and the fake
  descriptor must RECORD consultation so a dropped opt FAILS.
- BLOCKING: the caller-sweep predicate (`grep "AwsMachine\."`) is structurally blind to
  `aws_machine.ex`'s NINE intra-module consumers; worst case `find_instance_ips/3`'s own
  return contract is unchanged, so sweeping its callers finds nothing while its body ships
  broken → `mix deploy_ex.ssh <app>` raising for every AWS user at the P0.2 merge →
  predicate widened + `deploy_ex.ssh <app>` added to the P0 live smoke.
- BLOCKING: `find_nodes --format json` is a documented MACHINE-READABLE contract that §11
  never covered, and `%Cloud.Instance{}` renames three keys, drops three, and isn't
  Jason-encodable → §11 freezes `:aws` output shapes + a P0 key-set unit pin.
- BLOCKING: §3.0.2 deferred the inventory-composition encoding test to "P4 Done" (v16) but
  never bound it there — fifth describe-vs-bind instance, on the caller carrying the whole
  GCP story → literal P4 Done bullet.
- BLOCKING: `README.md` was outside the v16 guides predicate yet is the front door and the
  LOUDEST out-of-repo consumer of canonical tag values (`:51` libcluster pairing, plus the
  config block, CI secret table, prerequisites, bootstrap sequence) → predicate widened to
  `README.md Agents.md guides/`, README given a P4.6 row.
- MINOR: QaNode split reduced to ONE shape (`{instance_id, git_branch}` tuples; local
  pattern build; `derive_branch/2` gains a tuple clause); JSON-recap gains a third
  prerequisite (`run_command_streaming` hardcodes `stderr_to_stdout`, parse must skip
  non-JSON); `pem_file_path` added to the renderer-divergence census (three values for one
  assign) + gate 1 declared export_priv-seeded; deny list = 7 callers, resolves against
  `terraform_folder_path()`, RAISES (return type unchanged), plus a P2 negative unit pin
  (the only possible verification, since it never runs under `:aws`);
  `aws_ip_whitelister.ex` leaves the P0 expected-file list with the P0.2 commit; §10
  restated caller-level; P0 Done's "one @providers line" scoped to the dispatcher;
  `check_valid_project/0` failure handling named + `generate_pem` attached to P2.4; deny
  list added to the §3.0.3 census and P5 clause (f); P4.6 docs list replaced by the
  predicate + clustering content; §4 gains the per-provider cluster-strategy deferral;
  CDN paren repaired; cites (`ansible.setup.ex:323,:327`, `build_release_extra_vars/2`,
  libcluster comment hits, `terraform.build.ex:281-282`).

**v16 (2026-08-03)** — adversarial round 14 (0/3 PASS):
- BLOCKING: the caller-level encoding test was described in §3.0.2 and §10 but NEVER added
  to P0 Done (fourth instance of the describe-vs-bind defect) → literal P0 Done bullet;
  and no descriptor-injection seam existed at all (`Application.put_env` banned, Mix tasks
  call `AwsMachine.` directly) → P0.1 threads an INTERNAL `provider:` opt, serving the
  encoding test, gate 5's fake Machine, and P0.2 conformance; the inventory-composition
  clause moves to P4 (the generator doesn't exist until P4.1).
- BLOCKING: the v15 QaNode split dropped `git_branch` — `resolve_targets` feeds
  `derive_branch/2` as well as the limit pattern, and a nil branch silently unpins the QA
  release SHA → the id path carries `{id, tags["GitBranch"]}`, the conflict-raise is
  preserved, `verify_instances_found/2` swept, unit pin added.
- BLOCKING: `%Cloud.Instance{}`'s contract pinned 2 of 3 restrictions — the unconditional
  `Group` PROJECT-SCOPE filter was missing, and flattening it would let ssh/restart/
  download/ebs/db tasks target other projects' instances undetectably → third clause +
  decoy-instance conformance test.
- BLOCKING: §3.0.6 would have turned a tofu WARNING into a hard ERROR on the live AWS
  apply path ("omits nothing" ≠ "no-op") → scoped to non-AWS providers, implemented as a
  per-provider deny list, moved into `Terraform.parse_args/2` (the one site all FIVE
  var-file commands share, not 2 of 5).
- BLOCKING: the JSON-recap gate had no recoverable producer (`ansible.setup` globs all
  playbooks and runs them at `max_concurrency: 4`, interleaving JSON docs) → CI loop uses
  `--only <app> --parallel 1`, with an Elixir-side per-playbook recap producer as the
  preferred refinement.
- BLOCKING: the `check_valid_project/0` exempt list was justified falsely — 6 of the 11
  non-callers are provider-dependent and named in P2/P3.2 → those six add the call in
  their own phase item; the genuinely exempt remainder is enumerated.
- BLOCKING: cluster discovery was entirely absent — libcluster's `EC2Tag` strategy keys on
  the `Group`/`InstanceGroup` tags and queries the EC2 API, so a multi-node non-AWS
  deployment would run without ever forming a BEAM cluster → named as user-side config,
  `EC2Tag` AWS-only, Gossip/DNSPoll documented for non-AWS MVP, per-provider strategy
  post-MVP; plus a §3.0.2 clause that lossy encodings are a USER-VISIBLE contract change
  (`Group` feeds out-of-repo libcluster config).
- MINOR: P2 smoke renders terraform too (P2.3 rewires the shared params) and the
  render-vs-render dance is specified (same project dir, two `path:` deps, canary byte);
  `--render-dir` returns a placeholder pem so `ansible.cfg` still renders; descriptor
  inventory slot wording synced to strategy/template/filename; `aws_ip_whitelister.ex`
  dropped from the P0 expected-file list; `terraform.build.ex:33` added to the exempt
  census; §6.5's two CI mechanisms declared the STANDARD non-AWS ones; guides census gains
  introduction/getting_started/clustering AND a stated grep predicate so it stops being
  patched file-by-file; P5 gains clause (f) guides rows; dispatcher pin allows
  `DeployEx.Config`; §6.1(b) stale conditional removed; cite/count fixes
  (`aws_machine.ex:384`, seven compose vars, 44-of-69 predicate stated).

**v15 (2026-08-03)** — adversarial round 13 (0/3 PASS; ALL THREE lenses converged on the
same primary blocker, which is the signal the fix is right):
- BLOCKING (all 3): the v14 `--render-dir` + `diff -r <tmp> ./deploys/ansible` smoke can
  never be zero — `./deploys/ansible` also holds the seeded non-rendered tree (19 roles,
  setup/, Agents.md), user-customized playbooks, and `--auto-pull-aws` credentials the
  `.eex` renders as a placeholder; plus an absolute render dir changes the rendered
  `private_key_file` byte and the pem glob `Mix.raise`s → **RENDER-vs-RENDER**
  (merge-base vs train HEAD into two scratch dirs), and `--render-dir` is redefined to
  redirect EVERY write (incl. `opts[:directory]`/role sync) and SKIP the pem glob.
- BLOCKING (mechanism): per-instance exit code does not prove ansible reached the host —
  MEASURED on ansible-core 2.18.4, a `--limit` matching a host outside the play's group
  prints "skipping: no hosts matched" and exits 0 → `ANSIBLE_STDOUT_CALLBACK=json` recap
  (`ok>0`) promoted to PRIMARY gate for the SetupComplete write.
- BLOCKING (mechanism): `QaNode.build_qa_node_from_instance/1` has two producers (a
  P0.2-normalized one and QaNode's P5-frozen ExAws path) → documented split:
  `ansible.setup` takes ids from `%Cloud.Instance{}`, the function goes private and stays
  raw until P5.
- BLOCKING (mechanism + completeness): the encoding-layer test was specified at BEHAVIOUR
  level, which cannot detect the very thing it exists for; and P0 Done never named it
  while §10 still prescribed "both providers' fakes" → CALLER-level test
  (`find_nodes`, `instance.status`, inventory composition) against a lossy fake
  descriptor, explicit P0 Done bullet, §10 rewritten.
- BLOCKING (completeness): the defaulting-grep predicate missed
  `Config.aws_release_state_bucket()` (3 live sites, incl. one in a P0.2-absorbed module)
  → predicate widened + the three sites attributed.
- BLOCKING (completeness): `guides/reference/terraform_variables.md` — the most
  provider-coupled guide, and the reference for the schema §3.0.6 forks — was missing from
  the v14 guides census → added, owned by P4.6 + §3.0.6.
- MINOR: §3.0.6 enforcement relocated to `terraform.plan/apply` (terraform.build never
  parses tfvars; tofu only warns) and declared a no-op for `:aws`; `%Cloud.Instance{}`
  gains `qa_node?` + the running/non-nil-InstanceGroup filter as contract clauses;
  descriptor inventory slot split into template+filename (two census sites consume the
  template path); dispatcher pin given an executable form; validation hook named
  (`check_valid_project/0`, 58/69 tasks) + per-provider input + `nimble_options` added as
  a direct dep; key-pair row becomes a 4-tuple (resource NAME required); CliRunner passes
  `stderr_to_stdout: false`; `release.ex:6-7` re-attributed from EXEMPT to P1-moves (a
  mis-attributed hit passes the gate silently); resource-type freeze census completed (5
  sites incl. 2 inline); OCI config block gains the storage keys a strict schema would
  otherwise reject; P5 rule list gains (d) map rows and (e) gate-5 fixture row;
  `terraform_backend` dispatch added to the §5.3 seam census; §3.0.5/§3.0.6 reordered;
  `aws_ip_whitelister` wording; §6.1(a) failure is LOUD not silent; cite/count fixes
  (auto-pull `:142-163`, `generate_pem.ex:46`, `ansible.build.ex:240`, replace `:67-73`,
  145 ExAws lines, guides 21 keys/44 lines, TUI 24-of-25 synced in both places).

**v14 (2026-08-03)** — adversarial round 12 (0/3 PASS; blockers converged across lenses):
- BLOCKING (all 3 lenses): §3.4 still baked `--output json` into the shared `CliRunner` —
  the exact OCI-ism §3.0.5 forbids and the v13 log claimed removed (half-applied edit) →
  §3.4 now defers to the adapter's arg list.
- BLOCKING (all 3 lenses): P0 Done pinned "no hardcoded provider literals" against a
  `@providers` registry the same doc mandates → restated as "no capability/behaviour-module
  literals; adding a provider = one registry line + one descriptor".
- BLOCKING (mechanism + compat): P2/P4 `--force` smokes were DESTRUCTIVE against the live
  tree (re-render `group_vars/all.yaml`, wiping `--auto-pull-aws` credentials that only
  the first-run seed injects, which Loki/Prometheus templates then push to hosts) AND
  non-discriminating on hand-edited projects → both smokes become
  `--render-dir <tmp>` + `diff -r`, the non-destructive discriminating form.
- BLOCKING (mechanism): the inventory hostname convention rested on `qa_node.ex:220-223`'s
  unverified claim that the `aws_ec2` plugin composes `<instance-id>-<Name>`; MEASURED,
  `aws_ec2.yaml.eex:6-7` yields the BARE Name tag → P0 gains an `ansible-inventory --list`
  measurement (a possible PRE-EXISTING AWS `--limit` bug to report, not inherit), and the
  OCI generator emits the instance-id prefix BY CONSTRUCTION.
- BLOCKING (compat): per-provider NimbleOptions validation would hard-fail existing AWS
  users (flat config namespace, unknown keys, legitimately-nil keys) → the `:aws` schema is
  PERMISSIVE by contract + a P0.1 unit pin.
- BLOCKING (compat): v13 table-ized `generate_pem`'s resource-TYPE reads with no pin or
  smoke → §11 freeze extended to resource-type strings, P2.4 pin widened, `generate_pem`
  added to the P2 smoke; map row gains a `:basename | :filename` unit (AWS appends `.pem`,
  OCI's filename already carries it).
- BLOCKING (completeness): the canonical-tag encoding layer had NO test owner (both
  implemented columns are identity encodings, so fakes prove nothing) → P0 Done contract
  test against a test-only LOSSY fake encoder pinning all four clauses.
- BLOCKING (completeness): the 20-file `guides/` Diataxis tree was unowned (config
  reference table, mix-task flags, architecture) → §1 Tier-C entry + P4.6 sub-item +
  descriptor census row.
- MINOR: tag filter typed as LIST not map (`find_nodes` AND-semantics would silently
  change); `qa_node_suffix` added to the compose contract; ASG address row optional/`nil`
  until P5; CI `--host-only` still syncs roles (stated); inventory filename + default SSH
  user become descriptor slots with real shapes; validation point unified on TASK START;
  P4 inventory pin corrected to six sites; §9/§2 4-column wording synced to the event
  trigger; P5 echoes all three universal rules; gate triggers worded per provider;
  §3.0.6 promoted (variables sets omit unimplemented features); TUI count 19→24-of-25;
  `terraform.ex` cite synced to `:104-135`; three text-damage repairs.

**v13 (2026-08-03)** — adversarial round 11 (0/3 PASS; 8 blockers across 3 lenses):
- BLOCKING (compat): tag FILTER VALUES are matchers (`scalar | [scalar] | Regex.t()`,
  `aws_machine.ex:372-380`), and `instance.status.ex:107-110` depends on the regex arm
  against `InstanceGroup = "<snake_app>_<env>"` — an exact-match spec returns zero
  instances for every ASG-path instance → §3.0.2 third contract clause (push down exact
  matchers only; evaluate non-literal matchers client-side post-decode) + P3 smoke gains
  `instance.status` + a regex unit pin.
- BLOCKING (completeness): provider descriptor had no phase item and §3.1 still showed
  v9's inline map → P0.1 builds descriptors, dispatcher DERIVED, P0 Done pins
  no-hardcoded-literals, slot fill schedule stated.
- BLOCKING (completeness): 4-column check was phase-triggered, so Phase-5 behaviour
  extractions and post-P0 callback additions escaped → EVENT trigger (any callback
  added/changed in any phase needs its row before ITS PR merges).
- BLOCKING (mechanism): v12's CI regen (`mix ansible.build`) is a silent no-op in CI
  (`write_file` prompt + `IO.gets` → `:eof`) and raises on the PEM glob →
  `--force --host-only` prescribed.
- BLOCKING (mechanism): "gate SetupComplete on ansible reaching the host" had no
  producer (per-app aggregate exit vs per-instance tag loop) → per-instance
  `ansible.setup --instance-id` loop, tag on that exit; JSON-callback recap named as the
  alternative.
- BLOCKING (mechanism): inventory contract cited only keyed_groups/compose — missing
  `hostnames:` (which `--limit '<instance-id>*'` globs on) and the project `filters:`
  scope → 4-part contract + S4 gains the `--limit` discriminating measurement.
- BLOCKING (mechanism): §5.3 claimed `generate_pem` "works unchanged" while §5.2 deletes
  the OCI key-pair resource → real mechanism (filename from `local_file.ssh_key` +
  `@pem_app_name`; per-provider `{key_source_type, filename_attribute}` row).
- BLOCKING (mechanism): P2/P4 "zero `./deploys` diff" smokes are non-discriminating
  without `--force` (a byte-changing regression prompts, non-`y` leaves file untouched)
  → both smokes now specify `--force`.
- MINOR: `CliRunner` no longer bakes `--output json` (gcloud uses `--format=json`);
  OCI `tag` callback is a documented NO-OP (qa marker already in the key via
  `ReleaseUploader.State`; the tag has zero readers); CI shell scripts added to the
  census + gate-3 glob widened to `priv/github-action*`; gate path predicate is a
  path-COMPONENT test; gates 1/2/4/6 count-proof vs 3/5 provider-instanced; Security
  façade dropped (leaf module registered); `file_sd` declared the standard non-AWS
  Prometheus mechanism; polarity remnants swept (§1, §4); SG dead-reader literal cut
  from the address map; inventory template labeled render-template not plugin config;
  descriptor census gains guide/CI-secrets + column promotion; inventory filename
  single-owned by the descriptor; cite fixes (`:385`, `terraform.ex:104-135`).

**v12 (2026-08-03)** — adversarial round 10 under the new assumption (1 PASS / 2 FAIL):
- BLOCKING (R1): static-inventory decision broke both CI workflow mirrors (they'd run
  ansible against a stale committed inventory; AWS never needed regen — plugin resolves
  live) → OCI workflows regen inventory (`mix ansible.build`) before setup/deploy;
  SetupComplete write gated on ansible actually reaching the host; CI added to §6.1
  staleness consumers.
- BLOCKING (R3): 4-column check had no Done owner and its artifact no committed
  location → P0 Done bullet + `2026-08-03-provider-columns.md` + write-back rule.
- MINOR: gate 6 (registry classification: `providers.tf.eex` → AWS set; gates catch
  leaks, harness catches drops); gate 2 runs under `--render-dir` (`.terraform/providers`
  false-trip); gate 5 rendered-entry carve-out + fake-Machine inventory; §3.0.2 OPEN
  canonical map + slug post-verify clauses; §3.0.3 honest registration census (address
  table, resource-type map, full_setup list, TUI enum, ToolInstaller); guard polarity →
  "any provider ≠ :aws"; tagging fork removed from P1.2/S1 (key-prefix is the design);
  `S3ObjectStore` naming unified; registry-changes wording + generic derivation rule;
  gate counts five→six.

**v11 (2026-08-03)** — REOPENED: assumption change (GCP & Azure anticipated; quorum
raised to 3 clean passes in one round). N-provider redesign of retrofit-expensive
contracts, zero new implementation scope:
- §3.0 N-provider design rules: 4-column design check (blocking P0 criterion);
  canonical-tag encoding layer (GCP label constraints break raw-tag portability —
  spaces/caps in `Group`, slashes in `GitBranch`); provider descriptor module;
  optional-capabilities with portable defaults; shared `CliRunner`.
- Layout convention: all non-AWS providers under `providers/<name>/`; AWS complement
  rule + gates written ONCE (`zero providers/* paths`) — per-provider registry churn
  eliminated.
- §3.3 reframed: ObjectStore behaviour neutral, `S3ObjectStore` = impl #1 (AWS/OCI/GCS-interop
  paper column), Azure Blob = future separate impl; object tagging demoted to OPTIONAL
  capability — key-prefix is the DESIGN for OCI+, AWS tagging frozen.
- §6.1 DECISION CHANGED: static-inventory generator from `Cloud.Machine` is the standard
  non-AWS mechanism (one generator, N providers, no galaxy/SDK deps, encoding-safe);
  `oracle.oci.oci` plugin demoted to fallback; S4 reframed accordingly.
- §5.5 backend + §6.3 completion marker = descriptor slots (gcp/azure paper columns:
  native gcs/azurerm backends).
- Non-goals rewritten (trajectory statement); §9 gains the "N-proofing turns
  speculative" risk with its mitigation.

**v10 (2026-08-03)** — QUORUM PASSED at v9: round 9 scored 3/3 PASS (mechanism, compat,
completeness), zero blocking findings; required quorum was 2. v10 applies only the
round-9 certified-MINOR polish: aws_manager defaulting-sites correction; P0.3 stale
clause deleted; doc-interpolation residuals attributed exempt; per-PR zero-diff rule
extended to CI templates + §11 CI-files bullet; P1 bucket-lifecycle check; cite
tightening (ansible.deploy :358-359, auto-pull :142-163, awscli :3-6, SG :137-143).

**v9 (2026-08-03)** — adversarial round 8 (3 FAIL, all on ONE converged blocker; all
three reviewers ran the grep and produced identical hit sets):
- BLOCKING: allowlist closed against the measured grep — `find_nodes.ex:37`,
  `instance.health.ex:63`, `instance.status.ex:237` → clears-P3;
  `ansible.setup.ex:189` → clears-P4 (explicit); `create/drop_state_bucket` → P1-moves;
  new impl-side-permanent bullet (four conforming impls + S3ObjectStore) with
  absorbed-module fate stated (P0.2 migration; residual hit = gate failure by design);
  "unattributed hit = plan amendment, never ad-hoc pass"; P0.3-vs-P1 move timing pinned
  (P0.3 threads, P1 moves).
- MINOR: §6.5 CI SetupComplete write bound to S5's read-merge-write guard; ssh_user
  `"admin"` census extended (ssh/download_file → P3.3; qa/load_test → P5); P5 item-level
  smoke rule; cite fixes (ansible.deploy :301-302, view :25-26, list :27-28,
  terraform.build attrs :5,:7, loki :60).

**v8 (2026-08-03)** — adversarial round 7 (1 PASS — mechanism lens — / 2 FAIL on ONE
converged blocker):
- BLOCKING (R2+R3, converged): the v7 storage-defaulting grep predicate was unsatisfiable
  (≥60 hits in modules the plan itself freezes) → predicate kept, allowlist made FULL with
  per-phase attribution (P1-moves / permanent-exempt / clears-P3 / clears-P5); each phase
  re-runs the grep and clears its own entries.
- MINOR: S5 gains the discriminating measurement for OCI freeform-tag REPLACE semantics
  (pre-existing tags must survive the marker write) + tf `ignore_changes` note; gates 2+4
  restated as path-set equality + byte-equality for non-rendered entries (rendered bytes
  owned by P0.0); S4 gains control-machine collection/SDK deps; P0.0 render-only skips
  the ToolInstaller preflight; P1 smoke gains a lookup consumer; P0.3 defers to §3.2 as
  single source of truth; `terraform.build.ex:18` ghost flag censused; cite fixes
  (save_ami :18, packages :3, delete_request_store :61, AwsMachine 39 raw lines, SG parse
  :138-143).

**v7 (2026-08-03)** — adversarial round 6 (1 PASS / 2 FAIL):
- BLOCKING (R1): P0.2 raw-map consumer census was 2 sites; measured ~15 (lb.health, ebs
  tasks, grafana, qa.cleanup, qa_node, k6_runner, instance.health/status, select_node,
  find_nodes) → §3.2 caller-sweep transition contract: grep-defined caller census, ALL
  callers swept in the producer's own commit, NO dual-shape period; P0-smoke coverage
  claim re-attributed.
- BLOCKING (R1+R2): P4 Done drifted from the rule's promised build/ping smoke → P4 Done
  gains `ansible.build` zero-diff + `ansible.ping` + the `:aws` inventory-filename unit
  pin across all four call sites.
- MINOR: storage-defaulting census restated as a grep-defined class (P1 exit runs the
  grep); find_nodes/ssh/restart_machine already-neutral flags + instance.health dead
  `--region` + terraform.build ghost `aws-bucket` moduledoc added to census/P0.3; stale
  duplicated threading sentence deleted; `ansible.build.ex:222` added to row 5;
  `resource_databases` added to the §4 validation-error sentence.

**v6 (2026-08-03)** — adversarial round 5 (3 FAIL; two converged blockers):
- BLOCKING (all 3): Phase 2 omitted from the "ALL phases" integration rule (enumeration
  drift, same class as rounds 3-4) → rule restated as UNIVERSAL (trigger test governs; a
  phase Done without a live smoke is a doc defect); P2 Done gains its live AWS smoke
  (`terraform.plan --target` + `ansible.build` zero-diff + QA sync cycle) and a unit pin
  for frozen AWS address strings.
- BLOCKING (R2): `--aws-release-bucket` is a LIVE flag on upload/release/qa.create/
  qa.deploy, uncensused → census split by flag family; threading rule covers bucket flags;
  §11 amended; pinning test extended; `release_lookup.ex:196-197` +
  `ansible.rollback.ex:37-38` defaulting sites named for Phase 1.
- MINOR: P0 expected-file list gains the four conforming AWS impl modules; gate 5 (OCI
  merged-tree equality) added — the variant-wins assertion now has an owner; gate 3
  declared additive/overwrite-only + user-custom-role survival fixture;
  `priv_renderer.ex:157-158` inventory hardcode added to row 5; moduledoc-drift census
  extended (upload/release); P4.4 `:aws` template-selection unit test; P4.5 `:aws`
  command-list unit test; cite fixes (configparser_ex `:44`, QaNode 35 ExAws lines).

**v5 (2026-08-03)** — adversarial round 4 (2 PASS / 1 FAIL):
- BLOCKING (R2): v4 integration rule covered only Phase 0 → generalized to all
  live-path phases with named per-phase live AWS smokes; P1 Done gains the AWS-side
  storage smoke.
- MINOR: gates 2+4 restated to current-registry equality (no frozen pre-OCI baseline);
  SetupComplete writer census corrected (create-time seeds + k6 self-tag; OCI = no seed,
  absent == incomplete); §6.2 variant-delivery wording (registry flatten delivers bytes,
  playbooks pick names); S5 row renamed CloudInitComplete; S1 gains bucket
  lifecycle/compartment + native-CLI fallback; on-boot oci-CLI install named in §6.3;
  flag census corrected (ansible.build 12th flag exempt + dead; view/list release tasks
  already neutral-switched); loki dead-assign swap documented in §5.1; ebs-snapshot
  files added to P0 expected-file list; dispatcher fill-per-phase comment; CI cite fix;
  Config key count 15→14.

**v4 (2026-08-03)** — adversarial round 3 (3 fresh reviewers, all FAIL, findings narrowing):
- BLOCKING (R1): SetupComplete dual-writer contradiction (OCI cloud-init self-write vs
  CI-written post-ansible meaning) → distinct `CloudInitComplete` marker (§6.3, §5.2,
  §6.5, P2 Done).
- BLOCKING (R1): PrivFileSet rows 1-4 had no source→dest placement for non-rendered OCI
  files → explicit flatten mapping + variant-wins merge semantics + OCI sync gate (§5.1).
- BLOCKING (R2): export_priv bypassed all gates; filter placement ambiguous → filter at
  `PrivRenderer.render_to_temp` choke point + gate 4 (export fresh-fixture + manifest
  equality); "export" added to §11.
- BLOCKING (R2): unguarded live-path window between Phase-0 merges → integration rule:
  live-consumed branch merges only after exit smoke (P0).
- BLOCKING (R3): §6.4 monitoring mechanisms violated the §6.2 byte-frozen rule →
  `prometheus_db` + `grafana_loki` OCI role variants (§6.4, P4.2).
- MINOR: gate-3 restated (current-tree equality + per-PR zero-diff rule); ansible-seed
  .eex-removal cite fixed; flag census 9→11 (+`view_current_release`,
  `list_app_release_history`); ObjectStore bucket-lifecycle callbacks +
  `drop_state_bucket`; `--auto-pull-aws` census + `:oci` validation error; dualstack cite
  both playbooks; `aws_db_instance` type fix; dead public-IP grant dropped; outputs
  shape-parity test YAGNI-cut (zero callers); P2.1/P0.3/P3.2 lists updated;
  restart/start/stop_app in P3.2; mix.exs dep count fixed.

**v3 (2026-08-03)** — adversarial round 2 (3 fresh reviewers, all FAIL):
- BLOCKING (R1+R2): 5th copy path — ansible first-run seed (`ansible.build.ex:91-113`) —
  missed by the §5.1 census, and both seed paths invisible to the seeded-fixture gate →
  six-path census (§1 h3), fresh-project fixture gate, `full_drop`→`full_setup` re-seed
  route covered.
- BLOCKING (R1+R2): shared-role edits (letsencrypt in-role branch; ipv6 ".eex-gated" role
  line — roles are never rendered) contradicted the zero-diff contract; +
  `AnsibleRoles.sync/1` second sync site → §6.2 ground rule (shared roles byte-frozen; OCI
  role variants; playbook-layer gating), role-sync byte-equality gate.
- BLOCKING (R3): `save_ami` unconditional in setup playbook → OCI render omits it (§6.2,
  P4.2).
- BLOCKING (R3): `aws-s3-upload-bucket`/CloudFront feature absent → §1 Tier-C, §4
  deferral, OCI variables omit `upload_buckets` with validation error.
- BLOCKING (R2): P0 QA smoke too weak (`qa.list`) → create→deploy→destroy round-trip in
  P0 Done.
- MINOR: P0.0 drives real task entry points (+ `--render-dir` path/pem prerequisites);
  region-threading scoped to behaviour-consuming tasks (terraform.build + ebs-snapshots
  exempt); caller example `find_instance_details/3` + raw-map consumer sweep; §5.3 cite
  fix (`get_app_display_name`) + 4th address site to Phase-5 backlog; §6.5 dual credential
  sets; `show_password` in P0.4; `ansible.ping`/inventory-filename hardcodes in P4.1;
  `remote_user` templating note (§3.5).

**v2 (2026-08-03)** — adversarial round 1 (3 reviewers, lens-diverse, all FAIL):
- R1/R2 BLOCKING render-gate unimplementable → P0.0 deterministic-render harness; §11 reworded.
- R2 BLOCKING priv whole-tree copy leaks (seed cp_r, sync_ansible_roles, PrivRenderer/
  ChangePlanner/upgrade_priv) → §5.1 PrivFileSet + fixture zero-action gates; jaro
  false-rename data-loss path closed.
- R3 BLOCKING CI/CD surface missing → §1 Tier-C, §6.5, Phase 4.4, MVP line.
- R3 BLOCKING full_setup dies on OCI lock-table → `{:ok, :skipped}` + provider-gated
  pipeline, Phase 4.5.
- R1 BLOCKING S4 fallback needed Phase-4 module in Phase 3 → Phases 3↔4 swapped.
- R2 BLOCKING `--aws-region` flags silently ignored → §3.2 region threading.
- R1 MINOR outputs-contract misread → §5.3 real seam (raw tfstate resource reads);
  §1 hazard 7.
- R1 MINOR `build_target_string` missing from address map → §5.4 three sites.
- R1 MINOR render/seed subpath+flatten mechanics → §5.1 table.
- R1 MINOR SetupComplete identity grant → §5.2 + S5.
- R1/R3 MINOR grep gate false-positive (`tui.ex:7`) → expected-file list in P0 Done.
- R2/R3 MINOR letsencrypt AWS behavior change → dropped; AWS byte-frozen (§6.3).
- R3 MINOR static setup playbooks unreachable by .eex gating → additive OCI copies (§6.2).
- R3 MINOR Phase-0 YAGNI (8 behaviours → 4) → §3.2 trim; QaNode/K6Runner ExAws deferred.
- R2 MINOR untested modules rewired → P0.2 conformance-tests-before-rewire + QA smoke.

---

## 12. v20 Amendments — MEASURED at HEAD `abc18c6` during execution (2026-08-04)

Produced by four independent recon agents + an architect during the P0 execution cycle, all
MEASURED against the live tree. These CORRECT the plan; where an amendment conflicts with an
earlier section, **the amendment wins**. Numbering is stable for citation.

**A1.** P0.0 bullet 1 is UNIMPLEMENTABLE as written for PrivRenderer. Plan text: 'pem_app_name/generate_db_password accept values via opts (both renderers)'. MEASURED: PrivRenderer has NO generate_db_password; priv_renderer.ex:95 is the literal `db_password: "placeholder"`, and export_priv.ex:106-111 hashes that byte into .deploy_ex_manifest.exs (the byte gates 1 and 4 compare). Amend to: pem_app_name injectable in BOTH renderers; db_password injectable in terraform.build ONLY (PrivRenderer is already deterministic there and must stay untouched). §5.1 line 915 already records the divergence, so this is a P0.0 wording defect, not a design defect.

**A2.** NEW, MEASURED this session, not in the plan and not in the recon: `db_password` reaches ZERO templates. `grep -rn '@db_password' priv/` returns 0 hits; the RDS password is generated by terraform itself (priv/terraform/modules/aws-database/main.tf:10 `resource "random_password" "rds_database_password"`, consumed at :95). The ONLY injected value that reaches rendered bytes is pem_app_name (priv/terraform/key-pair-main.tf.eex:9, 1 hit). Consequence: `--db-password` is unobservable in render output, so any Done criterion asserting 'pinned db_password produces identical bytes' passes VACUOUSLY. Amend P0.0's Done wording so the byte-determinism gate is pem_app_name-only; db_password injection remains (plan-pinned, one line, useful for P2.3's shared-params extraction) but its criterion is switch-acceptance plus preserved random default, not a byte diff.

**A3.** P0.0's --render-dir contract must be SPLIT PER TASK; as written it reads as one uniform mechanism and an implementer will build one shared flag handler and miss a live write. MEASURED: terraform.build's only write root is opts[:directory] (:29 default, :51 into params, :288 write target) and it already has -d/--directory at :105 — so --render-dir there is exactly `--directory` + skip :41 (ToolInstaller) + skip :90-93 (init). ansible.build is the hard case: the three targets at :39-41 are hardcoded './deploys/ansible/...' STRING LITERALS independent of opts[:directory], and group_vars is written from INSIDE the seed (create_ansible_group_vars_file called at :105 during ensure_ansible_directory_exists, before the with-chain call at :55). A --render-dir that only overrides :37 would still write the live ./deploys/ansible/group_vars/all.yaml on a fresh render.

**A4.** P0.0 attributes ansible.build.ex:263-264 to build_host_playbook/build_host_setup_playbook. MEASURED: :263-264 are in create_ansible_playbooks/2 (mkdir_p! at :267/:271). The write paths inside the two NAMED functions are :310 (playbooks/<app>.yaml) and :329 (setup/<app>.yaml). All four are opts[:directory]-derived so the redirect requirement is right; only the function attribution is wrong.

**A5.** Seed-guard line numbers are internally inconsistent in the plan itself: line 860 says terraform.build.ex:122, line 872 says :123. MEASURED: :122 is the defp head, :123 is the `if File.exists?(directory)` guard. Gate 2's 'render dir MUST NOT pre-exist' clause depends on citing the guard, not the head. ansible.build.ex:92 is correct as written.

**A6.** §5.1 line 841 says the provider filter 'lives at that choke point... PrivRenderer.render_to_temp itself (priv_renderer.ex:45,:132)'. MEASURED: render_to_temp/1 is :13-37 and is NOT a copy site. :45 and :132 are two separate copy_directory/2 CALL SITES inside render_terraform/2 and render_ansible/2, both funnelling into ONE shared helper at :360-364. Amend to name copy_directory/2 (:360-364) as the single choke point — row 6's fuller citation (:45,:132,:360-364) is the accurate one. This matters because a filter placed in render_to_temp covers nothing, and because P2 gates 4/5 need the filter in copy_directory to stop nested providers/oci/*.tf.eex files surviving into the export temp tree and getting hashed by export_priv.ex:96-111 (PrivRenderer strips .eex ROOT-ONLY at remove_eex_files/1 :366-373 while terraform.build's seed strips RECURSIVELY at :135 — MEASURED zero nested .eex today, so the asymmetry is latent until providers/oci lands).

**A7.** §3.0.2's MEASURED claim that `OptionParser.parse!` silently drops undeclared switches is FALSE in the environment the plan applies it to, and it is the SOLE stated justification for the P0 injection-seam design (plan :285-313). MEASURED this session, Elixir 1.17.3/OTP 27: the drop happens only when the atom does not already exist. Under `mix run --no-start` with the project compiled, String.to_existing_atom("provider") succeeds and find_nodes' exact parser returns {[provider: "fake_lossy", format: "json"], []} — the flag is KEPT. Consequences: the 'UNREACHABLE from a test' premise at :290-292 collapses; the v17 finding recorded as blocking was resolved against a wrong measurement; the parenthetical at :309-310 about terraform.build/ansible.build is wrong for the same reason. The @doc false entry point is still the better design (keep/drop is contingent on implicit atom-table state and flips under a release or a differently-named flag) but the plan must be rewritten to say THAT, and the claim must lose its MEASURED label until re-measured under `mix`.

**A8.** §3.5's permissive-config pin has NO injection seam and is untestable as written. Plan :730-736 requires 'task start with today's full flat env PLUS one arbitrary unknown key returns no validation error', with :aws reading Application.get_all_env(:deploy_ex) INTERNALLY. Application.put_env/3 is banned in tests (test/deploy_ex/Agents.md:9; MEASURED zero put_env calls in test/). Amendment (baked into the P0.1 contract): the config SOURCE must be an explicit argument — `DeployEx.Cloud.validate_config(provider, env)` as the pure, testable arity, with a convenience arity reading the real source. Precedent already in-repo: DeployEx.ProjectContext.check_valid_project/1 (project_context.ex:119) takes an injectable `mix_project \\ Mix.Project`.

**A9.** §3.0.6 / P2.2 WILL NOT COMPILE as written. terraform.ex:7-9 defines a public parse_args/1 whose body is `parse_args(args, nil)`. Plan :395 explicitly rejects a defaulted `\\ nil` third argument, so converting parse_args/2 to /3 leaves :8 calling an undefined parse_args/2 — a hard compile error in the same module. parse_args/1 has ZERO callers repo-wide (MEASURED: all 8 DeployEx.Terraform.parse_args call sites are 2-arity). Resolution is trivial (delete it, or have it delegate with a nil directory) but the plan must state its fate the way §11 states parse_instance_info/1's. Not a P0 blocker; flagged so P2.2 does not discover it at implementation time.

**A10.** P0 'Done' is arithmetically under-specified for a CI-compared EXACT list. The permitted list is stated as 12, but the same paragraph attributes instance.health.ex and instance.status.ex as clears-at-P3, so the file set legitimately holding `ExAws.` at P0 EXIT is 14, not 12. The number 14 appears nowhere in the plan. Additionally: aws_ip_whitelister.ex is described as 'leaving the list with the P0.2 commit that empties it', so the list has 13 entries for part of P0.2 — and 'capability-per-commit' + 'compared in CI' means every intermediate commit must pass. The checked-in list must be written in its P0-exit form with a per-entry clears-at column (permanent | clears-at-P3) and the owning commit for each list edit named.

**A11.** P0 Done's false-positive warning about the ExAws CI gate is wrong in specifics. MEASURED: `grep -rln 'ExAws\.' lib/` (the dotted form used for the 18-file census) never hits tui.ex — the token at tui.ex:7 is bare `ExAws` with no dot. Only the UNDOTTED grep false-positives, and it yields TWO non-call hits, not one: lib/deploy_ex/tui.ex and lib/deploy_ex/Agents.md (a tracked markdown file inside lib/). Also tui.ex:7 is prose inside the @moduledoc block opened at :2, not a `#` comment — a gate written to strip comments would still hit it. The gate must specify: dotted pattern `ExAws\.`, scoped to lib/**/*.ex, and must decide whether `alias ExAws.S3`-style lines count (3 of the 145 measured lines are aliases, at aws_bucket.ex:2, aws_dynamodb.ex:2, aws_ip_whitelister.ex:2 — all 3 in files P0.2 is supposed to EMPTY, so a leftover alias is exactly the residue the gate exists to catch).

**A12.** §3.0.2's v13 clause and its P3 unit pin (plan :323-337) are anchored to modules/aws-instance/main.tf:647, which is NOT an instance tag. MEASURED: :647 sits in the resource-level `tags = merge({...})` block (:645-652) of `resource "aws_launch_template" "ec2_lt_templates"` — it tags the LAUNCH TEMPLATE object, which DescribeInstances never returns. The instance-facing write of `<snake>_<env>` is main.tf:698-702 (aws_autoscaling_group.ec2_asg_templates, propagate_at_launch = true), corroborated by the data source at main.tf:389-393. Re-anchor to :698-702. Also narrow the claim: 'an exact-match spec returns ZERO instances for EVERY ASG-path instance' is overbroad — aws_autoscaling_group.ec2_asg (:495) propagates the BARE local.snake_instance_name (:538-542); only ec2_asg_templates carries `<snake>_<env>`. The %Regex{} arm survives regardless, partly for a reason the plan never states: the matcher at instance.status.ex:108 is UNANCHORED, so `my_app` also matches `my_app_redis`.

**A13.** §11's compat freeze cites the wrong mechanism for the space-joined `--format ids` form. Plan :1667 says ':52's wc -w depends on the SPACE-joined form'. MEASURED: `wc -w` counts whitespace-separated words and is separator-AGNOSTIC — newline-joined ids give the same count. The genuinely space-dependent consumers are priv/github-action-setup-nodes.yml.eex:54 (`echo "incomplete_nodes=$INCOMPLETE_NODES" >> $GITHUB_OUTPUT` — a multi-line value corrupts GITHUB_OUTPUT without a heredoc delimiter) and :80 (`grep -q`). The conclusion (freeze the space form) is right; a P0 pin written against the :52 rationale would not catch a separator regression. Separately: guides/how-to/connecting_to_nodes.md:97 documents `--format ids` as 'newline-separated instance IDs' while find_nodes.ex:153-158 joins with a SPACE — shipped doc contradicts shipped code, and no plan item (P4.6 docs sweep included) owns fixing that line.

**A14.** §3.2's 'has_tag?/3 has a %Regex{} arm' is correct but omits that it is `defp`, not public (aws_machine.ex:372-380), as is filter_instances_by_tags/2 (:405-412, which supplies the AND across filters via Enum.all?). Any Cloud.Machine behaviour-conformance test must go through the public arity-2 functions (find_instances_by_tags/2 :317, find_instances_needing_setup/2 :326, find_instances_setup_complete/2 :340). Worth stating before P0.2 writes conformance tests against an unreachable private function.

**A15.** §1 calls the Tier-A set '10 leaf modules ... under lib/deploy_ex/'. MEASURED: only 9 live at lib/deploy_ex/aws_*.ex; the 10th is DeployEx.ReleaseUploader.AwsManager at lib/deploy_ex/release_uploader/aws_manager.ex. Any gate written as a path glob `lib/deploy_ex/aws_*.ex` silently drops one module.

**A16.** Config key count: §1 says '14 of 24 DeployEx.Config keys are AWS-specific'. MEASURED 14 aws_-NAMED + 10 neutral-named = 24, so the number is right — but the honest classification is 14 aws_-named + 1 AWS-DEFAULTED (terraform_backend/0 at config.ex:79, `Application.get_env(@app, :terraform_backend, :s3)`) = 15 AWS-coupled. The plan tracks terraform_backend separately at :968-969/:1012 so nothing is lost; noting it so a future reader does not re-litigate the 14-vs-15 delta. Also 3 of the 14 (aws_project_name, aws_names_include_env?, aws_resource_group) are AWS-NAMED but provider-NEUTRAL in semantics — which is exactly what makes §3.5's neutral-accessor delegation viable.

**A17.** Cosmetic line-span drift, bundled — none change a conclusion, but contracts are written against the measured values: Section 1 item 5 cites terraform.build.ex:280 for the render glob (:280 is the bare pipe head `terraform_path`; the glob is :281-282, as §5.1 row 5 correctly says). priv_renderer.ex params range: §5.1 line 913 says :74-120, P0.0 line 1303 says :74-124; the function is :74-124 and :120 is mid-map. ansible.build.ex OptionParser is :69-86, not :69-87 (:87 blank). pem_file_path/2 is :235-253, not :235-254. create_ansible_config_file/1 is :191-214, not :191-206. find_nodes.ex: the case block is :41-55 not :41-53; parse_args/1 is :68-84 (call :69-81) not :67-79; build_tag_filters/1 is :86-95 not :86-97; Keyword.get_values(:tag) is at :91 not :71 (and the `tag: :keep` switch is :73). instance.status.ex:113 is fetch_elastic_ips(), NOT the AwsLoadBalancer call — that is :114 alone. config.ex flat get_env span is :4-83, not :4-90. Section 1 item 3 cites deploy_ex_helpers.ex:34-41 as part of the role-sync COPY path; :34-42 is priv_folder/1, a path RESOLVER, not a cp_r! site. §5.1 row 3 calls the role sync 'every build'; it is gated at ansible.build.ex:350 on BOTH priv_roles and target_roles already being directories, so it no-ops on a tree with no roles/ dir yet — 'every build post-seed' is the accurate wording.

---

## 13. v21 Amendments — MEASURED against a live OCI tenancy (2026-08-07)

Produced while wiring real OCI access. These **override** §3.3, §3.4 and §3.5 where they conflict.

**B1. §3.3 IS REFUTED — ExAws cannot reach OCI object storage.** The plan's "S3-compat is impl #1,
OCI reuses the ExAws `S3ObjectStore`" does not work. MEASURED three ways:
`ExAws.request(region: "ap-seoul-1")` RAISES `s3 not supported in region ap-seoul-1 for partition
aws`; ExAws's partition table is COMPILE-TIME (`ex_aws/config/defaults.ex:163`,
`@partition_data Code.eval_file("priv/endpoints.exs", File.cwd!())`), so no runtime override or
region-keyed host map can register an OCI region. Signing with a valid AWS region instead
(`region: "us-east-1"` + OCI host) DOES send but returns **HTTP 403 "The secret key required to
complete authentication could not be found. The region must be specified if this is not the home
region"** — OCI requires the OCI region inside the SigV4 credential scope. CONTROL: the `aws` CLI
signing `--region ap-seoul-1` against the same endpoint with the same credential SUCCEEDS.
**Resolution: `Cloud.OciObjectStore` drives the `oci` CLI via §3.4's CliRunner.** MEASURED working
roundtrip: `oci os bucket create` -> `object put` -> `object list` -> `object get`.
CONSEQUENCE: **Customer Secret Keys are NOT required** — the CLI uses a session token locally and
instance principals on-instance, mirroring AWS instance profiles. This removes a long-lived
credential from the design and collapses §3.3's hybrid into ONE mechanism.

**B2. No usable OCI SDK exists for Elixir/Erlang — §3.4's CLI choice is now EVIDENCED, not assumed.**
`ex_oci_sdk` 0.2.2 supports **only the Queue service** (no Object Storage/Compute/Networking/
Identity; 51 commits). "OCI" in the Erlang ecosystem means Oracle **Call Interface** (the Oracle
DATABASE driver, e.g. `erloci`), a different product. Seventeen adversarial rounds never checked
this; the design was right for a reason nobody had verified.

**B3. IAM writes go to the HOME REGION, which differs from the resource region.** MEASURED:
`oci iam compartment create` against `ap-seoul-1` fails `NotAllowed — "Please go to your home region
YNY to execute CREATE, UPDATE and DELETE operations"`. Home region is `ap-chuncheon-1`; resources
live in `ap-seoul-1`. This is universal OCI behaviour, not tenancy-specific. §3.5's single `region`
key is therefore insufficient — **the descriptor needs a `home_region` slot distinct from the
resource region**, and §5.2's identity resources (dynamic groups, policies for instance principals)
must target it. Without this, Phase 2 fails MID-APPLY after network resources already exist.

**B4. NO `OciManager`. `ReleaseUploader.AwsManager` is 100% S3 plumbing** — `get_releases/3`,
`upload/4`, `tag_object/4` map exactly onto `Cloud.ObjectStore`'s `list_objects/2`,
`upload_file/4`, `put_object_tags/4`, with zero release-specific logic worth duplicating per
provider. A per-provider manager would be a SECOND abstraction over the same operations. Correct
shape: `AwsManager` delegates to `Cloud.ObjectStore`; OCI supplies `OciObjectStore` behind the same
behaviour.

**B5. Pagination is part of the ObjectStore contract, not an implementation detail.** MEASURED bug
in the first `S3ObjectStore` (commit 3330904): `list_objects` issued ONE request and returned 1000
keys where `AwsManager.get_releases` returned 7138 against `cfx-deploys-prod`. Absorbing AwsManager
as §3.2 directs would have made release discovery see one release in seven, silently — breaking
change detection and rollback with no error. Any provider implementation MUST follow pagination to
completion; the OCI CLI's `--all` flag is its equivalent.

**B6. Tenancy facts** (opgg): namespace `axm8ic8kr5of`; both `ap-seoul-1` and `ap-chuncheon-1` have
exactly ONE availability domain, so §3.5's `availability_domain: nil` (= first) is adequate and no
multi-AD spread is possible; an existing `opgg-terraform` bucket lives in `ap-seoul-1` (do not
clobber — relevant to §5.5 backend config); compartment `opgg-backend` created for this work.

