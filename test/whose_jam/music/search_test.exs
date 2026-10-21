defmodule WhoseJam.Music.SearchTest do
  @moduledoc """
  `Music.search/3`'s shared behavior, observed through a stub provider that
  reports every query it is actually asked (search runs in the calling
  process, so `assert_received` sees it).

  Not async: it swaps the enabled-provider list, which is global.
  """
  use ExUnit.Case, async: false

  alias WhoseJam.Music

  defmodule Stub do
    @behaviour WhoseJam.Music.Provider

    def id, do: :stub
    def name, do: "Stub"
    def requirement, do: "none"
    def ineligible_message, do: "none"
    def connect_kind, do: :none
    def video?, do: false
    def configured?, do: Process.get(:stub_configured, true)
    def valid_uri?(_uri), do: true
    def valid_art_url?(_url), do: false
    def connect(_params), do: {:ok, %{}}
    def eligible?(_auth), do: true
    def client_config(_auth), do: %{}

    def search(query, _auth) do
      send(self(), {:searched, query})

      Process.get(
        :stub_result,
        {:ok, [%{uri: "stub:1", name: query, artist: "a", album_art_url: nil}]}
      )
    end
  end

  setup do
    previous = Application.fetch_env!(:whose_jam, :music_providers)
    Application.put_env(:whose_jam, :music_providers, [Stub | previous])
    on_exit(fn -> Application.put_env(:whose_jam, :music_providers, previous) end)

    # Results are cached in a shared table: every test searches its own terms.
    %{term: "term#{System.unique_integer([:positive])}"}
  end

  test "searches with the normalized query and shares the result across spellings", %{term: term} do
    assert {:ok, [%{name: name}] = results} = Music.search(:stub, "  #{term}   FOO ", %{})
    assert name == "#{term} foo"
    assert_received {:searched, searched}
    assert searched == "#{term} foo"

    # Same query, different case/spacing: served from the cache.
    assert Music.search(:stub, "#{term} foo", %{}) == {:ok, results}
    assert Music.search(:stub, "#{String.upcase(term)}\tFoo", %{}) == {:ok, results}
    refute_received {:searched, _}
  end

  test "different queries are searched separately", %{term: term} do
    {:ok, _} = Music.search(:stub, "#{term} a", %{})
    {:ok, _} = Music.search(:stub, "#{term} b", %{})
    assert_received {:searched, _}
    assert_received {:searched, _}
  end

  test "errors are never cached", %{term: term} do
    Process.put(:stub_result, {:error, :boom})
    assert Music.search(:stub, term, %{}) == {:error, :boom}
    assert Music.search(:stub, term, %{}) == {:error, :boom}
    assert_received {:searched, _}
    assert_received {:searched, _}

    Process.delete(:stub_result)
    assert {:ok, [_]} = Music.search(:stub, term, %{})
  end

  test "an unconfigured provider is never searched", %{term: term} do
    Process.put(:stub_configured, false)

    assert Music.search(:stub, term, %{}) == {:error, :not_configured}
    refute_received {:searched, _}
  end

  test "a blank query is never searched" do
    assert Music.search(:stub, "  \t ", %{}) == {:ok, []}
    refute_received {:searched, _}
  end

  test "an unknown provider is an error, not a crash" do
    assert Music.search(:nope, "x", %{}) == {:error, :unknown_provider}
  end
end
