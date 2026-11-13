defmodule WhoseJamWeb.PlayerToken do
  @moduledoc """
  The signed token that ties a device to its seat in a game.

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
  def seat(session) do
    case verify(Map.get(session, "player_token")) do
      {:ok, %{code: code, player_id: player_id}} -> {:ok, code, player_id}
      _other -> :error
    end
  end
end
