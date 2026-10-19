defmodule Home.RenderAssetsTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Test.{Png, Render}

  @moduletag timeout: 120_000

  @green {0, 255, 0, 255}
  @blue {0, 0, 255, 255}
  @red {255, 0, 0, 255}
  @black {0, 0, 0, 255}

  defp display,
    do: %{id: "disp0", kind: :display, adapter: Home.Adapters.Display, meta: %{w: 200, h: 60}}

  setup do
    [{a, _}, {b, _}] =
      start_cluster("m8a",
        # Anything over 4 KB goes over TCP; B receives on 41930..41939.
        a: [device_id: "laptop", capabilities: [], render: [asset_tcp_threshold: 4096]],
        b: [
          device_id: "kitchen",
          capabilities: [display()],
          render: [asset_ports: 41_930..41_939]
        ]
      )

    %{a: a, b: b}
  end

  defp pixel(b, i), do: rpc(b, Render, :pixel, ["disp0", {20 + 40 * i, 20}])

  defp cached(b) do
    rpc(b, File, :ls!, [Path.join([rpc(b, Home, :data_dir, []), "render", "assets"])])
  end

  test "runtime paths, preloaded ids and large files reach the display by hash", %{a: a, b: b} do
    dir = Path.join(rpc(a, Home, :data_dir, []), "photos")
    File.mkdir_p!(dir)

    green = Path.join(dir, "green.png")
    File.write!(green, Png.solid(40, 40, {0, 255, 0}))
    big = Path.join(dir, "big.png")
    big_png = Png.noise(120, 120)
    File.write!(big, big_png)
    assert byte_size(big_png) > 4096

    blue_id = rpc(a, Home.Render.Assets, :put_image, [Png.solid(40, 40, {0, 0, 255})])

    svg =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">) <>
        ~s(<rect width="40" height="40" fill="#ff0000"/></svg>)

    red_id = rpc(a, Home.Render.Assets, :put_image, [svg])
    assert {:id, "img_" <> _} = red_id

    sources = [{:path, green}, blue_id, red_id, {:path, big}]

    {:ok, app} =
      rpc(a, Home.Render, :show, [{Home.Test.ImageViewport, sources: sources}, [on: {b, "disp0"}]])

    assert eventually(fn -> pixel(b, 0) == @green end, 10_000)
    assert eventually(fn -> pixel(b, 1) == @blue end, 10_000)
    assert eventually(fn -> pixel(b, 2) == @red end, 10_000)
    # The noise image (sent over TCP) is drawn: not the black background.
    assert eventually(fn -> pixel(b, 3) not in [@black, nil] end, 10_000)

    for data <- [File.read!(green), big_png, svg],
        do: assert(Home.Render.Compositor.hash(data) in cached(b))

    # Replacing the file at the runtime path shows the new image.
    tmp = green <> ".new"
    File.write!(tmp, Png.solid(40, 40, {0, 0, 255}))
    File.rename!(tmp, green)
    viewport = rpc(a, Home.Render.Session, :viewport, [app])
    send(viewport, {:sources, sources})
    assert eventually(fn -> pixel(b, 0) == @blue end, 10_000)

    :ok = rpc(a, Home.Render, :stop, [app])
  end

  test "AssetTransfer: hash and token are checked", %{b: b} do
    dir = Path.join(rpc(b, Home, :data_dir, []), "xfer")
    data = :crypto.strong_rand_bytes(100_000)
    src = Path.join(dir, "src")
    File.mkdir_p!(dir)
    File.write!(src, data)
    hash = Home.Render.Compositor.hash(data)

    {:ok, {ip, port, token}} =
      rpc(b, Home.Render.AssetTransfer, :listen, [hash, byte_size(data), Path.join(dir, "ok")])

    assert port in 41_930..41_939
    assert :ok = Home.Render.AssetTransfer.send_file({ip, port, token}, src)
    assert File.read!(Path.join(dir, "ok")) == data

    # Wrong hash: rejected, nothing written.
    {:ok, receiver} =
      rpc(b, Home.Render.AssetTransfer, :listen, [
        String.duplicate("0", 64),
        byte_size(data),
        Path.join(dir, "bad")
      ])

    assert {:error, :rejected} = Home.Render.AssetTransfer.send_file(receiver, src)
    refute File.exists?(Path.join(dir, "bad"))

    # Wrong token.
    {:ok, {ip, port, _}} =
      rpc(b, Home.Render.AssetTransfer, :listen, [hash, byte_size(data), Path.join(dir, "tok")])

    assert {:error, _} = Home.Render.AssetTransfer.send_file({ip, port, "0123456789abcdef"}, src)
    refute File.exists?(Path.join(dir, "tok"))
  end
end
