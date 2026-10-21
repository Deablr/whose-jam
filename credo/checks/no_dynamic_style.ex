defmodule WhoseJam.Credo.Checks.NoDynamicStyle do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed_helpers: []],
    explanations: [
      check: """
      A dynamic `style={...}` attribute in a `~H` template must be exactly one
      call to a vetted helper listed in `.credo.exs` (`allowed_helpers`).

      HEEx escapes attribute values for HTML but not for CSS, so player or
      provider data (song names, album-art URLs) built into a style string can
      break out of the declaration, e.g. `url(...)` closed early. Helpers on the
      allowlist must only emit values the server computed (numbers, fixed
      keywords) or ones validated against a strict pattern. Anything else in the
      attribute, including concatenating onto an allowed call, is flagged. Prefer
      a class or an `<img src={...}>`, which HEEx escapes correctly.

      Only `~H` sigils in `.ex` files are scanned: Credo does not parse
      standalone `.html.heex` templates, and a style passed through a spread
      (`<div {@rest}>`) is not visible either, so keep dynamic `style` out of
      those by hand.
      """,
      params: [allowed_helpers: "Function names allowed to produce a `style` value."]
    ]

  @style_attr ~r/(?<![\w:-])style\s*=\s*\{/i

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    allowed = params |> Params.get(:allowed_helpers, __MODULE__) |> Enum.map(&to_string/1)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, allowed))
  end

  defp traverse(
         {:sigil_H, meta, [{:<<>>, _, [template]}, _mods]} = ast,
         issues,
         issue_meta,
         allowed
       )
       when is_binary(template) do
    first_line = meta[:line] + if(meta[:delimiter] in [~s("""), "'''"], do: 1, else: 0)

    new_issues =
      for [{start, len}] <- Regex.scan(@style_attr, template, return: :index),
          rest = binary_part(template, start + len, byte_size(template) - start - len),
          not allowed_call?(attr_ast(rest), allowed) do
        before = binary_part(template, 0, start)
        line_no = first_line + length(String.split(before, "\n")) - 1

        format_issue(issue_meta,
          message:
            "Dynamic `style` attribute; use a class, or a single call to a helper listed in .credo.exs.",
          trigger: "style",
          line_no: line_no
        )
      end

    {ast, new_issues ++ issues}
  end

  defp traverse(ast, issues, _issue_meta, _allowed), do: {ast, issues}

  # `rest` is the template text right after the attribute's `{`. The body ends
  # where HEEx ends it, not where Elixir would: Phoenix.LiveView's tokenizer
  # counts `{` and `}` depth without looking at strings or comments, treats
  # `\{` and `\}` as plain text, and closes the attribute at the first `}` at
  # depth 0. Ending it anywhere else lets a comment hide a brace and the check
  # approve a shorter expression than the one HEEx compiles. A body that never
  # closes (`:error`) is a violation, like one that does not parse.
  defp attr_ast(rest) do
    with {:ok, body} <- attr_body(rest, 0, []),
         {:ok, ast} <- Code.string_to_quoted(body, emit_warnings: false) do
      {:ok, ast}
    else
      _ -> :error
    end
  end

  defp attr_body(<<>>, _depth, _acc), do: :error

  defp attr_body(<<?}, _rest::binary>>, 0, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp attr_body(<<?\\, c, rest::binary>>, depth, acc) when c in [?{, ?}],
    do: attr_body(rest, depth, [c, ?\\ | acc])

  defp attr_body(<<?{, rest::binary>>, depth, acc), do: attr_body(rest, depth + 1, [?{ | acc])
  defp attr_body(<<?}, rest::binary>>, depth, acc), do: attr_body(rest, depth - 1, [?} | acc])
  defp attr_body(<<c, rest::binary>>, depth, acc), do: attr_body(rest, depth, [c | acc])

  # Allowed only when the whole expression is one call to an allowed helper:
  # `<>`, `|>`, remote calls, variables and everything else are different ASTs.
  defp allowed_call?({:ok, {name, _meta, args}}, allowed) when is_atom(name) and is_list(args),
    do: to_string(name) in allowed

  defp allowed_call?(_ast, _allowed), do: false
end
