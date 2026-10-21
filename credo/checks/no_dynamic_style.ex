defmodule WhoseJam.Credo.Checks.NoDynamicStyle do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed_helpers: []],
    explanations: [
      check: """
      A dynamic `style={...}` attribute in a HEEx template must come from a
      vetted helper listed in `.credo.exs` (`allowed_helpers`).

      HEEx escapes attribute values for HTML but not for CSS, so player or
      provider data (song names, album-art URLs) built into a style string can
      break out of the declaration, e.g. `url(...)` closed early. Helpers on the
      allowlist must only emit values the server computed (numbers, fixed
      keywords) or ones validated against a strict pattern. Prefer a class or
      an `<img src={...}>`, which HEEx escapes correctly.
      """,
      params: [allowed_helpers: "Function names allowed to produce a `style` value."]
    ]

  @style_attr ~r/\bstyle=\{\s*([a-z_][a-zA-Z0-9_?!]*)?(\()?/

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
      template
      |> String.split("\n")
      |> Enum.with_index(first_line)
      |> Enum.flat_map(fn {line, line_no} -> line_issues(line, line_no, issue_meta, allowed) end)

    {ast, new_issues ++ issues}
  end

  defp traverse(ast, issues, _issue_meta, _allowed), do: {ast, issues}

  defp line_issues(line, line_no, issue_meta, allowed) do
    for [_ | captures] <- Regex.scan(@style_attr, line),
        not allowed_call?(captures, allowed) do
      format_issue(issue_meta,
        message: "Dynamic `style` attribute; use a class, or a helper listed in .credo.exs.",
        trigger: "style=",
        line_no: line_no
      )
    end
  end

  defp allowed_call?([name, "("], allowed), do: name in allowed
  defp allowed_call?(_captures, _allowed), do: false
end
