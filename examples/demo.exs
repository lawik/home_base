# Shortcuts for the README walkthrough. `scripts/node.sh` loads this into every node.

defmodule Demo.Hello do
  @moduledoc """
  A tiny emerge app for the walkthrough: says which node it runs on and counts seconds,
  so you can see it keep running when it moves to another display.
  """
  use Emerge

  @impl Viewport
  def mount(opts) do
    :timer.send_interval(1_000, :tick)
    state = %{title: Keyword.get(opts, :title, "Hello"), seconds: 0}
    {:ok, state, %Emerge.Config{runtime: Keyword.get(opts, :runtime, [])}}
  end

  @impl Viewport
  def render(state) do
    column(
      [
        width(fill()),
        height(fill()),
        padding(16),
        spacing(8),
        Background.color(color(:indigo, 800)),
        Font.color(color(:slate, 50))
      ],
      [
        el([Font.size(24)], text(state.title)),
        el([Font.size(14)], text("running on #{node()}")),
        el([Font.size(14)], text("for #{state.seconds} s"))
      ]
    )
  end

  @impl Viewport
  def handle_info(:tick, state),
    do: {:noreply, Viewport.rerender(%{state | seconds: state.seconds + 1})}
end

defmodule Demo do
  @moduledoc false

  @doc "The node whose name ends in `name`: `Demo.node!(:kitchen)` -> `:\"home-kitchen@127.0.0.1\"`."
  def node!(name) do
    name = to_string(name)

    Enum.find([Node.self() | Node.list()], fn n ->
      n |> short() |> String.ends_with?(name)
    end) || raise "no #{name} node in the cluster (yet?)"
  end

  @doc "Print every capability in the cluster: hardware, status and who holds it."
  def caps do
    for info <- Home.Registry.list() do
      {node, id} = info.ref

      holders =
        Enum.map_join(info.held_by, "; ", fn h ->
          "#{short(Kernel.node(h.holder))}: #{h.purpose}"
        end)

      [
        String.pad_trailing("#{short(node)}/#{id}", 20),
        String.pad_trailing("#{info.cap.kind}", 10),
        String.pad_trailing("#{info.cap.availability}", 11),
        String.pad_trailing("hw #{info.hardware}", 7),
        String.pad_trailing("#{info.status}", 7),
        holders
      ]
      |> Enum.join(" ")
      |> String.trim_trailing()
      |> IO.puts()
    end

    :ok
  end

  @doc """
  Save what a (headless) display shows as a PNG. Briefly leases the display (shared)
  to reach its compositor.
  """
  def snapshot({_node, _id} = display, path) do
    {:ok, lease} = Home.Lease.acquire(display, purpose: "snapshot")

    try do
      case Home.Render.Compositor.frame(lease.endpoint) do
        nil -> {:error, :no_frame}
        frame -> with :ok <- File.write(path, png(frame)), do: {:ok, path}
      end
    after
      Home.Lease.release(lease)
    end
  end

  # RGBA frame -> PNG (8-bit RGBA, no filtering).
  defp png(%{coded_width: w, coded_height: h, storage: %{data: data, planes: [plane | _]}}) do
    rows =
      for y <- 0..(h - 1) do
        [0, binary_part(data, plane.offset + y * plane.stride, w * 4)]
      end

    chunk = fn type, body ->
      body = IO.iodata_to_binary(body)
      [<<byte_size(body)::32>>, type, body, <<:erlang.crc32([type, body])::32>>]
    end

    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      chunk.("IHDR", <<w::32, h::32, 8, 6, 0, 0, 0>>),
      chunk.("IDAT", :zlib.compress(rows)),
      chunk.("IEND", "")
    ])
  end

  defp short(node), do: node |> Atom.to_string() |> String.split("@") |> hd()
end
