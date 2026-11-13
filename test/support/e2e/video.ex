defmodule WhoseJamWeb.E2E.Video do
  @moduledoc """
  Composites per-device browser recordings into one video with ffmpeg.

  Every tile is scaled to fit its rectangle on the canvas (letterboxed in the
  game's ink colour), delayed by its `offset_ms` so all screens stay in sync,
  and stacked with ffmpeg's `xstack` filter into an H.264 MP4.

  Recordings don't start when their browser opens but at some later first
  paint, each a little differently, so the offsets come from the recordings
  themselves: `flash_end/1` finds the moment a white screen went dark again,
  the end of a mark `WhoseJamWeb.E2E.Stage` puts on every screen at once. (Its
  end, because a recording may only begin part-way through the flash.)

  Uses `ffmpeg` from the `PATH` when there is one, otherwise the
  `linuxserver/ffmpeg` Docker image at a fixed version tag, run without network
  access (Docker is already required for the e2e suite's database).
  """

  @typedoc "One recording: its file, how long to hold it back, and where it goes on the canvas."
  @type tile :: %{
          path: Path.t(),
          offset_ms: non_neg_integer(),
          rect: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
        }

  @docker_image "linuxserver/ffmpeg:version-7.1-cli"
  @background "0x120726"
  @fps 25

  # A frame this bright (mean luma, 0..255) is the white flash: the game's
  # screens are dark.
  @flash_luma 200
  # The flash is put up before the game starts; no need to look further in.
  @flash_window_s 60

  @doc """
  When, in seconds from its start, the recording at `path` first stops showing
  an all-white screen, or `nil` if it never shows one (or ffmpeg can't say).
  """
  @spec flash_end(Path.t()) :: float() | nil
  def flash_end(path) do
    path = Path.expand(path)
    root = Path.dirname(path)
    {command, prefix} = ffmpeg(root)

    args =
      ["-hide_banner", "-loglevel", "error", "-t", "#{@flash_window_s}"] ++
        ["-i", Path.basename(path), "-an", "-vf"] ++
        ["signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-", "-f", "null", "-"]

    case System.cmd(command, prefix ++ args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output |> frame_lumas() |> first_dark_after_bright()
      {_output, _status} -> nil
    end
  end

  # ffmpeg prints a "pts_time:<s>" line, then that frame's "YAVG=<luma>" line.
  defp frame_lumas(output) do
    times =
      for [_, seconds] <- Regex.scan(~r/pts_time:([0-9.]+)/, output), do: parse_float(seconds)

    lumas = for [_, luma] <- Regex.scan(~r/YAVG=([0-9.]+)/, output), do: parse_float(luma)
    Enum.zip(times, lumas)
  end

  defp first_dark_after_bright(frames) do
    frames
    |> Enum.drop_while(fn {_time, luma} -> luma < @flash_luma end)
    |> Enum.find(fn {_time, luma} -> luma < @flash_luma end)
    |> case do
      {time, _luma} -> time
      nil -> nil
    end
  end

  defp parse_float(text) do
    case Float.parse(text) do
      {number, _} -> number
      :error -> nil
    end
  end

  @doc """
  Writes the tiles, laid out on a `{width, height}` canvas, to `output` (an
  `.mp4`), leaving out its first `skip_ms` (what came before the game). Every
  tile path must sit under `Path.dirname(output)`. Raises if ffmpeg fails.
  """
  @spec compose!([tile()], {pos_integer(), pos_integer()}, Path.t(), non_neg_integer()) :: :ok
  def compose!(tiles, {width, height}, output, skip_ms \\ 0) do
    root = Path.dirname(output)
    inputs = Enum.flat_map(tiles, &["-i", relative!(&1.path, root)])

    args =
      ["-y", "-loglevel", "error"] ++
        inputs ++
        [
          "-filter_complex",
          filter_graph(tiles, width, height, skip_ms),
          "-map",
          "[out]",
          "-c:v",
          "libx264",
          "-preset",
          "veryfast",
          "-crf",
          "23",
          "-pix_fmt",
          "yuv420p",
          "-movflags",
          "+faststart",
          Path.basename(output)
        ]

    {command, prefix} = ffmpeg(root)

    case System.cmd(command, prefix ++ args, cd: root, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "ffmpeg exited with #{status}:\n#{output}"
    end
  end

  defp relative!(path, root) do
    path = Path.expand(path)

    case Path.relative_to(path, root) do
      ^path -> raise ArgumentError, "#{path} is not under #{root}"
      relative -> relative
    end
  end

  # Per input: hold the background until the device opened, fit it into its
  # rectangle, then stack every tile onto a canvas-sized background.
  defp filter_graph(tiles, width, height, skip_ms) do
    count = length(tiles)

    tile_filters =
      tiles
      |> Enum.with_index()
      |> Enum.map(fn {%{offset_ms: offset_ms, rect: {_x, _y, w, h}}, i} ->
        "[#{i}:v]fps=#{@fps}," <>
          "tpad=start_duration=#{offset_ms / 1000}:start_mode=add:color=#{@background}," <>
          "scale=#{w}:#{h}:force_original_aspect_ratio=decrease," <>
          "pad=#{w}:#{h}:(ow-iw)/2:(oh-ih)/2:color=#{@background},setsar=1[t#{i}]"
      end)

    labels = Enum.map_join(0..(count - 1), &"[t#{&1}]")
    layout = Enum.map_join(tiles, "|", fn %{rect: {x, y, _w, _h}} -> "#{x}_#{y}" end)

    # A canvas-sized background underneath guarantees the output size even
    # if the tiles leave gaps.
    stack =
      "#{labels}xstack=inputs=#{count}:layout=#{layout}:fill=#{@background}[stack];" <>
        "color=c=#{@background}:s=#{width}x#{height}:r=#{@fps}[bg];" <>
        "[bg][stack]overlay=0:0:shortest=1," <>
        "trim=start=#{skip_ms / 1000},setpts=PTS-STARTPTS[out]"

    Enum.join(tile_filters ++ [stack], ";")
  end

  defp ffmpeg(root) do
    case System.find_executable("ffmpeg") do
      nil ->
        {"docker",
         ["run", "--rm", "--network", "none", "-v", "#{root}:/work", "-w", "/work", @docker_image]}

      path ->
        {path, []}
    end
  end
end
