---
description: Testing conventions for the DeployEx codebase
---

# Testing Rules

## General
- Run tests from the application directory, never from the umbrella root.
- Treat compiler warnings as errors; test output must be clean.
- Use `refute` instead of `assert` when asserting something is not true.

## Data setup
- Use `FactoryEx` for database insertions and building test schemas.
- Avoid mocking libraries; prefer real modules and fixture files.
- Never use `Application.put_env` in tests.

## Fixtures
- Keep fixture files (e.g., mix deps tree output, lock file diffs) up to date when parser logic changes.
- Add new fixtures when introducing new parsing rules.

## Conventions
- Keep tests aligned with `{:ok, _}` / `{:error, ErrorMessage}` return conventions.
- When a test fails, determine whether the code or the test is correct before choosing what to fix.
- Always run tests after writing them.
