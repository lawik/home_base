defmodule Home.Test.Png do
  @moduledoc false
  # A solid-colour RGB PNG, for images whose pixels a test can check.

  def solid(w, h, {r, g, b}) do
    row = <<0>> <> :binary.copy(<<r, g, b>>, w)
    idat = :zlib.compress(:binary.copy(row, h))

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <> chunk("IDAT", idat) <> chunk("IEND", "")
  end

  # Incompressible pixels, for an image of a given size on disk.
  def noise(w, h) do
    rows = for _ <- 1..h, into: <<>>, do: <<0>> <> :crypto.strong_rand_bytes(w * 3)

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(rows)) <> chunk("IEND", "")
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
end

defmodule Home.Test.ImageViewport do
  @moduledoc false
  # A row of 40x40 images from `opts[:sources]` (any emerge image source) on black.
  use Emerge

  @impl Viewport
  def mount(opts) do
    config = %Emerge.Config{runtime: Keyword.get(opts, :runtime, []), assets: [otp_app: :emerge]}
    {:ok, %{sources: Keyword.fetch!(opts, :sources)}, config}
  end

  @impl Viewport
  def render(%{sources: sources}) do
    row(
      [width(fill()), height(fill()), Background.color(color_rgb(0, 0, 0))],
      for {src, i} <- Enum.with_index(sources) do
        image([width(px(40)), height(px(40)), key(i)], src)
      end
    )
  end

  @impl Viewport
  def handle_info({:sources, sources}, state),
    do: {:noreply, Viewport.rerender(%{state | sources: sources})}
end
