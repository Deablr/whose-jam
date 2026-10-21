defmodule WhoseJam.Credo.Checks.NoGlobalEnvInAsyncTest do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      An `async: true` test module must not change global state with
      `Application.put_env/3`, `Application.delete_env/2`, `System.put_env/2`
      or `System.delete_env/1`.

      Async modules run concurrently with every other async module, so the
      change leaks into unrelated tests and makes them flaky. Either make the
      module `async: false` (and restore the old value in `on_exit/1`), or pass
      the value in explicitly instead of reading it from the environment.
      """
    ]

  @global_writers [
    {:Application, :put_env},
    {:Application, :delete_env},
    {:Application, :put_all_env},
    {:System, :put_env},
    {:System, :delete_env}
  ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    {async?, writes} = Credo.Code.prewalk(source_file, &traverse/2, {false, []})

    if async? do
      Enum.map(writes, fn {call, line_no} -> issue_for(issue_meta, call, line_no) end)
    else
      []
    end
  end

  defp traverse({:use, _, [_module, opts]} = ast, {async?, writes}) when is_list(opts) do
    {ast, {async? or Keyword.get(opts, :async) == true, writes}}
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [mod]}, fun]}, meta, _args} = ast,
         {async?, writes} = acc
       ) do
    if {mod, fun} in @global_writers do
      {ast, {async?, [{"#{mod}.#{fun}", meta[:line]} | writes]}}
    else
      {ast, acc}
    end
  end

  defp traverse(ast, acc), do: {ast, acc}

  defp issue_for(issue_meta, call, line_no) do
    format_issue(issue_meta,
      message: "`#{call}` in an `async: true` module leaks into concurrent tests.",
      trigger: call,
      line_no: line_no
    )
  end
end
