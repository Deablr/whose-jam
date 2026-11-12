# Browser end-to-end tests (test/e2e, tagged :e2e) need Docker and Playwright;
# they run only through `mix test.e2e`, which provides both.
ExUnit.start(exclude: [:e2e])
Ecto.Adapters.SQL.Sandbox.mode(WhoseJam.Repo, :manual)

# The project's Credo checks (credo/checks/) are tested with Credo.Test.Case,
# which needs the Credo services running; the dep itself is `runtime: false`.
# Inside `mix precommit` the earlier `credo` step has already started them.
case Application.ensure_all_started(:credo) do
  {:ok, _started} -> :ok
  {:error, {:credo, {{:already_started, _pid}, _child}}} -> :ok
end
