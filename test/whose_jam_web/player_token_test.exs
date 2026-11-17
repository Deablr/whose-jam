defmodule WhoseJamWeb.PlayerTokenTest do
  use ExUnit.Case, async: true

  alias WhoseJamWeb.{Endpoint, PlayerToken}

  @salt "player session"

  describe "seat_of/1" do
    test "names the seat a genuine token holds" do
      token = PlayerToken.sign(%{code: "ABCD", player_id: "p1", role: :player})
      assert PlayerToken.seat_of(token) == {:ok, "ABCD", "p1"}
    end

    test "refuses a tampered token, and anything that isn't a token" do
      token = PlayerToken.sign(%{code: "ABCD", player_id: "p1", role: :player})

      assert PlayerToken.seat_of(token <> "x") == :error
      assert PlayerToken.seat_of(nil) == :error
      assert PlayerToken.seat_of(%{"token" => token}) == :error
      assert PlayerToken.seat_of(123) == :error
    end

    test "refuses a token older than four hours, and keeps one just under" do
      claims = %{code: "ABCD", player_id: "p1", role: :player}
      # `:signed_at` is in seconds.
      now = System.system_time(:second)

      old = Phoenix.Token.sign(Endpoint, @salt, claims, signed_at: now - 4 * 60 * 60 - 5)
      fresh = Phoenix.Token.sign(Endpoint, @salt, claims, signed_at: now - 4 * 60 * 60 + 60)

      assert PlayerToken.seat_of(old) == :error
      assert PlayerToken.seat_of(fresh) == {:ok, "ABCD", "p1"}
    end
  end
end
