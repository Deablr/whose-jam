defmodule WhoseJam.Repo do
  use Ecto.Repo,
    otp_app: :whose_jam,
    adapter: Ecto.Adapters.Postgres
end
