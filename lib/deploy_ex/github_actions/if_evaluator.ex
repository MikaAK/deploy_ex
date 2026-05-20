defmodule DeployEx.GitHubActions.IfEvaluator do
  @moduledoc """
  Evaluates the subset of GitHub Actions expression syntax that appears in
  `if:` gates on deploy workflows. Used to disambiguate workflows whose
  candidate jobs share a sub-workflow but gate on different branches.

  Supported:
  * literals — single-quoted strings (with `''` for embedded apostrophes),
    integers, floats, `true`, `false`, `null`
  * operators — `==`, `!=`, `&&`, `||`, `!`, parens
  * functions — `startsWith/2`, `endsWith/2`, `contains/2`, `success/0`,
    `failure/0`, `cancelled/0`, `always/0`
  * context — dotted lookups (e.g. `github.ref`) resolved from a flat
    context map keyed by the full dotted path

  Returns `{:ok, boolean}` when fully evaluated, or `:unknown` if the
  expression references an unknown identifier/function/context key, or if
  parsing fails. Callers should treat `:unknown` conservatively (do not
  use it to exclude a candidate).
  """

  @spec evaluate(String.t() | nil, map()) :: {:ok, boolean()} | :unknown
  def evaluate(nil, _ctx), do: :unknown

  def evaluate(source, ctx) when is_binary(source) and is_map(ctx) do
    tokens = tokenize(strip_wrapper(source))
    {ast, []} = parse_expr(tokens)
    {:ok, truthy?(eval(ast, ctx))}
  rescue
    MatchError -> :unknown
  catch
    {:unknown, _} -> :unknown
    {:parse_error, _} -> :unknown
  end

  def evaluate(_other, _ctx), do: :unknown

  defp strip_wrapper(source) do
    trimmed = String.trim(source)

    case trimmed do
      "${{" <> rest ->
        rest
        |> String.trim_trailing()
        |> String.trim_trailing("}}")
        |> String.trim()

      _ ->
        trimmed
    end
  end

  # ─── tokenizer ──────────────────────────────────────────────────────────

  defp tokenize(""), do: []

  defp tokenize(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r],
    do: tokenize(rest)

  defp tokenize("(" <> rest), do: [:lparen | tokenize(rest)]
  defp tokenize(")" <> rest), do: [:rparen | tokenize(rest)]
  defp tokenize("," <> rest), do: [:comma | tokenize(rest)]
  defp tokenize("." <> rest), do: [:dot | tokenize(rest)]
  defp tokenize("&&" <> rest), do: [:and | tokenize(rest)]
  defp tokenize("||" <> rest), do: [:or | tokenize(rest)]
  defp tokenize("==" <> rest), do: [:eq | tokenize(rest)]
  defp tokenize("!=" <> rest), do: [:neq | tokenize(rest)]
  defp tokenize("!" <> rest), do: [:bang | tokenize(rest)]
  defp tokenize("'" <> rest), do: tokenize_string(rest, [])

  defp tokenize(<<char, _::binary>> = src) when char >= ?0 and char <= ?9,
    do: tokenize_number(src, [])

  defp tokenize(<<char, _::binary>> = src)
       when (char >= ?a and char <= ?z) or (char >= ?A and char <= ?Z) or char === ?_,
       do: tokenize_ident(src, [])

  defp tokenize(other), do: throw({:parse_error, {:unexpected, other}})

  defp tokenize_string("''" <> rest, acc), do: tokenize_string(rest, [?' | acc])

  defp tokenize_string("'" <> rest, acc),
    do: [{:string, acc |> Enum.reverse() |> List.to_string()} | tokenize(rest)]

  defp tokenize_string(<<char, rest::binary>>, acc),
    do: tokenize_string(rest, [char | acc])

  defp tokenize_string("", _acc), do: throw({:parse_error, :unterminated_string})

  defp tokenize_number(<<char, rest::binary>>, acc)
       when (char >= ?0 and char <= ?9) or char === ?.,
       do: tokenize_number(rest, [char | acc])

  defp tokenize_number(rest, acc) do
    text = acc |> Enum.reverse() |> List.to_string()

    value =
      if String.contains?(text, "."),
        do: String.to_float(text),
        else: String.to_integer(text)

    [{:number, value} | tokenize(rest)]
  end

  defp tokenize_ident(<<char, rest::binary>>, acc)
       when (char >= ?a and char <= ?z) or (char >= ?A and char <= ?Z) or
              (char >= ?0 and char <= ?9) or char === ?_ or char === ?-,
       do: tokenize_ident(rest, [char | acc])

  defp tokenize_ident(rest, acc) do
    text = acc |> Enum.reverse() |> List.to_string()

    token =
      case text do
        "true" -> {:bool, true}
        "false" -> {:bool, false}
        "null" -> :null
        _ -> {:ident, text}
      end

    [token | tokenize(rest)]
  end

  # ─── parser ─────────────────────────────────────────────────────────────

  defp parse_expr(tokens), do: parse_or(tokens)

  defp parse_or(tokens) do
    {left, rest} = parse_and(tokens)
    parse_or_tail(left, rest)
  end

  defp parse_or_tail(left, [:or | rest]) do
    {right, rest2} = parse_and(rest)
    parse_or_tail({:or, left, right}, rest2)
  end

  defp parse_or_tail(left, rest), do: {left, rest}

  defp parse_and(tokens) do
    {left, rest} = parse_not(tokens)
    parse_and_tail(left, rest)
  end

  defp parse_and_tail(left, [:and | rest]) do
    {right, rest2} = parse_not(rest)
    parse_and_tail({:and, left, right}, rest2)
  end

  defp parse_and_tail(left, rest), do: {left, rest}

  defp parse_not([:bang | rest]) do
    {operand, rest2} = parse_not(rest)
    {{:not, operand}, rest2}
  end

  defp parse_not(tokens), do: parse_comparison(tokens)

  defp parse_comparison(tokens) do
    {left, rest} = parse_primary(tokens)

    case rest do
      [:eq | rest2] ->
        {right, rest3} = parse_primary(rest2)
        {{:eq, left, right}, rest3}

      [:neq | rest2] ->
        {right, rest3} = parse_primary(rest2)
        {{:neq, left, right}, rest3}

      _ ->
        {left, rest}
    end
  end

  defp parse_primary([{:string, str} | rest]), do: {{:lit, str}, rest}
  defp parse_primary([{:number, num} | rest]), do: {{:lit, num}, rest}
  defp parse_primary([{:bool, bool} | rest]), do: {{:lit, bool}, rest}
  defp parse_primary([:null | rest]), do: {{:lit, nil}, rest}

  defp parse_primary([:lparen | rest]) do
    {inner, rest2} = parse_expr(rest)

    case rest2 do
      [:rparen | rest3] -> {inner, rest3}
      _ -> throw({:parse_error, :missing_rparen})
    end
  end

  defp parse_primary([{:ident, name}, :lparen | rest]) do
    {args, rest2} = parse_call_args(rest, [])
    {{:call, name, args}, rest2}
  end

  defp parse_primary([{:ident, head} | rest]) do
    {path, rest2} = parse_context_path([head], rest)
    {{:ctx, path}, rest2}
  end

  defp parse_primary(other), do: throw({:parse_error, {:expected_primary, other}})

  defp parse_context_path(acc, [:dot, {:ident, name} | rest]),
    do: parse_context_path([name | acc], rest)

  defp parse_context_path(acc, rest), do: {Enum.reverse(acc), rest}

  defp parse_call_args([:rparen | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_call_args(tokens, acc) do
    {arg, rest} = parse_expr(tokens)

    case rest do
      [:comma | rest2] -> parse_call_args(rest2, [arg | acc])
      [:rparen | rest2] -> {Enum.reverse([arg | acc]), rest2}
      _ -> throw({:parse_error, :bad_call_args})
    end
  end

  # ─── evaluator ──────────────────────────────────────────────────────────

  defp eval({:lit, value}, _ctx), do: value
  defp eval({:not, expr}, ctx), do: not truthy?(eval(expr, ctx))

  defp eval({:and, left, right}, ctx) do
    if truthy?(eval(left, ctx)), do: truthy?(eval(right, ctx)), else: false
  end

  defp eval({:or, left, right}, ctx) do
    if truthy?(eval(left, ctx)), do: true, else: truthy?(eval(right, ctx))
  end

  defp eval({:eq, left, right}, ctx), do: gh_equal?(eval(left, ctx), eval(right, ctx))
  defp eval({:neq, left, right}, ctx), do: not gh_equal?(eval(left, ctx), eval(right, ctx))
  defp eval({:ctx, path}, ctx), do: lookup_context(path, ctx)

  defp eval({:call, name, args}, ctx) do
    call(String.downcase(name), Enum.map(args, &eval(&1, ctx)), ctx)
  end

  defp call("startswith", [str, prefix], _ctx) when is_binary(str) and is_binary(prefix),
    do: String.starts_with?(str, prefix)

  defp call("endswith", [str, suffix], _ctx) when is_binary(str) and is_binary(suffix),
    do: String.ends_with?(str, suffix)

  defp call("contains", [str, sub], _ctx) when is_binary(str) and is_binary(sub),
    do: String.contains?(str, sub)

  defp call("success", [], ctx), do: status(ctx) === :success
  defp call("failure", [], ctx), do: status(ctx) === :failure
  defp call("cancelled", [], ctx), do: status(ctx) === :cancelled
  defp call("always", [], _ctx), do: true
  defp call(name, _args, _ctx), do: throw({:unknown, {:function, name}})

  defp status(ctx), do: Map.get(ctx, :status, :success)

  defp lookup_context(path, ctx) do
    key = Enum.join(path, ".")

    case Map.fetch(ctx, key) do
      {:ok, value} -> value
      :error -> throw({:unknown, {:context, key}})
    end
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(""), do: false
  defp truthy?(0), do: false
  defp truthy?(_), do: true

  defp gh_equal?(left, right) when is_binary(left) and is_binary(right), do: left === right
  defp gh_equal?(left, right), do: left == right
end
