defmodule WhoseJamWeb.HowToPlay do
  @moduledoc """
  How a round is played, in three casual steps, for the screen that opens
  each round (the game's `:intro` phase): the TV reads them out large and
  every phone has them in hand.

  A round is a theme, and its steps follow the theme's styles: picking a song
  for each prompt and guessing whose it is (`:guess_who`), or the prompt it
  answers (`:guess_question`), or everyone picking for one prompt and the
  songs going head to head (`:vs`). The points are said in passing, and only
  the ways of scoring the host left on.

  Plain data in, plain data out: `steps/2` takes the public view's theme and
  config maps.
  """

  @type step :: %{title: String.t(), body: String.t()}

  @doc """
  The round's steps, in order: `[%{title, body}]`, three of them.

      iex> theme = %{style_sequence: [:vs]}
      iex> [first | _] = WhoseJamWeb.HowToPlay.steps(theme, %{})
      iex> first.title
      "One prompt, everyone"
  """
  @spec steps(map() | nil, map() | nil) :: [step()]
  def steps(theme, config) do
    config = config || %{}

    case styles(theme) do
      [:vs | _] -> head_to_head()
      styles -> guessing(styles, config)
    end
  end

  defp styles(%{style_sequence: [_ | _] = styles}), do: Enum.uniq(styles)
  defp styles(_theme), do: [:guess_who]

  defp head_to_head do
    [
      %{
        title: "One prompt, everyone",
        body: "Everyone picks a song for the same prompt. Bring your best."
      },
      %{
        title: "Battle it out",
        body:
          "Songs face off two at a time. Vote for the better one, out in the open: everyone sees who backs what."
      },
      %{
        title: "Last song standing",
        body: "Every vote your song wins is a point, and the champion takes +2 more."
      }
    ]
  end

  defp guessing(styles, config) do
    [
      %{
        title: "Pick your songs",
        body: "Your phone gives you a few prompts. Find a song for each, and keep it to yourself."
      },
      %{title: guess_title(styles), body: guess_body(styles, config)},
      %{title: "Keep a straight face", body: bluff_body(config)}
    ]
  end

  defp guess_title([:guess_question]), do: "Guess the prompt"
  defp guess_title(_styles), do: "Guess whose jam"

  defp guess_body(styles, config) do
    task =
      case styles do
        [:guess_question] -> "Vote for the prompt each song was picked for"
        [_, _ | _] -> "Vote for the prompt each song was for, or who picked it"
        _ -> "Vote for whoever you think picked each one"
      end

    if on?(config, :score_correct?),
      do: "The songs play on the TV. #{task}: a point for every right guess.",
      else: "The songs play on the TV. #{task}."
  end

  defp bluff_body(config) do
    fooled =
      if on?(config, :score_fooled?),
        do: "Every friend your song fools is a point for you. ",
        else: ""

    prediction =
      if on?(config, :score_predictions?),
        do: "When it plays, predict who’ll take the blame, for one more.",
        else: "When it plays, predict who’ll take the blame."

    fooled <> prediction
  end

  # A scoring switch the host hasn't turned off.
  defp on?(config, key), do: Map.get(config, key) != false
end
