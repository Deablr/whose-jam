defmodule WhoseJamWeb.PlayerToken do
  @moduledoc """
  The signed token that ties a device to its seat in a game.

  A device holds it twice: in the session cookie (one seat, the latest joined)
  and in the browser's local storage under the room code
  (`assets/js/hooks/player.js`, `SeatKeeper`), which survives the cookie
  being lost (a phone that closed the tab, or a back button that went too far)
  and keeps a seat in each game the device has joined.

  `PlayLive` signs one when someone joins (`{code, player_id, role}`),
  `WhoseJamWeb.PlayerSessionController` keeps it in the session cookie, and
  the pages that need to know who this device is (`PlayLive` to rejoin,
  `HomeLive` to offer the way back) read it from there. Tokens last four
  hours, longer than any game.
  """

  alias WhoseJamWeb.Endpoint

  @salt "player session"
  @max_age 4 * 60 * 60

  @doc "Signs a device's seat."
  @spec sign(%{code: String.t(), player_id: String.t(), role: atom()}) :: String.t()
  def sign(claims), do: Phoenix.Token.sign(Endpoint, @salt, claims)

  @doc "The seat a token names, if it is genuine and not expired."
  @spec verify(term()) :: {:ok, map()} | {:error, atom()}
  def verify(token) when is_binary(token),
    do: Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age)

  def verify(_token), do: {:error, :missing}

  @doc "The `{code, player_id}` of the seat this session's device holds, or `:error`."
  @spec seat(map()) :: {:ok, String.t(), String.t()} | :error
  def seat(session), do: seat_of(Map.get(session, "player_token"))

  @doc "The `{code, player_id}` a token (from local storage, say) names, or `:error`."
  @spec seat_of(term()) :: {:ok, String.t(), String.t()} | :error
  def seat_of(token) do
    case verify(token) do
      {:ok, %{code: code, player_id: player_id}} -> {:ok, code, player_id}
      _other -> :error
    end
  end
end
