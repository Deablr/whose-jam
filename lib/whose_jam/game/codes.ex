defmodule WhoseJam.Game.Codes do
  @moduledoc """
  Room-code generation for games.

  Codes are short, uppercase, and drawn from an *unambiguous* alphabet — the
  letters and digits that are easy to read off a TV and type on a phone without
  confusing `O`/`0`, `I`/`1`/`L`, etc. Pure and side-effect free apart from the
  RNG draw.
  """

  # 30 unambiguous characters: A-Z minus I, L, O and digits 2-9 (no 0/1).
  @alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @default_length 4

  @doc "Generate a random room code of `length` unambiguous characters."
  @spec generate(pos_integer()) :: String.t()
  def generate(length \\ @default_length) when is_integer(length) and length > 0 do
    for _ <- 1..length, into: "", do: <<Enum.random(@alphabet)>>
  end

  @doc "The unambiguous character set used for codes (as a charlist)."
  @spec alphabet() :: charlist()
  def alphabet, do: @alphabet
end
