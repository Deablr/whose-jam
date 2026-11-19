defmodule WhoseJamWeb.HowToPlay do
  @moduledoc """
  How a round is played, in three casual steps, for the screen that opens
  each round (the game's `:intro` phase): the TV reads them out large and
  every phone has them in hand.

  A round is a theme, and its steps follow the theme's styles: picking a song
  for each prompt and guessing whose it is (`:guess_who`), or the prompt it
  answers (`:guess_question`), or everyone picking for one prompt and the
  songs going head to head (`:vs`). The points are said in passing, and only
  the ways of scoring the host left on. The TV and players' phones read the
  players' steps; an audience phone reads its own (it picks nothing, and
  always scores a right guess).

  Plain data in, plain data out: `steps/3` takes the public view's theme and
  config maps.
  """

  @type step :: %{title: String.t(), body: String.t()}
  @type role :: :player | :audience

  @doc """
  The round's steps, in order: `[%{title, body}]`, three of them, for a
  player (and the TV) or an audience member.

      iex> theme = %{style_sequence: [:vs]}
      iex> [first | _] = WhoseJamWeb.HowToPlay.steps(theme, %{})
      iex> first.title
      "One prompt, everyone"
  """
  @spec steps(map() | nil, map() | nil, role()) :: [step()]
  def steps(theme, config, role \\ :player) do
    config = config || %{}

    case styles(theme) do
      [:vs | _] -> head_to_head(role)
      styles -> guessing(styles, config, role)
    end
  end

  defp styles(%{style_sequence: [_ | _] = styles}), do: Enum.uniq(styles)
  defp styles(_theme), do: [:guess_who]

  defp head_to_head(role) do
    [
      %{
        title: "One prompt, everyone",
        body:
          if(role == :audience,
            do: "Every player picks a song for the same prompt.",
            else: "Everyone picks a song for the same prompt. Bring your best."
          )
      },
      %{
        title: "Battle it out",
        body:
          "Songs face off two at a time. Vote for the better one, out in the open: everyone sees who backs what."
      },
      %{
        title: "Last song standing",
        body:
          if(role == :audience,
            do: "Every vote a song wins is a point for whoever picked it.",
            else: "Every vote your song wins is a point, and the champion takes +2 more."
          )
      }
    ]
  end

  defp guessing(styles, config, :audience) do
    [
      %{
        title: "The players pick songs",
        body: "Each one picks a song for a few prompts, and keeps it to themselves."
      },
      %{title: guess_title(styles), body: guess_body(styles, true)},
      %{
        title: "Don’t be fooled",
        body:
          if(on?(config, :score_fooled?),
            do: "The players score for every friend they fool. Don’t let it be you.",
            else: "Some of those songs are bluffs. Don’t fall for them."
          )
      }
    ]
  end

  defp guessing(styles, config, _player) do
    [
      %{
        title: "Pick your songs",
        body: "Your phone gives you a few prompts. Find a song for each, and keep it to yourself."
      },
      %{title: guess_title(styles), body: guess_body(styles, on?(config, :score_correct?))},
      %{title: "Keep a straight face", body: bluff_body(config)}
    ]
  end

  defp guess_title([:guess_question]), do: "Guess the prompt"
  defp guess_title(_styles), do: "Guess whose jam"

  defp guess_body(styles, points?) do
    task =
      case styles do
        [:guess_question] -> "Vote for the prompt each song was picked for"
        [_, _ | _] -> "Vote for the prompt each song was for, or who picked it"
        _ -> "Vote for whoever you think picked each one"
      end

    if points?,
      do: "The songs play on the TV. #{task}: a point for every right guess.",
      else: "The songs play on the TV. #{task}."
  end

  defp bluff_body(config) do
    fooled =
      if on?(config, :score_fooled?),
        do: "Every friend your song fools is a point for you. ",
        else: ""

    split =
      cond do
        not on?(config, :score_split?) -> ""
        fooled == "" -> "A song some call and some don’t is a point for you. "
        true -> "So is a song some call and some don’t. "
      end

    prediction =
      if on?(config, :score_predictions?),
        do: "When it plays, predict who’ll take the blame, for one more.",
        else: "When it plays, predict who’ll take the blame."

    fooled <> split <> prediction
  end

  # A scoring switch the host hasn't turned off.
  defp on?(config, key), do: Map.get(config, key) != false
end
