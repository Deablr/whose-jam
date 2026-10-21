defmodule WhoseJam.Music.ProviderContractTest do
  @moduledoc """
  Runs one set of expectations against *every* enabled music provider — the
  shared contract that keeps `Game.Server` and the LiveViews provider-neutral.
  """
  use ExUnit.Case, async: true

  alias WhoseJam.Music
  alias WhoseJam.Music.Provider
  alias WhoseJam.MusicFixtures

  @providers Application.compile_env(:whose_jam, :music_providers)

  defp call(mod, fun), do: apply(mod, fun, [])

  test "every enabled provider has a fixture, and no fixture is orphaned" do
    ids = Enum.map(@providers, & &1.id())
    assert Enum.sort(ids) == Enum.sort(MusicFixtures.sample_ids())
  end

  test "provider ids are unique" do
    ids = Enum.map(@providers, & &1.id())
    assert ids == Enum.uniq(ids)
  end

  for provider <- @providers do
    describe "#{inspect(provider)}" do
      @provider provider
      @sample MusicFixtures.sample(provider.id())

      test "implements every required callback" do
        required =
          Provider.behaviour_info(:callbacks) -- Provider.behaviour_info(:optional_callbacks)

        for {fun, arity} <- required do
          assert function_exported?(@provider, fun, arity),
                 "#{inspect(@provider)} is missing #{fun}/#{arity}"
        end
      end

      test "declares its identity and capabilities" do
        # Via `call/2`: the type checker would otherwise flag these as always true.
        assert is_atom(call(@provider, :id))
        assert is_binary(call(@provider, :name)) and call(@provider, :name) != ""
        assert is_binary(call(@provider, :requirement))
        assert is_binary(call(@provider, :ineligible_message))
        assert call(@provider, :connect_kind) in [:oauth_redirect, :browser, :none]
        assert is_boolean(call(@provider, :video?))
        assert is_boolean(call(@provider, :configured?))
      end

      test "is found by id, as an atom or the string a URL carries" do
        assert Music.fetch_provider(@provider.id()) == {:ok, @provider}
        assert Music.fetch_provider(Atom.to_string(@provider.id())) == {:ok, @provider}
      end

      test "accepts its own song and normalizes it" do
        assert @provider.valid_uri?(@sample.song.uri)
        assert Music.normalize_track(@provider.id(), @sample.song) == {:ok, @sample.song}
      end

      test "accepts string-keyed songs (as they arrive from the browser)" do
        string_keyed = Map.new(@sample.song, fn {k, v} -> {Atom.to_string(k), v} end)
        assert Music.normalize_track(@provider.id(), string_keyed) == {:ok, @sample.song}
      end

      test "rejects other providers' song URIs" do
        for other <- @providers, other != @provider do
          song = MusicFixtures.sample(other.id()).song

          assert Music.normalize_track(@provider.id(), song) == {:error, :invalid_song},
                 "#{inspect(@provider)} accepted #{song.uri}"
        end
      end

      test "rejects malformed URIs" do
        for bad <- [nil, 123, "", "x", @sample.song.uri <> "\n", @sample.song.uri <> "x"] do
          assert Music.normalize_track(@provider.id(), %{@sample.song | uri: bad}) ==
                   {:error, :invalid_song},
                 "expected #{inspect(bad)} to be rejected"
        end
      end

      test "drops album art it doesn't recognize" do
        for bad <- [@sample.hostile_art, "javascript:alert(1)", 123, nil] do
          {:ok, song} =
            Music.normalize_track(@provider.id(), %{@sample.song | album_art_url: bad})

          assert song.album_art_url == nil, "expected #{inspect(bad)} to be dropped"
        end
      end

      test "an eligible account is eligible" do
        assert @provider.eligible?(@sample.auth)
      end

      test "an ineligible account is not" do
        # Read at runtime: not every provider has an ineligible state (Mock).
        case MusicFixtures.sample(@provider.id()).ineligible_auth do
          nil -> :ok
          auth -> refute @provider.eligible?(auth)
        end
      end

      test "client config is JSON-encodable, with and without an account" do
        assert {:ok, _} = Jason.encode(@provider.client_config(@sample.auth))
        assert {:ok, _} = Jason.encode(@provider.client_config(%{}))
      end

      test "an unconfigured provider reports :not_configured instead of searching" do
        # Only providers whose credentials are absent here (Mock needs none).
        if apply(@provider, :configured?, []) do
          :ok
        else
          assert Music.search(@provider.id(), "anything", @sample.auth) ==
                   {:error, :not_configured}
        end
      end

      test "a blank search never touches the provider" do
        assert Music.search(@provider.id(), "   ", @sample.auth) == {:ok, []}
      end
    end
  end

  test "an unknown provider id is an error, not a new atom" do
    assert Music.fetch_provider("nope") == :error
    assert Music.search(:nope, "x", %{}) == {:error, :unknown_provider}
    assert Music.normalize_track(:nope, %{}) == {:error, :invalid_song}
  end
end
