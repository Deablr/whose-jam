defmodule WhoseJamWeb.E2E.Video do
  @moduledoc """
  Composites per-device browser recordings into one video with ffmpeg.

  Every tile is scaled to fit its rectangle on the canvas (letterboxed in the
  game's ink colour), delayed by the moment its device opened so all screens
  stay in sync, and stacked with ffmpeg's `xstack` filter into an H.264 MP4.

  Uses `ffmpeg` from the `PATH` when there is one, otherwise the pinned
  `linuxserver/ffmpeg` Docker image (Docker is already required for the
  e2e suite's database).
  """

  @typedoc "One recording: its file, when its device opened, and where it goes on the canvas."
  @type tile :: %{
          path: Path.t(),
          offset_ms: non_neg_integer(),
          rect: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
        }

  @docker_image "linuxserver/ffmpeg:version-7.1-cli"
  @background "0x120726"
  @fps 25

  @doc """
  Writes the tiles, laid out on a `{width, height}` canvas, to `output` (an
  `.mp4`). Every tile path must sit under `Path.dirname(output)`. Raises if
  ffmpeg fails.
  """
  @spec compose!([tile()], {pos_integer(), pos_integer()}, Path.t()) :: :ok
  def compose!(tiles, {width, height}, output) do
    root = Path.dirname(output)
    inputs = Enum.flat_map(tiles, &["-i", relative!(&1.path, root)])

    args =
      ["-y", "-loglevel", "error"] ++
        inputs ++
        [
          "-filter_complex",
          filter_graph(tiles, width, height),
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
  defp filter_graph(tiles, width, height) do
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
        "[bg][stack]overlay=0:0:shortest=1[out]"

    Enum.join(tile_filters ++ [stack], ";")
  end

  defp ffmpeg(root) do
    case System.find_executable("ffmpeg") do
      nil -> {"docker", ["run", "--rm", "-v", "#{root}:/work", "-w", "/work", @docker_image]}
      path -> {path, []}
    end
  end
end
