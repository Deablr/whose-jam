defmodule WhoseJam.Credo.Checks.NoSleepInTests do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Don't use `Process.sleep/1` or `:timer.sleep/1` in tests.

      Sleeping makes a test slow when the wait is generous and flaky when it
      isn't. Wait for the thing itself instead: `assert_receive` on the
      broadcast (with an explicit timeout), `Process.monitor/1` and the `:DOWN`
      message, or `:sys.get_state/1` to let a process drain its mailbox. For
      timer-driven behaviour, shorten the timer through config rather than
      sleeping through it.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse({{:., _, [module, :sleep]}, meta, _args} = ast, issues, issue_meta) do
    if sleep_module?(module) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp sleep_module?(:timer), do: true
  defp sleep_module?({:__aliases__, _, [:Process]}), do: true
  defp sleep_module?(_), do: false

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message: "Sleeping in a test; wait with `assert_receive`, a monitor or `:sys.get_state/1`.",
      trigger: "sleep",
      line_no: line_no
    )
  end
end
