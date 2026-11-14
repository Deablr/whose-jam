defmodule WhoseJamWeb.CoreComponentsTest do
  # The pure text and class helpers the game screens share. Plain functions,
  # tested as such (no rendering).
  use ExUnit.Case, async: true

  import WhoseJamWeb.CoreComponents,
    only: [
      curly: 1,
      no_widow: 1,
      poster_title: 1,
      tie_part: 2,
      tie_band_corners: 2,
      tie_bracket: 3,
      clock_length: 1
    ]

  describe "curly/1" do
    test "escapes the text and sets each curly apostrophe in the body face" do
      assert Phoenix.HTML.safe_to_string(curly("<b>It’s</b>")) ==
               ~s(&lt;b&gt;It<span class="jam-apos">’</span>s&lt;/b&gt;)
    end

    test "leaves text without one as it is, escaped" do
      assert Phoenix.HTML.safe_to_string(curly("Rock & roll")) == "Rock &amp; roll"
    end
  end

  describe "no_widow/1" do
    test "joins the last two words of a longer line" do
      assert no_widow("Pick who chose it") == "Pick who chose it"
    end

    test "leaves three words or fewer alone" do
      assert no_widow("Listen up now") == "Listen up now"
    end
  end

  describe "poster_title/1" do
    test "keeps a closing parenthetical of up to 14 characters whole" do
      # "(abcdef ghijk)": 12 inside, 14 with its brackets.
      assert poster_title("Song (abcdef ghijk)") == "Song (abcdef ghijk)"
    end

    test "lets a longer one break, rather than run past the poster" do
      # 13 inside: left to break (three words, so no widow join either).
      assert poster_title("Song (abcdef ghijkl)") == "Song (abcdef ghijkl)"
      assert poster_title("FLIRT (if i don’t mean it)") == "FLIRT (if i don’t mean it)"
    end

    test "passes anything that isn't a string through" do
      assert poster_title(nil) == nil
    end
  end

  # Ranks as Standings.rank/2 gives them: two runs that meet, then a place
  # of its own.
  @rows Enum.with_index([1, 1, 3, 3, 3, 6], fn rank, i -> %{id: "p#{i}", rank: rank} end)

  describe "tie_part/2" do
    test "says where each row sits in its run, two runs that meet kept apart" do
      assert Enum.map(@rows, &tie_part(@rows, &1)) ==
               [:first, :last, :first, :middle, :last, :first]
    end
  end

  describe "tie_band_corners/2" do
    test "rounds a run's band at its two ends only" do
      assert Enum.map(@rows, &tie_band_corners(@rows, &1)) ==
               [
                 "rounded-t-md",
                 "rounded-b-md",
                 "rounded-t-md",
                 nil,
                 "rounded-b-md",
                 "rounded-t-md"
               ]
    end
  end

  describe "tie_bracket/3" do
    test "starts the line inside a run's first row and ends it inside its last" do
      [first, middle, last] = Enum.slice(@rows, 2, 3)

      assert [_, "before:top-2 before:-bottom-3"] = tie_bracket(@rows, first, :tv)
      assert [_, "before:-inset-y-3"] = tie_bracket(@rows, middle, :tv)
      assert [_, "before:-top-1.5 before:bottom-1.5"] = tie_bracket(@rows, last, :phone)
    end
  end

  describe "clock_length/1" do
    test "says a clock's length as its numerals will show it" do
      assert Enum.map([0, 59, 60, 90, 300], &clock_length/1) ==
               ["0:00", "0:59", "1:00", "1:30", "5:00"]
    end
  end
end
