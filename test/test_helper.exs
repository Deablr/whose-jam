ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(WhoseJam.Repo, :manual)

# The project's Credo checks (credo/checks/) are tested with Credo.Test.Case,
# which needs the Credo services running; the dep itself is `runtime: false`.
# Inside `mix precommit` the earlier `credo` step has already started them.
case Application.ensure_all_started(:credo) do
  {:ok, _started} -> :ok
  {:error, {:credo, {{:already_started, _pid}, _child}}} -> :ok
end
