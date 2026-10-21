defmodule WhoseJam.Credo.Checks.NoBareOkMatch do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Don't assert success with a bare match (`:ok = ...` or `{:ok, x} = ...`)
      anywhere in `lib/` (release tasks are excluded in `.credo.exs`).

      A refused call (`{:error, :not_lobby}`, a provider error, a bad param)
      raises a MatchError, which crashes the LiveView (the TV player restarts)
      or the game process. Handle the error branch with `with` or `case`:

          with {:ok, auth} <- provider.connect(%{}),
               :ok <- Game.set_music(code, provider.id(), auth) do
            {:noreply, socket}
          else
            {:error, reason} -> {:noreply, put_flash(socket, :error, message(reason))}
          end

      Patterns are fine: `def f({:ok, _} = result)`, `{:ok, _} = r ->` in a
      `case`/`fn`, and the left side of `<-` bind a value without asserting, so
      they are not flagged.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Function heads, clause patterns and generators are patterns, not assertions.
  # Replacing them lets the walk carry on into bodies without seeing their `=`.
  defp traverse({kind, meta, [_head | rest]}, issues, _issue_meta)
       when kind in [:def, :defp, :defmacro, :defmacrop],
       do: {{kind, meta, [:_ | rest]}, issues}

  defp traverse({:->, meta, [_patterns, body]}, issues, _issue_meta),
    do: {{:->, meta, [[], body]}, issues}

  defp traverse({:<-, meta, [_pattern, rhs]}, issues, _issue_meta),
    do: {{:<-, meta, [:_, rhs]}, issues}

  defp traverse({:=, meta, [lhs, _rhs]} = ast, issues, issue_meta) do
    if ok_pattern?(lhs) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp ok_pattern?(:ok), do: true
  defp ok_pattern?({:ok, _}), do: true
  defp ok_pattern?({:{}, _, [:ok | _]}), do: true
  defp ok_pattern?(_), do: false

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message: "Bare `:ok` match crashes on an error reply; handle it with `with` or `case`.",
      trigger: "=",
      line_no: line_no
    )
  end
end
