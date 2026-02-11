---
description: Elixir coding conventions for the DeployEx codebase
---

# Elixir Coding Rules

## Error handling
- Return `{:ok, _}` / `{:error, %ErrorMessage{}}` from public functions.
- Use `ErrorMessage` from the `error_message` hex package; do not alias it under `DeployEx.ErrorMessage`.
- Avoid raising exceptions in library code.

## Comparisons and guards
- Use `===` and `!==` instead of `==` and `!=`.
- Use `is_nil(value)` instead of `value == nil` or `value != nil`.
- Use `Enum.empty?(list)` instead of `length(list) === 0` or `list === []`.
- Do not prefix non-guard functions with `is_`; use a `?` suffix instead.

## Style
- Do not use one or two letter acronym variable names.
- Do not alias modules that are short or would conflict with dependency modules.
- Start pipe chains with a raw value: prefer `a |> b() |> c()` over `b(a) |> c()`.
- Imports must be at the top of the file.
- Do not add comments unless they explain something non-obvious.
- Prefer `if is_nil(value) do ... else ... end` over `case value do nil -> ... end` for nil checks.

## Configuration
- Use `DeployEx.Config` for all configuration and environment values.
- Never call `Mix.env()` at runtime; it is only available at compile time.
- Never use `Application.put_env` in tests.

## GenServers
- Use `handle_continue` instead of blocking calls in `init/1`.
- Keep side effects out of init callbacks.

## Phoenix LiveView
- Elements with hooks must have an `id` attribute.
