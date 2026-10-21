defmodule WhoseJam.Credo.Checks.NoGlobalEnvInAsyncTest do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      An `async: true` test module must not change global state with
      `Application.put_env/3`, `Application.put_all_env/2`,
      `Application.delete_env/2`, `System.put_env/2` or `System.delete_env/1`.

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

    source_file
    |> Credo.Code.prewalk(&collect_modules/2, [])
    |> Enum.flat_map(&module_issues(&1, issue_meta))
  end

  defp collect_modules({:defmodule, _, [_name, [do: body]]} = ast, bodies),
    do: {ast, [body | bodies]}

  defp collect_modules(ast, bodies), do: {ast, bodies}

  # Each module is judged on its own `async:` flag; nested modules are skipped
  # here and picked up as modules in their own right.
  defp module_issues(body, issue_meta) do
    {_body, {async?, writes}} = Macro.prewalk(body, {false, []}, &scan/2)

    if async? do
      Enum.map(writes, fn {call, line_no} -> issue_for(issue_meta, call, line_no) end)
    else
      []
    end
  end

  defp scan({:defmodule, _, _}, acc), do: {:ok, acc}

  defp scan({:use, _, [_module, opts]} = ast, {async?, writes}) when is_list(opts) do
    async? = async? or (Keyword.keyword?(opts) and Keyword.get(opts, :async) == true)
    {ast, {async?, writes}}
  end

  defp scan({{:., _, [{:__aliases__, _, [mod]}, fun]}, meta, _args} = ast, {async?, writes} = acc) do
    if {mod, fun} in @global_writers do
      {ast, {async?, [{"#{mod}.#{fun}", meta[:line]} | writes]}}
    else
      {ast, acc}
    end
  end

  defp scan(ast, acc), do: {ast, acc}

  defp issue_for(issue_meta, call, line_no) do
    format_issue(issue_meta,
      message: "`#{call}` in an `async: true` module leaks into concurrent tests.",
      trigger: call,
      line_no: line_no
    )
  end
end
