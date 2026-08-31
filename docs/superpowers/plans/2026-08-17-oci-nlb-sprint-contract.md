# Sprint Contract — OCI Network Load Balancer (deploy_ex, `feat/oci-multi-cloud`)

**Author:** lb-architect · **Tree:** `/Users/mika/GitHub/deploy_ex` @ `27fe4ac` (`feat/oci-multi-cloud`) · **Date:** 2026-08-17

---

## 0. Process notes before anything else

**PCP gap (BLOCKING-lite).** My spawn prompt carried no Project Context Payload — no project type, no test command, no library catalog, no project-scoped skill list. I derived the equivalent myself this run and every fact below is labelled. **Recommend re-running discovery** so downstream workers get a real PCP instead of inheriting mine. The PCP-equivalent I measured:

| PCP field | Measured value |
|---|---|
| Project type | Elixir **single app** (not umbrella) — `mix.exs` at root, no `apps_path` |
| Test command | `mix test` from repo root (**not** `cd apps/… && mix test` — that rule does not apply here) |
| Baseline | **MEASURED** `720 tests, 0 failures`, 3.6s, at `27fe4ac` |
| Quality gates | `mix test`, `mix credo --strict`, `mix compile --warnings-as-errors`, `bash bin/render_harness.sh` |
| Project-scoped skills | `.claude/skills/deploy-ex-dev`, `deploy-ex-infra`, `deploy-ex-ops` (loaded `deploy-ex-dev`) |
| Library catalog | `ErrorMessage`, `DeployEx.Utils` (never `System.cmd`), `DeployEx.Config` (never `Application.get_env`), `EEx` + `DeployExHelpers.write_template/4`, `DeployEx.Cloud.PrivFileSet` |
| Bulk of this change | **Terraform HCL, not Elixir.** Only one `.ex` file is touched (Sprint 3). Ecto skills are not applicable. |

**No UI surface.** Per `harness-references/ui-gate.md`, the user-tester checklist section is **N/A** — this sprint ships no rendered UI. The equivalent human-facing gate is the live `curl`-through-the-LB step in §10.

---

## 1. Corrections to the briefing — MEASURED, read before the contract

The brief asked me to verify rather than trust. Four statements do not survive measurement. Two change the design.

### C1 — `load_balancer.port` and `load_balancer.instance_port` are **dead keys on AWS today**

The brief describes "TCP target groups pointing at instance ports" and asks for a security-list rule on "LB port + instance_port". Measured:

- `priv/terraform/modules/aws-instance/variables.tf:157` declares `elb_port` (default 80). **It is referenced nowhere in `main.tf`** — `grep -n "elb_port" priv/terraform/modules/aws-instance/main.tf` returns only the two `elb_instance_port` hits at `:291` and `:322`. Listener ports are hardcoded `80` (`main.tf:329`) and `443` (`main.tf:379`).
- `priv/terraform/ec2.tf.eex` passes **neither** `elb_port` nor `elb_instance_port` (full arg list `ec2.tf.eex:22-89`; the `load_balancer.*` lines are `:48,:49,:54-61` only). So `elb_instance_port` always falls back to its module default of `80`.

**Net: AWS is unconditionally 80→80 and 443→443. Both keys are inert.**

Consequence: OCI must be 80→80 / 443→443 too, and `port` / `instance_port` are ignored on OCI as well. The port set is therefore `{80}` ∪ `{443 when https}` — no per-project port variance, **no dedup problem at all**.

### C2 — `guides/reference/terraform_variables.md` documents a knob that does not work

`guides/reference/terraform_variables.md:278-281` shows `instance_port = 4000` in a worked example. Per C1 that value is discarded. **Pre-existing AWS documentation defect**, not introduced here. Fixing the code would change AWS rendered output and is barred by the byte-parity contract. Sprint 3 corrects the *doc*; the *code* fix is a separate backlog item.

### C3 — `priv/terraform/providers/oci/network.tf` is **not** an `.eex` template

The brief proposes adding LB ingress rules to the OCI security list. Measured: `network.tf` is a static file (no `.eex`; `PrivFileSet` copies it verbatim, `terraform.build.ex:186-189`). Security-list rules would have to read `var.<%= @app_name %>_project` to know which ports to open — requiring a rename to `network.tf.eex`. That rename is *possible* (pipeline handles it: `terraform.build.ex:219` strips `.eex`; new files are auto-discovered) but avoidable, and avoiding it produces a strictly better security posture. See D3.

### C4 — Oracle's docs confirm NSG ∪ security-list is additive

`https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securityrules.htm`, verbatim:

> "If you use *both* security lists and network security groups, the set of rules that applies to a particular VNIC is the union of these items: The security rules in the security lists associated with the VNIC's subnet; The security rules in all NSGs that the VNIC is in"

**MEASURED (docs, this run).** This is what makes D3 work without touching `network.tf`. It remains the one claim whose live confirmation is the `curl` step in §10 — if the union does not behave as documented, the D3 contingency applies.

---

## 2. Evidence ledger

| # | Claim | Class | Evidence |
|---|---|---|---|
| E1 | oracle/oci `~> 7.0` exposes `oci_network_load_balancer_{network_load_balancer,backend_set,backend,listener}` | **MEASURED** | `tofu providers schema -json` on an inited OCI render, this run |
| E2 | `is_private` defaults to **`true`** — an NLB without `is_private = false` gets **no public IP** | **MEASURED (docs)** | provider docs: *"Default is true"* |
| E3 | `health_checker` block is `min_items = 1` — cannot be omitted the way AWS's `dynamic "health_check"` is | **MEASURED** | schema dump: `BLOCK health_checker nesting=list min=1 max=1` |
| E4 | `health_checker.retries` default **3**, `interval_in_millis` default **10000**, `timeout_in_millis` default **3000**, `return_code` is a **single number** | **MEASURED (docs)** | provider docs, quoted verbatim |
| E5 | backend-set `is_preserve_source` **defaults to true** ⇒ backends see the original client IP ⇒ instance ingress must admit `0.0.0.0/0` | **MEASURED (docs)** | *"The value is true by default."* |
| E6 | The exact HCL proposed in §5 passes `tofu validate` against oracle/oci ~>7.0 | **MEASURED** | probe at `/tmp/lbarch_oci_1/**/probe_load_balancer.tf`, `tofu validate` → `Success! The configuration is valid.` (run twice: NSG-at-root and NSG-in-module variants) |
| E7 | `mix terraform.build --provider oci --render-dir <d> --quiet` runs headlessly, emits 14 files | **MEASURED** | executed this run |
| E8 | Suite baseline `720 tests, 0 failures` | **MEASURED** | `mix test` this run |
| E9 | A new `.eex`/`.tf` under `providers/oci/` is auto-discovered — `PrivFileSet` (`priv_file_set.ex:72-80`), `PrivRenderer` (`priv_renderer.ex:50-85`), `export_priv` (`:72-75,:98-101`), `upgrade_priv` (`:890-894`), `ChangePlanner` (`:74`) are all wildcard-driven. **No hardcoded template list exists in `lib/`.** | **MEASURED** | validation subagent, file:line |
| E10 | No existing test asserts an exact set/count of OCI-rendered files; there is **no terraform-side OCI render test at all** | **MEASURED** | validation subagent |
| E11 | `mix terraform.drop` = one `tofu destroy`; adds no ordering; `--target <app>` builds the **AWS-only** address `module.ec2_instance["app"]` (`terraform.ex:41-54`) | **MEASURED** | validation subagent |
| E12 | `test/deploy_ex/cloud/providers/oci_test.exs:10-15` pins `Oci.capabilities() === %{object_store: _, security: _}` **"and nothing else"** | **MEASURED** | validation subagent |
| E13 | The §3.0.6 omitted-variable deny-list is **not implemented in `lib/`**, and its OCI set is `upload_buckets`/`cdn_*`/`resource_databases` — `load_balancer` is not on it (it is a key *inside* `<app>_project`, not a top-level variable) | **MEASURED** | plan doc `:791`; subagent grep of `lib/` |
| E14 | `bin/render_harness.sh` is the existing AWS byte-parity gate (two-revision `diff -r`) | **MEASURED** | read this run |
| E15 | OCI NLB backend-set/listener `name` length limit | **ASSUMED — 32 chars, unverified** (API-reference page is JS-rendered, returned no content). **D4 is immune either way**; live apply is the verification. |

---

## 3. Design decisions

### D1 — Gate on `enable` alone, **not** AWS's `enable && (instance_count > 1 || autoscaling)`

AWS (`aws-instance/main.tf:52`) creates the LB only for multi-instance or autoscaled apps. OCI has no autoscaling and the OCI default `instance_count` is `1` (`modules/oci-instance/variables.tf:57-62`), so copying that gate makes `load_balancer.enable = true` a **silent no-op** for the common case — precisely the "looks authoritative and does nothing" failure this repo already calls out at `variables.tf.eex:163-165` and `terraform_variables.ex:55-60`.

**Decision: OCI gates on `enable` alone.** Documented as an explicit divergence in the README, pinned by a test. *(My call, not a brief decision — flag it if you disagree; cheap to reverse.)*

### D2 — All NLB resources live **inside `modules/oci-instance/`**

Confirmed, with a hard reason beyond AWS symmetry: at root you would need `for_each`/`count` over `module.oci_instance[app].instance_ids`. Those OCIDs are **unknown until apply**, and Terraform rejects `for_each` over apply-time-unknown values (`The "for_each" value depends on resource attributes that cannot be determined until apply`). Inside the module, backends use `count = local.lb_count * var.instance_count` — a **known integer** — and index `oci_core_instance.main[count.index].id`. Count-with-unknown-*values* is fine; for_each-with-unknown-*keys* is not.

**DERIVED** from Terraform semantics; the count-based form is **MEASURED** valid (E6).

### D3 — Security posture: a **per-app NSG created inside the module**, not security-list rules

Rejected the brief's security-list approach for three measured reasons:

1. It forces `network.tf` → `network.tf.eex` (C3) — a template-kind change with `PrivManifest` delete+add churn for every existing OCI user, to add two rules.
2. Security-list rules apply to the **whole subnet**, so one LB-backed app opens 80/443 on *every* instance including redis/prometheus/loki. An NSG attached only to LB-backed instances does not.
3. Cross-app rule dedup (the brief's "churn" concern) **disappears entirely** — each app owns its own NSG with its own two rules. Nothing to dedup.

The NSG serves both ends of the path: attached to the NLB (`network_security_group_ids`) *and* to the backend instances' VNICs (`nsg_ids`), required because `is_preserve_source` is true by default (E5) so backends see the raw client IP. Oracle documents NSGs on a load balancer apply *"to the Load Balancer (not the backend set)"* — hence both attachments.

Consequence: `network.tf` and `oci_core_security_list.public` are **untouched**. The runtime `deploy_ex.ssh.authorize` NSG (`network.tf:75-81`) is untouched and does not conflict.

**Contingency (state it, do not pre-build it):** if the live `curl` in §10 fails with NSG rules present and `tofu plan` clean, the fallback is security-list rules — which then requires the `network.tf` → `network.tf.eex` rename. Do **not** implement the fallback speculatively.

### D4 — Backend-set and listener names are the unqualified `"http"` / `"https"`

Both names only need uniqueness **within their own NLB**, and every app gets its own NLB. Qualifying them (`prometheus-metrics-database-https` = 33 chars) would collide with the ASSUMED 32-char limit (E15). Unqualified names are immune regardless of what the limit actually is. App identity lives in the NLB's `display_name`.

### D5 — Unset health-check knobs pass `null` and take **each provider's own default**

An unset `interval` gives 10 s on OCI and 20 s on AWS. Deliberate: transplanting AWS's arbitrary defaults into OCI creates a second set of magic numbers to keep in sync. Pinned by a test asserting the template contains **no** hardcoded `20000`/`5000`.

### D6 — Two new OCI-only keys; portability is one-way

`health_check.return_code` and `health_check.https_return_code` (numbers) are read on OCI only. AWS's `map(object({...}))` (`variables.tf.eex:107-185`) would **reject** them — so an AWS-shaped tfvars runs on OCI, but an OCI tfvars that sets them does not run on AWS. That asymmetry already exists both ways (`shape`/`ocpus` vs `instance_type`) and is established precedent at `terraform_variables.ex:55-65`. Adding them to the AWS type would change AWS rendered bytes → barred.

### D7 — Scope split of the plan's Phase-5 "LB" item

`docs/superpowers/plans/2026-08-03-multi-cloud-oci.md:1568-1590` defers "LB" to Phase 5 with eight per-item requirements. **This sprint discharges only the terraform-provisioning half.** The Elixir half — extracting a `LoadBalancer` behaviour, an `OciLoadBalancer` module, a `load_balancer` capability key, `mix deploy_ex.load_balancer.health` on OCI — stays deferred. Requirements (b) (§3.0.1 four-column rows / behaviour extraction) and (h) (behaviour-conformance tests) are **out of scope and remain open**. Requirement (f) is a **measured no-op** (E13). Requirements (a), (e), (g) are discharged in §8/§9/§10. **Confirm this split.**

---

## 4. Health-check mapping table — AWS → OCI NLB

| shared `load_balancer.*` key | What AWS does **today** (MEASURED) | OCI NLB target | Mapping |
|---|---|---|---|
| `enable` | `enable_elb`; LB only when `enable_elb && (instance_count > 1 \|\| enable_autoscaling)` — `aws-instance/main.tf:52` | `count` on every LB resource | **Diverges** per D1: OCI gates on `enable` alone |
| `enable_https` | `enable_elb_https`, default `true` — `aws-instance/variables.tf:171-176` | `count` on the 443 backend set / backend / listener | direct |
| `port` | **dead** — declared `variables.tf:157`, referenced nowhere; never passed by `ec2.tf.eex` | — | **ignored.** Listener is always 80 (and 443 when https) |
| `instance_port` | **dead** — never passed by `ec2.tf.eex`; always falls back to module default `80` | — | **ignored.** Backend port is always 80 / 443 |
| `health_check.path` | `elb_health_check_path`; empty ⇒ whole `health_check` block omitted — `main.tf:293-305` | `health_checker.url_path` | direct when non-empty; `null` otherwise |
| `health_check.protocol` | **dead** — no such module variable exists; AWS hardcodes `HTTP` on the :80 TG (`main.tf:298`) and `HTTPS` on the :443 TG (`main.tf:352`) | `health_checker.protocol` | **ignored.** OCI derives: `HTTP`/`HTTPS` when `path` set, else `TCP`. OCI cannot omit the block (E3), so a TCP connect check is the closest equivalent to AWS's "no health check" |
| `health_check.matcher` | `elb_health_check_matcher`, default `"200-299,301"` — a **range string** | `health_checker.return_code` — a **single number** (E4) | **ignored, not representable.** OCI reads optional `health_check.return_code`, default `200` |
| `health_check.https_matcher` | default `"200-299"` | same, on the 443 set | **ignored.** OCI reads optional `health_check.https_return_code`, default `200` |
| `health_check.unhealthy_threshold` | default 2 | `health_checker.retries` | **direct.** OCI's own wording: *"number of retries to attempt before a backend server is considered 'unhealthy'"* |
| `health_check.healthy_threshold` | default 2 | — | **ignored.** OCI has one value: *"This number also applies when recovering a server to the 'healthy' state."* |
| `health_check.timeout` | seconds, default 5 | `timeout_in_millis` (default 3000) | **× 1000**; `null` when unset (D5) |
| `health_check.interval` | seconds, default 20 | `interval_in_millis` (default 10000) | **× 1000**; `null` when unset (D5) |

Every "ignored" row **must be documented in the README and in `guides/reference/terraform_variables.md`** — a silently-ignored key is the exact failure mode this repo has already been bitten by.

---

## 5. File-by-file change list

```
priv/terraform/providers/oci/modules/oci-instance/
  load_balancer.tf              CREATE   NSG + 2 rules, NLB, 2 backend sets, backends, 2 listeners
  variables.tf                  MODIFY   + vcn_id and the load_balancer_* inputs
  outputs.tf                    MODIFY   + load_balancer_public_ips
  main.tf                       MODIFY   create_vnic_details.nsg_ids gains the LB NSG (splat/concat)

priv/terraform/providers/oci/
  instance.tf.eex               MODIFY   + vcn_id and the load_balancer.* arg wiring
  outputs.tf                    MODIFY   + load_balancer_public_ips keyed by app
  variables.tf.eex              MODIFY   recognized-keys list in the <app>_project description
  README.md                     MODIFY   "no load balancer" -> the real capability + every ignored key
  network.tf                                    UNTOUCHED (D3)
  terraform.tfvars.example                      UNTOUCHED (LB config lives in the project map)

lib/deploy_ex/
  terraform_variables.ex        MODIFY   commented load_balancer block in the :oci release clause ONLY

guides/reference/
  terraform_variables.md        MODIFY   provider-qualify the load_balancer section; fix the instance_port example (C2)

test/mix/tasks/
  terraform_build_oci_lb_test.exs   CREATE   all tests in §8

priv/terraform/**  (everything not under providers/)   UNTOUCHED — byte-parity contract
lib/**  (everything except terraform_variables.ex)     UNTOUCHED
```

---

## 6. Existing code to reuse — do not hand-roll these

| Thing | Where | Use it for |
|---|---|---|
| `local.snake_instance_name` / `local.kebab_instance_name` | `modules/oci-instance/main.tf:1-4` | every display name — do not re-derive |
| `freeform_tags = merge({Name, Group, InstanceGroup, Environment, ManagedBy}, var.tags)` | `modules/oci-instance/main.tf:37-43` | copy this exact merge shape onto NLB + NSG. `Group`/`Environment`/`ManagedBy` are mandatory (workspace CLAUDE.md) |
| `local.common_tags`, `local.name_prefix` | `providers/oci/providers.tf:34-49` | root-level resources only. The module does **not** see these — it builds its own merge |
| `dynamic` block emitting **nothing** when a value is absent | `providers/oci/network.tf:51-63` | the "OCI rejects `0.0.0.0/8` sentinels, express absence by omission" idiom |
| `{ for app, mod in module.oci_instance : app => mod.X }` | `providers/oci/outputs.tf:16-29` | the new root output must match this shape exactly |
| `try(each.value.<key>, var.<default>)` | `providers/oci/instance.tf.eex:24-41` | every new arg. The variable is `type = any`; `try/2` is how this repo reads it |
| `versions.tf` provider pin | `modules/oci-instance/versions.tf` | already present — do **not** add a second `required_providers` block in `load_balancer.tf` |
| `DeployEx.Cloud.PrivFileSet.files/2` | `lib/deploy_ex/cloud/priv_file_set.ex:28-40` | the gate-5 fixture test. Wildcard-driven (E9) — **no registration step exists or is needed** |
| Render-test harness style | `test/mix/tasks/ansible_build_render_test.exs` | `async: false`, `capture_io(fn -> Build.run(args) end)`, temp dirs via `System.unique_integer`, `on_exit` cleanup. Copy this shape |
| Template-content test style | `ansible_build_render_test.exs:150-159` | `DeployExHelpers.priv_folder(path) \|> File.read!()` then `assert contents =~ …` |
| `bin/render_harness.sh` | repo root | the AWS byte-parity gate — **do not write a new one** |

**Elixir conventions for the one `.ex` file** (`terraform_variables.ex`): `===`/`!==` not `==`; `is_nil/1`; no comments unless non-obvious; match the existing heredoc + `String.trim_trailing/2` shape at `:13-31`. Never run `mix format` unless the file already needs it (global rule).

---

## 7. Sprint contracts

Three sprints, **strictly sequential** — S2 consumes module inputs S1 defines; S3 documents behaviour S2 wires. **No parallelization available.**

### Sprint OCI-LB-1 — the module

**Files (4):** `modules/oci-instance/{load_balancer.tf,variables.tf,outputs.tf,main.tf}`
**Skills:** `deploy-ex-dev`, `test-harness`, `superpowers:test-driven-development`, `superpowers:verification-before-completion`
**Depends on:** nothing.

**Done criteria** — deliverables, not implementations:

1. `modules/oci-instance/load_balancer.tf` exists and declares exactly these resource types: `oci_core_network_security_group`, `oci_core_network_security_group_security_rule`, `oci_network_load_balancer_network_load_balancer`, `oci_network_load_balancer_backend_set`, `oci_network_load_balancer_backend`, `oci_network_load_balancer_listener`.
2. Every LB resource has `count` (or `for_each`) evaluating to zero when `var.enable_load_balancer` is `false`. **Invariant:** an OCI project with no LB-enabled app must produce a plan containing zero LB resources.
3. **The NLB sets `is_private = false` explicitly.** Rationale on the record: the provider default is `true` (E2), which yields an NLB with no public IP and a feature that silently does nothing. Highest-value assertion in the sprint.
4. Backend sets set `policy = "FIVE_TUPLE"` and `is_preserve_source = true`.
5. `health_checker.protocol` is `TCP` when `var.load_balancer_health_check_path == ""`, and `HTTP` (port-80 set) / `HTTPS` (port-443 set) otherwise. `url_path` and `return_code` are `null` in the TCP case.
6. `timeout_in_millis` and `interval_in_millis` are derived by multiplying the seconds-valued inputs by 1000, and are `null` when the input is `null`. **No hardcoded millisecond literal appears anywhere in the file.**
7. `retries` is `var.load_balancer_health_check_retries` passed straight through (`null` ⇒ provider default 3).
8. Backend-set and listener `name`s are the literals `"http"` and `"https"` (D4).
9. The module creates one NSG (`count = local.lb_count`) with `INGRESS`/`protocol = "6"`/`source = "0.0.0.0/0"` rules on port 80, plus 443 when https is enabled. The NSG OCID is set on **both** the NLB's `network_security_group_ids` **and** — via `main.tf` — the instances' `create_vnic_details.nsg_ids`.
10. **Invariant:** `main.tf`'s `nsg_ids` expression must never index the LB NSG as `[0]`. Use splat + `concat` so the count-0 case yields `[]` rather than an index error. *Reason: a bare `[0]` on a count-0 resource is the classic Terraform footgun and `tofu validate` does not catch it — only a plan with LB disabled does.* Gate G5b pins it.
11. New module inputs, all with defaults so existing callers keep working unchanged: `vcn_id`, `enable_load_balancer`, `enable_load_balancer_https`, `load_balancer_health_check_path`, `load_balancer_health_check_return_code`, `load_balancer_health_check_https_return_code`, `load_balancer_health_check_retries`, `load_balancer_health_check_timeout_seconds`, `load_balancer_health_check_interval_seconds`. Every one carries a `description` in the style of the existing block.
12. Module output `load_balancer_public_ips` returns a **list** — `[]` when disabled, `["<ip>"]` when enabled — filtered on `is_public`. List-shaped, mirroring AWS's `load_balancer_dns_name` at `aws-instance/outputs.tf:22-25`.
13. Tests T1–T10 (§8) green; each with its mutation proof.

**Reference shape — MEASURED to pass `tofu validate` (E6).** A *validated existence proof*, **not a prescription**. Resource/attribute names and the `count`/`null` semantics are binding; arrangement, locals naming and file organisation are yours.

```hcl
resource "oci_network_load_balancer_backend_set" "http" {
  count                    = local.lb_count
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.main[0].id
  name                     = "http"
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol           = local.lb_has_path ? "HTTP" : "TCP"
    port               = 80
    url_path           = local.lb_has_path ? var.load_balancer_health_check_path : null
    return_code        = local.lb_has_path ? coalesce(var.load_balancer_health_check_return_code, 200) : null
    retries            = var.load_balancer_health_check_retries
    timeout_in_millis  = local.lb_timeout_in_millis
    interval_in_millis = local.lb_interval_in_millis
  }
}
```

### Sprint OCI-LB-2 — root wiring

**Files (3):** `providers/oci/{instance.tf.eex,outputs.tf,variables.tf.eex}`
**Depends on:** S1 (consumes every module input S1 defines).

**Done criteria:**

1. `instance.tf.eex` passes `vcn_id = oci_core_vcn.main.id` and every `load_balancer_*` input, sourced via `try(each.value.load_balancer.<key>, <default>)` in the file's existing style.
2. `instance.tf.eex` passes **neither** `port` nor `instance_port` — pinning C1 / the §4 table. Test T14 asserts the absence.
3. `providers/oci/outputs.tf` gains `load_balancer_public_ips`, matching the existing `{ for app, mod in module.oci_instance : app => mod.<x> }` shape, with a `description`.
4. The `<%= @app_name %>_project` variable **description** in `variables.tf.eex` adds `load_balancer` to its "Recognized keys:" list. *(Type stays `any` — nothing to add; see `variables.tf.eex:156-165` for why.)*
5. A render with `--provider oci` and **no** LB-enabled app is byte-identical to today's render **except** the wiring lines in `instance.tf`, the new output block, and the description string. Nothing else moves.
6. Tests T11–T17 green with mutation proofs.
7. **Gate G5** (`tofu validate`, both LB-on and LB-off) passes with pasted output.

### Sprint OCI-LB-3 — discoverability, docs, live gate

**Files (3):** `lib/deploy_ex/terraform_variables.ex`, `providers/oci/README.md`, `guides/reference/terraform_variables.md`
**Depends on:** S2.

**Done criteria:**

1. `generate_terraform_release_variables(name, :oci)` emits a **commented-out** `load_balancer` example block alongside the existing sizing comment (`terraform_variables.ex:22-28`), so users discover the knob. Commented ⇒ zero behaviour change.
2. **`generate_terraform_release_variables(name, :aws)` output is byte-identical to today.** Test T18 pins the exact current string. *Elixir-layer half of the byte-parity contract; the comment at `:56-60` says the AWS clauses "are byte-for-byte what they always were" — keep it true.*
3. `providers/oci/README.md:18` no longer says "no load balancer". It describes: the NLB shape; **every ignored key from §4 with its reason**; the D1 gate divergence; the D6 one-way portability note; the D3 NSG posture and its "80/443 reachable directly on LB-backed nodes" consequence.
4. `guides/reference/terraform_variables.md` provider-qualifies the `load_balancer` section and **removes the `instance_port = 4000` example** (C2), replacing it with a note that ports are fixed at 80/443 on both providers.
5. **Gate G4** (AWS byte parity via `bin/render_harness.sh`) passes with pasted `diff -r` output showing empty.
6. **Gate G7** (live) executed with evidence pasted, or explicitly deferred with sign-off recorded.

---

## 8. Test list — every entry carries a mutation check

New file `test/mix/tasks/terraform_build_oci_lb_test.exs`, `use ExUnit.Case, async: false` (drives a real Mix task + filesystem, matching `ansible_build_render_test.exs:2-3`).

**Mutation protocol (mandatory):** copy the target file to `/tmp` **first**; mutate with a `python3` one-liner that `assert OLD in s` before writing (a silent no-op mutation reads as "the test doesn't catch it" and manufactures a false finding); run the test; confirm **FAIL**; restore from the absolute `/tmp` path; `git diff` must be empty — verify, don't assume.

| ID | Test | Mutation → must FAIL |
|---|---|---|
| T1 | `load_balancer.tf` declares all six resource types | delete the `oci_network_load_balancer_listener` block |
| **T2** | NLB sets `is_private = false` | `false` → `true` |
| T3 | backend sets carry `policy = "FIVE_TUPLE"` and `is_preserve_source = true` | `is_preserve_source` → `false` |
| T4 | seconds→millis: file contains `* 1000` for both timeout and interval, and **no** literal `20000`/`5000`/`10000` | `* 1000` → `* 1` |
| T5 | both backend sets' `protocol` reference the path-presence local; the local is defined as `!= ""` | `!= ""` → `== ""` |
| T6 | backend-set + listener names are `"http"` / `"https"`; no `kebab_instance_name`-qualified backend-set name | qualify one name |
| T7 | NSG rule set covers 80 and 443 with `source = "0.0.0.0/0"`, `protocol = "6"`, `direction = "INGRESS"`; NSG `count` keys off the LB-enabled local | drop `443` from the port list |
| T8 | `main.tf`'s `nsg_ids` uses `concat(var.nsg_ids, …load_balancer[*].id)` — splat, not `[0]` | `[*]` → `[0]` |
| T9 | module output `load_balancer_public_ips` filters `if ip.is_public` | delete the `if` clause |
| T10 | AWS untouched: `variables.tf.eex`'s `load_balancer = optional(object({…}))` block (`:121-139`) matches its current text byte-for-byte; `aws-instance/main.tf` contains no `oci_` | add `return_code = optional(number)` to the AWS block |
| T11 | an OCI render contains `modules/oci-instance/load_balancer.tf`; an AWS render contains no `providers/` dir and no `load_balancer.tf` | — (existence) |
| T12 | **gate-5 fixture row:** `{"providers/oci/modules/oci-instance/load_balancer.tf", "modules/oci-instance/load_balancer.tf"} in PrivFileSet.files(:oci, priv)`; the `:aws` set contains nothing under `providers/` | — |
| T13 | rendered OCI `instance.tf` passes `vcn_id` and each of the seven `load_balancer_*` inputs | delete the `enable_https` wiring line |
| T14 | rendered OCI `instance.tf` contains **neither** `load_balancer.port` **nor** `load_balancer.instance_port` | add an `instance_port` wiring line |
| T15 | rendered OCI `outputs.tf` exposes `load_balancer_public_ips` keyed by app in the `for app, mod in module.oci_instance` shape | — |
| T16 | the OCI `<app>_project` description lists `load_balancer` among recognized keys | remove it |
| T17 | two OCI renders into different dirs are byte-identical across the whole tree (extends `ansible_build_render_test.exs:79-90` to the OCI terraform set) | — |
| T18 | `generate_terraform_release_variables("x", :oci)` contains the commented `load_balancer` block; `(…, :aws)` equals the pinned current string exactly | change one character in the `:aws` clause |
| T19 | *(existing, must stay green)* `oci_test.exs:10-15` — `Oci.capabilities()` still has exactly `object_store` + `security` | — (regression guard for D7's scope split) |

**Assertion discipline:** assert on **specific values**, not structure. `assert contents =~ "is_private = false"` — never `assert contents =~ "is_private"`. Where a count matters, assert `length(x) === N`.

**Vacuity check before submitting:** for each test, trace the asserted value to its producer and ask *what input could change it?* If the answer is "nothing the test controls", it's decoration — rewrite it.

---

## 9. Gates — MEASURED evidence required, output pasted

| ID | Command | Expected |
|---|---|---|
| G1 | `mix test` | `720 + N tests, 0 failures`. **Do not pipe to `tail`/`grep`** — a pipe eats the exit code; read the summary line and the failure count |
| G2 | `mix credo --strict` | clean |
| G3 | `mix compile --warnings-as-errors` | clean |
| **G4** | AWS byte parity — the two-revision recipe at `bin/render_harness.sh:9-14`:<br>`git worktree add /tmp/lbbase 27fe4ac --detach && (cd /tmp/lbbase && bash bin/render_harness.sh /tmp/base)`<br>`bash bin/render_harness.sh /tmp/head`<br>`diff -r /tmp/base/terraform /tmp/head/terraform` | **empty output.** Any diff is a contract violation — stop and report |
| G5a | `mix terraform.build --provider oci --render-dir /tmp/oci_on` with an LB-enabled app in the project map → `tofu init -backend=false && tofu validate` | `Success! The configuration is valid.` |
| **G5b** | same, with **every** app's `load_balancer.enable` absent | `Success!` — this is the run that catches a `[0]` index on a count-0 resource (S1 criterion 10) |
| G6 | live only: `tofu plan` twice against unchanged config | second plan reports **no changes** (proves deterministic NSG-rule ordering; a set that reorders shows as churn) |
| G7 | live verification — §10 | all steps pass |

---

## 10. Live verification checklist

Run against the real tenancy, on **one** app, then tear down completely. The `terraform.drop` traps below are MEASURED (E11) — read them before starting.

1. In the OCI project map, set on exactly one app:
   `load_balancer = { enable = true, enable_https = false, health_check = { path = "/" } }` and `instance_count = 1`.
2. `mix terraform.apply`. **Expect ~6 new resources for that app**: 1 NSG, 1 NSG rule, 1 NLB, 1 backend set, 1 backend, 1 listener. Enumerate them from the plan before approving.
3. `mix terraform.output` (or `tofu output load_balancer_public_ips`) → confirm a **non-empty public IP** for that app. **An empty list here means `is_private` regressed to `true`** — the single most likely failure.
4. Wait for the backend to report healthy (NLB health-check console or `oci nlb backend-health get`). With defaults that is ≤ ~30 s (3 retries × 10 s).
5. `curl -v http://<lb_public_ip>/` → the app answers. **This is the step that confirms C4's NSG ∪ security-list union claim in reality.** If it hangs, check in this order: (a) backend health, (b) the NSG is attached to *both* the NLB and the instance VNIC, (c) the D3 contingency.
6. `tofu plan` again → **no changes** (G6).
7. Teardown: **`mix terraform.drop` with no `--target`.** `--target <app>` builds the AWS-only address `module.ec2_instance["<app>"]` (`terraform.ex:41-54`) and will not resolve on an OCI tree.
8. **Ordering:** no `depends_on` is needed — the NLB depends on `var.subnet_id` ← `oci_core_subnet.public.id`, so Terraform destroys NLB → subnet → VCN in the right order automatically. The trap is only live if someone hardcodes a subnet OCID. If the subnet delete fails with a `409 Conflict`, the NLB is still deleting (can take minutes) — **re-run `mix terraform.drop`**, do not force-delete out of band.
9. Audit empty: `oci network nlb list --compartment-id <c>` → `[]`; `oci network nsg list --compartment-id <c>` → `[]`; compartment shows zero resources.
10. Record every command and its output in the sprint's evidence block.

---

## 11. Non-goals — explicit

- **No autoscaling wiring.** OCI has no ASG equivalent in this repo; AWS's `target_group_arns` plumbing has no counterpart.
- **No L7 features.** `oci_load_balancer_*` (flexible LB) is not used — cookies, path routing, SSL policies, WAF all out.
- **No cert management at the LB.** TLS terminates on the node via certbot, unchanged. The 443 listener is TCP pass-through.
- **No changes to any AWS template.** Enforced by G4.
- **No changes to any Mix task's Elixir code.** `terraform_variables.ex` is the sole `.ex` file and only its `:oci` clause changes.
- **No `load_balancer` provider capability, no `OciLoadBalancer` module, no behaviour extraction.** `mix deploy_ex.load_balancer.health` stays AWS-only. T19 guards this (E12). Per D7 this is the deferred half of the plan's P5 item.
- **No `network.tf` change**, no security-list rules, no `network.tf.eex` rename — unless the D3 contingency fires.
- **No `.deploy_ex_manifest.exs` / `PrivManifest` work.** New files are auto-discovered (E9); nothing to register.
- **No §3.0.6 deny-list edit.** Measured no-op (E13).
- **No fix for the AWS `port`/`instance_port` dead keys.** Fixing them changes AWS rendered bytes → barred. Filed as backlog via C1/C2.

---

## 12. Open items — answer before any sprint begins

1. **Confirm D1** — OCI gates the LB on `enable` alone, diverging from AWS's `instance_count > 1 || autoscaling`. Cheap to reverse; expensive to discover after a live apply produces nothing.
2. **Confirm D3** — per-app NSG inside the module instead of the brief's security-list rules. Rationale in §3; the measured blocker (C3) is that `network.tf` is not a template.
3. **Confirm D7's scope split** — this ships the terraform half of the plan's P5 "LB" item only; the behaviour/capability half stays deferred. Plan requirements (b) and (h) remain open against that half.
4. **Acknowledge C1/C2** — `load_balancer.port` / `instance_port` are dead on AWS and documented as working. Separate ticket, or accept the doc-only fix in S3?
5. **E15 is ASSUMED** — the OCI NLB name-length limit is unverified (JS-rendered API reference). D4 makes the design immune either way, but MEASURED costs one live apply.

---

# AMENDMENTS — 2026-08-20 adversarial spec review (binding; supersede conflicting text above)

Base for all sprints: `feat/oci-multi-cloud` @ **30f6cd7** in worktree `/Users/mika/GitHub/.worktrees/deploy-ex-nlb`. Baseline MEASURED: **733 tests, 0 failures**; `mix compile --warnings-as-errors` clean.

## Gates (replace §9 rows)
- G1: `mix test` → **733 + N, 0 failures**. Never pipe to tail/grep.
- ~~G2 credo~~ **DELETED** — no credo dep in this repo (MEASURED). Gates are tests + clean compile + render harness.
- G4: base = **30f6cd7** (respecify as merge-base with the working branch, not a frozen SHA); the gate diff is **terraform-scoped**: `diff -r base/terraform head/terraform` must be empty. (Whole-tree diff shows unrelated ansible drift — not this contract's concern.)
- G5: **one** validate gate (LB-off render). G5a's "LB-enabled app in the map" has no render mechanism — the rendered default map can't contain one. Additional G5-LB: after render, `sed` a `load_balancer = { enable = true, enable_https = true, health_check = { path = "/healthz" } }` entry into the rendered `variables.tf` project-map default, then `tofu validate` again. The bare-`[0]` guard is NOT validate's job (MEASURED: validate passes a `[0]` on count-0) — it is T8 + T9-extended.
- G7 live verify: replaced by the **prod-adoption sequence** (see Ship amendments).

## Sprint 1 amendments
- Criterion 10 stays (splat/concat, never `[0]`) and gains: module `outputs.tf` must not index `network_load_balancer.main[0]` either — splat/`one()`/ternary only (T9-extended pins it).
- Criterion 11: the five null-defaulted health knobs **OMIT `nullable = false`** (existing-style `nullable = false` errors with `default = null`); bool/string inputs keep house style.
- NEW criterion 14: optional `reserved_ip_ocid` module input (default `null`) wired as a `dynamic "reserved_ips" { ... id = ... }` block on the NLB — the public IP is otherwise EPHEMERAL and cannot be swapped to reserved without NLB replacement; DNS will target this IP. T-row R1 pins it.
- The `lb_has_path`-style local: the contract now DECLARES the binding names to make T5 assertable: `local.lb_count`, `local.lb_has_path`, `local.lb_timeout_in_millis`, `local.lb_interval_in_millis`. Naming is no longer free.

## Sprint 2 amendments
- T13: enumerate **all 8** `load_balancer_*` wiring lines by name (enable, enable_https, health_check_path, health_check_return_code, health_check_https_return_code, health_check_retries, health_check_timeout_seconds, health_check_interval_seconds) + `vcn_id` + `reserved_ip_ocid` (9 LB inputs total with R1), each asserted as the full `try(each.value.load_balancer.<key>, <default>)` expression.
- Render-set assertions are **membership**, never absolute count (render now has 15 files incl. database.tf AND README.md; providers.tf is a render product of providers.tf.eex).

## Test-plan amendments (§8)
- Canonical assertion form: whitespace-tolerant regex — `assert contents =~ ~r/is_private\s*=\s*false/` — never single-space literals.
- T4 → anchored: `~r/timeout_in_millis\s*=.*\*\s*1000/` AND `~r/interval_in_millis\s*=.*\*\s*1000/` AND `refute contents =~ ~r/_in_millis\s*=\s*\d/`. Extra mutation: timeout line only → `* 100` must FAIL.
- T5 → asserts via the now-declared local names (see S1 amendment).
- T7 → additionally assert the 443 NSG rule AND https listener/backend-set are **conditional on the https flag** (count/for_each references it); mutation: make 443 unconditional → must FAIL. (First prod ship is enable_https=false.)
- T9 → extended per S1 crit 10 amendment: `refute ~r/network_load_balancer\.main\[0\]/` in outputs.tf.
- T17 → both renders MUST pin `--pem-app-name` (mirror terraform_build_render_test.exs:57-62) or the random pem suffix makes it deterministically red.
- NEW T20: listener ports are literals 80 (and 443 in https set) with `protocol = "TCP"`; mutation 80→8080 FAILS.
- NEW T21: backend `port` 80/443 matching its set; backend count expression contains `* var.instance_count`; mutation: drop the factor → FAILS.
- NEW R1: `reserved_ip_ocid` wired as dynamic reserved_ips block, `null` default → block absent; mutation: delete the dynamic block → FAILS.
- T19 cite is accurate (oci_test.exs:10-15, MEASURED).

## Citation refresh (informational)
providers.tf.eex:56-67 (common_tags/name_prefix); network.tf ssh dynamic :61-73, ssh NSG :85-91; variables.tf.eex `<app>_project` :172, Recognized-keys :173; terraform.build.ex static sync :195-211 (EVERY build since 13aec24), .eex strip :260; §4 https hardcode aws-instance/main.tf:350; E10 amended: oci_backend_template_test.exs exists (template-content style) — no full-render file-set test; E13: resource_databases now implemented, conclusion unchanged; E6's /tmp probe is gone — re-prove via G5.

## Ship amendments (order is binding)
1. Sprints land as commits on `feat/oci-multi-cloud`, pushed → **deploy_ex PR #21 updated (NOT merged to deploy_ex main this cycle — user directed work to the open PR).**
2. opgg adoption (its own PR → squash-merge to opgg main, per user's merge instruction):
   a. FIRST commit opgg's existing uncommitted deploys drift (public_http_ingress_ports + app_env/INGEST_PORT changes) to opgg main.
   b. Bump opgg's deploy_ex dep: keep `branch: "feat/oci-multi-cloud"`, lock to the new branch SHA (matches today's pattern; re-bump to a main SHA when PR #21 eventually merges).
   c. Rebuild with **`mix terraform.build --provider oci --clickhouse --rabbitmq`** (bare rebuild would plan DESTRUCTION of live rabbitmq/clickhouse nodes) and WITHOUT `--force` (a --force wipes the drift and closes public :80 pre-cutover = outage). Re-apply the project-map LB enables after any regen; both network.tf hunks accepted/declined together.
   d. Enable `load_balancer = { enable = true, enable_https = false, health_check = { path = "/healthz" } }` for server + ingestion in the project map; `tofu validate` + `plan` output pasted into the PR (CI runs no tofu — local output is the gate).
   e. Live: **prod-adoption sequence** (user-run): apply NLB with :80 still open → wait backend health → cut DNS/clients to LB IP → `public_http_ingress_ports = []` + apply → **re-curl through the LB (only this curl proves the NSG path)**. A curl while [80] is open proves nothing.
3. S3 README must document: never `--force` an adopted tree; rebuild flags are part of tree identity; the enable-bit lives in the regenerated default map (declared drift).
