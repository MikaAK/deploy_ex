---
description: Review code changes for bugs, security issues, and improvements
---

You are a Principal Elixir Architect performing a thorough code review on the DeployEx library. Before reviewing any code, you MUST read the following reference material to understand all project conventions:

1. Read the root `AGENTS.md` file
2. Read all files in `.windsurf/rules/` directory

After reading those files, apply ALL of the conventions below when reviewing. The rest of this document contains the full context from every rules file and AGENTS.md so you have it inline, but you should still read the source files to catch any updates made after this workflow was written.

---

# STEP 1: Gather Context

Run `gh pr view --json baseRefName,headRefName,title,body` to understand the PR context. Then run `gh pr diff` to see the actual changes. If the diff is large, focus on the most critical files first.

# STEP 2: Review Focus Areas

Find all potential bugs and code improvements. Focus on:

1. Logic errors and incorrect behavior
2. Edge cases that aren't handled
3. Nil reference issues (use `is_nil/1` guard, never `=== nil`)
4. Race conditions or concurrency issues
5. Security vulnerabilities (hardcoded secrets, unsafe shell commands, template injection)
6. Improper resource management or resource leaks
7. API contract violations (`{:ok, _}` / `{:error, ErrorMessage}` return types)
8. AWS resource tagging and naming issues
9. Terraform/Ansible template compatibility issues
10. **Violations of existing code patterns or conventions** (see full reference below)

# STEP 3: Review Guidelines

1. If exploring the codebase, call multiple tools in parallel for increased efficiency. Do not spend too much time exploring.
2. If you find any pre-existing bugs in the code, report those too since it's important to maintain general code quality.
3. Do NOT report issues that are speculative or low-confidence. All conclusions must be based on a complete understanding of the codebase.
4. Remember that if you were given a specific git commit, it may not be checked out and local code states may be different.
5. When reporting issues, reference the specific rule or convention being violated.

---

# FULL PROJECT CONVENTIONS REFERENCE

Everything below is the complete set of rules and conventions for this project. Use this as your checklist when reviewing code.

---

## 1. Project Overview

DeployEx is an Elixir library that generates and manages AWS infrastructure with Terraform and Ansible, plus Mix tasks for deployment workflows.

### Key Locations
- `lib/deploy_ex`: core AWS and release logic
- `lib/mix/tasks`: Mix CLI tasks
- `priv/ansible` and `priv/terraform`: templates and modules
- `test`: ExUnit tests and fixtures

---

## 2. Elixir Code Conventions (always enforced)

### Error Handling
- Return `{:ok, _}` / `{:error, %ErrorMessage{}}` from public functions
- Use `ErrorMessage` from the `error_message` hex package; do **not** alias it under `DeployEx.ErrorMessage`
- Avoid raising exceptions in library code

### Error Chaining with `with`
```elixir
def process(params) do
  with {:ok, validated} <- validate(params),
       {:ok, result} <- execute(validated) do
    {:ok, result}
  end
end
```
The `with` block automatically propagates `{:error, _}` tuples — do not add redundant `else` clauses unless transforming errors.

### Strict Equality
- Use `===` instead of `==`
- Use `!==` instead of `!=`

### Nil Checks
- Use `is_nil(value)` instead of `value === nil`
- Use `not is_nil(value)` instead of `value !== nil`
- Prefer `if is_nil(value) do ... else ... end` over `case value do nil -> ... _ -> ... end`

### Empty Collections
- Use `Enum.empty?(list)` instead of `length(list) === 0` or `list === []`

### Pipe Operator
- Only use `|>` when there are at least 2 operations in the chain
- Always start pipe chains with a raw value: `a |> b() |> c()` not `b(a) |> c()`

### Function Naming
- Predicate functions use `?` suffix: `valid?/1`, `active?/1`
- Reserve `is_` prefix for guard clauses only
- Do not use 1-2 letter acronym variable names

### Assertions in Tests
- Use `refute` instead of `assert !` or `assert not`
- Use `is_nil/1` guard in assertions

### Atoms vs Strings
- Never mix atoms and strings for the same key access
- If data comes as strings, keep it as strings; fix upstream if needed

### Module Aliases
- Do not alias modules that would conflict with dependency modules
- Do not alias modules that are already short

### Comments
- Do not write comments unless the code is genuinely unusual
- Do not add explanatory comments for straightforward operations

### Style
- Imports must be at the top of the file
- Start pipe chains with a raw value

---

## 3. Configuration (always enforced)

- Use `DeployEx.Config` for all configuration and environment values
- **Never** call `Mix.env()` at runtime; it is only available at compile time
- **Never** use `Application.put_env` in tests

---

## 4. GenServer Patterns

### Initialization
**Always** use `handle_continue/2` for initialization work instead of blocking in `init/1`:
```elixir
def init(opts) do
  {:ok, %{opts: opts}, {:continue, :initialize}}
end

def handle_continue(:initialize, state) do
  {:noreply, do_initialization(state)}
end
```

### Side Effects
- Keep side effects out of init callbacks

---

## 5. Shell Commands and Utilities

- Run shell commands through `DeployEx.Utils` for consistent output, logging, and error handling
- **Never** shell out directly from Mix tasks or library modules
- **Never** use shell pipes (`|`), redirects (`2>&1`), or output manipulation (`tail`, `head`, `grep`)
- Always run commands cleanly and directly

---

## 6. AWS Rules

### ExAws Requests
- Always pass `:region` to ExAws operation calls
- Tag all AWS resources with `Group`, `Environment`, and `ManagedBy`

### Naming
- Use `DeployEx.Config.aws_names_include_env?()` when building resource name prefixes that may or may not include the environment (e.g., security groups, buckets)

### Terraform
- Keep Terraform resource tags consistent with `resource_group`, `environment`, and `ManagedBy`
- Update `variables.tf` and `outputs.tf` when module interfaces change
- Ensure EEx templates in `priv/terraform/` stay compatible with `DeployEx.Terraform` module usage

### Ansible
- Keep Ansible tasks idempotent and safe to re-run
- Use variables from `group_vars` and role defaults; avoid hardcoding values
- AWS CLI calls in playbooks must include region and required tags

---

## 7. Mix Task Rules

### Argument Parsing
- Parse arguments with `OptionParser` and keep flags aligned with README documentation
- Update the README when adding or changing CLI flags, config, or user-facing behavior

### Shared Helpers
- Use `DeployExHelpers` for common IO and task utilities
- Use `DeployEx.Config` for defaults instead of `Mix.env()` at runtime
- Use `DeployEx.Utils` for shell command execution

### Structure
- Keep long-running work in helper functions, not in the task's `run/1` body directly
- Ensure tasks check umbrella requirements and provide clear `Mix.shell()` output
- Follow the existing naming convention: `Mix.Tasks.DeployEx.<Domain>.<Action>`

### Migrations and Schemas
- Write migrations when creating new Ecto schemas
- Add proper indexes to schemas

---

## 8. Template and Priv Asset Rules

### EEx Templates
- Keep EEx templates compatible with Mix task generators that render them
- Templates use `DeployEx.Config` for runtime values like region, bucket names, and environment
- Never hardcode secrets in templates; use placeholder values or machine-preloaded credentials

### GitHub Actions
- CLI scripts in `priv/` are consumed by generated GitHub Action workflows
- Update scripts and workflow templates together when changing CI behavior

### Ansible Templates
- Ansible playbook and role templates must stay in sync with Mix task generation
- Variable names in `group_vars` templates must match expectations in role `defaults/` and `vars/`

### Terraform Templates
- Terraform EEx templates (`.tf.eex`) are rendered by `DeployEx.Terraform` and Mix tasks
- Keep variable and output definitions consistent between modules and parent templates

---

## 9. Testing Rules

### General
- Treat compiler warnings as errors; test output must be clean
- Use `refute` instead of `assert` when asserting something is not true

### Data Setup
- Use `FactoryEx` for database insertions and building test schemas
- Avoid mocking libraries; prefer real modules and fixture files
- Never use `Application.put_env` in tests

### Fixtures
- Keep fixture files (e.g., mix deps tree output, lock file diffs) up to date when parser logic changes
- Add new fixtures when introducing new parsing rules

### Conventions
- Keep tests aligned with `{:ok, _}` / `{:error, ErrorMessage}` return conventions
- When a test fails, determine whether the code or the test is correct before choosing what to fix
- Always run tests after writing them

---

# REVIEW CHECKLIST

When reviewing each changed file, verify against this checklist:

### For ALL Elixir files:
- [ ] Uses `===`/`!==` instead of `==`/`!=`
- [ ] Uses `is_nil/1` instead of `=== nil`
- [ ] Uses `Enum.empty?/1` instead of `length(list) === 0`
- [ ] Pipe chains start with raw values and have 2+ operations
- [ ] Predicate functions use `?` suffix, `is_` only in guards
- [ ] No 1-2 letter acronym variable names
- [ ] No unnecessary comments
- [ ] No mixing of atom and string keys
- [ ] Public functions return `{:ok, _}` / `{:error, ErrorMessage}`
- [ ] No raised exceptions in library code

### For configuration-related files:
- [ ] Uses `DeployEx.Config` for all config and environment values
- [ ] No `Mix.env()` at runtime
- [ ] No `Application.put_env` in tests

### For shell/command execution:
- [ ] All shell commands go through `DeployEx.Utils`
- [ ] No direct shell-outs from Mix tasks or library modules
- [ ] No shell pipes, redirects, or output manipulation

### For AWS-related files:
- [ ] ExAws calls include `:region`
- [ ] Resources tagged with `Group`, `Environment`, `ManagedBy`
- [ ] Uses `DeployEx.Config.aws_names_include_env?()` for name prefixes

### For Terraform/Ansible templates:
- [ ] EEx templates compatible with rendering modules
- [ ] No hardcoded secrets
- [ ] Variables consistent between templates and modules
- [ ] Ansible tasks are idempotent

### For Mix task files:
- [ ] Uses `OptionParser` for argument parsing
- [ ] README updated for new/changed CLI flags
- [ ] Uses `DeployExHelpers` for common utilities
- [ ] Uses `DeployEx.Utils` for shell commands
- [ ] Follows `Mix.Tasks.DeployEx.<Domain>.<Action>` naming
- [ ] Long-running work in helper functions, not in `run/1`

### For GenServer files:
- [ ] Uses `handle_continue` instead of blocking in `init/1`
- [ ] No side effects in init callbacks

### For test files:
- [ ] Uses `FactoryEx` for test data
- [ ] Uses `refute` instead of `assert !`
- [ ] No mocking libraries; uses real modules and fixtures
- [ ] No `Application.put_env`
- [ ] Fixtures up to date with parser logic
- [ ] Tests aligned with `{:ok, _}` / `{:error, ErrorMessage}` conventions
