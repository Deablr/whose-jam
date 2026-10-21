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
      standalone `.html.heex` templates, so keep dynamic `style` out of those by
      hand.
      """,
      params: [allowed_helpers: "Function names allowed to produce a `style` value."]
    ]

  @style_attr ~r/(?<![\w:-])style\s*=\s*\{/

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
    first_line = meta[:line] + if(meta[:delimiter] == ~s("""), do: 1, else: 0)

    new_issues =
      for [{start, len}] <- Regex.scan(@style_attr, template, return: :index),
          body = attr_body(binary_part(template, start + len, byte_size(template) - start - len)),
          not allowed_call?(body, allowed) do
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

  # The text of the `{...}` expression, given the text right after its `{`.
  defp attr_body(rest), do: attr_body(rest, 1, false, [])

  defp attr_body(<<>>, _depth, _in_string, _acc), do: nil

  defp attr_body(<<?\\, c, rest::binary>>, depth, true, acc),
    do: attr_body(rest, depth, true, [c, ?\\ | acc])

  defp attr_body(<<?", rest::binary>>, depth, in_string, acc),
    do: attr_body(rest, depth, not in_string, [?" | acc])

  defp attr_body(<<?{, rest::binary>>, depth, false, acc),
    do: attr_body(rest, depth + 1, false, [?{ | acc])

  defp attr_body(<<?}, _rest::binary>>, 1, false, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp attr_body(<<?}, rest::binary>>, depth, false, acc),
    do: attr_body(rest, depth - 1, false, [?} | acc])

  defp attr_body(<<c, rest::binary>>, depth, in_string, acc),
    do: attr_body(rest, depth, in_string, [c | acc])

  # True only when the whole expression is one call to an allowed helper.
  defp allowed_call?(body, allowed) do
    case Regex.run(~r/\A\s*([a-z_][a-zA-Z0-9_]*[?!]?)\(/, body, return: :index) do
      [{_, _}, {name_start, name_len}] ->
        rest_start = name_start + name_len + 1

        binary_part(body, name_start, name_len) in allowed and
          sole_call?(binary_part(body, rest_start, byte_size(body) - rest_start))

      nil ->
        false
    end
  end

  # `rest` starts just after the call's `(`: is the matching `)` the last thing?
  defp sole_call?(rest), do: sole_call?(rest, 1, false)

  defp sole_call?(<<>>, _depth, _in_string), do: false
  defp sole_call?(<<?\\, _c, rest::binary>>, depth, true), do: sole_call?(rest, depth, true)

  defp sole_call?(<<?", rest::binary>>, depth, in_string),
    do: sole_call?(rest, depth, not in_string)

  defp sole_call?(<<?(, rest::binary>>, depth, false), do: sole_call?(rest, depth + 1, false)
  defp sole_call?(<<?), rest::binary>>, 1, false), do: String.trim(rest) == ""
  defp sole_call?(<<?), rest::binary>>, depth, false), do: sole_call?(rest, depth - 1, false)
  defp sole_call?(<<_c, rest::binary>>, depth, in_string), do: sole_call?(rest, depth, in_string)
end
