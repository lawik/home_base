defmodule Home.RenderDrmTest do
  @moduledoc """
  A forwarded app on a real DRM/KMS output, with real input: the display node's
  renderer drives `/dev/dri/card0` (CPU raster presentation, no GPU needed), the test
  reads back what the CRTC scans out with plain DRM ioctls (`drm/drmgrab.c`, not
  through emerge), and taps a uinput touchscreen (`drm/utouch.c`) that emerge's libinput
  picks up, so the press goes evdev -> libinput -> B's hit-testing -> A's Solve event.

  Needs root, a free `/dev/dri/card0` (no other DRM master), `/dev/uinput`, gcc, and an
  emerge NIF built from source with a DRM backend:

      HOME_EMERGE_BACKENDS='[wayland: [:opengl], drm: [:raster], headless: [:opengl]]' \\
        EMERGE_SKIA_BUILD=true mix test --only drm test/render_drm_test.exs
  """
  use Home.Test.ClusterCase, async: false

  alias Home.Test.Render

  @moduletag :drm
  @moduletag timeout: 120_000

  @card "/dev/dri/card0"
  @button {20, 20}
  @bg {150, 100}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "home_drm_tools_#{System.pid()}")
    File.mkdir_p!(dir)
    src = Path.join(__DIR__, "support/drm")

    for tool <- ["drmgrab", "utouch"] do
      {_, 0} =
        System.cmd("gcc", ["-O2", "-o", Path.join(dir, tool), Path.join(src, tool <> ".c")],
          stderr_to_stdout: true
        )
    end

    on_exit(fn -> File.rm_rf(dir) end)
    %{tools: dir}
  end

  setup %{tools: tools} do
    # The touchscreen first, so it is there when the renderer's libinput starts.
    touch =
      Port.open({:spawn_executable, Path.join(tools, "utouch")}, [
        :binary,
        :use_stdio,
        {:line, 256}
      ])

    assert_receive {^touch, {:data, {:eol, "ready"}}}, 5_000

    display = %{
      id: "disp0",
      kind: :display,
      adapter:
        {Home.Adapters.Display,
         output: %Emerge.Config.DRM{card: @card}, renderer: %Emerge.Config.Renderer{api: :raster}}
    }

    [{a, _}, {b, _}] =
      start_cluster("m8d",
        a: [device_id: "laptop", capabilities: []],
        b: [device_id: "kitchen", capabilities: [display]]
      )

    on_exit(fn -> if Port.info(touch), do: Port.close(touch) end)
    %{a: a, b: b, touch: touch, grab: Path.join(tools, "drmgrab")}
  end

  # What the CRTC scans out, read with DRM ioctls: {fb_id, %{{x, y} => "RRGGBB"}}.
  defp scanout(grab, points) do
    args = [@card | Enum.flat_map(points, fn {x, y} -> [to_string(x), to_string(y)] end)]
    # A page flip can retire the framebuffer between the two ioctls; try again.
    case System.cmd(grab, args, stderr_to_stdout: true) do
      {out, 0} ->
        ["fb=" <> fb | lines] = String.split(out, "\n", trim: true)
        [fb | _] = String.split(fb)

        pixels =
          Map.new(lines, fn line ->
            [xy, rgb] = String.split(line, "=")
            [x, y] = xy |> String.split(",") |> Enum.map(&String.to_integer/1)
            {{x, y}, rgb}
          end)

        {fb, pixels}

      _ ->
        Process.sleep(20)
        scanout(grab, points)
    end
  end

  defp await_scanout(grab, point, rgb) do
    eventually(fn -> elem(scanout(grab, [point]), 1)[point] == rgb end, 10_000)
  end

  defp touch_at(touch, {x, y}) do
    Port.command(touch, "tap #{x} #{y}\n")
    assert_receive {^touch, {:data, {:eol, "tapped " <> _}}}, 5_000
  end

  test "an app on A is scanned out on B's DRM output and takes touch input", ctx do
    %{a: a, b: b, touch: touch, grab: grab} = ctx
    {console_fb, _} = scanout(grab, [@bg])

    {session, app} = rpc(a, Render, :show, [{b, "disp0"}])
    await_scanout(grab, @bg, "ff0000")
    {fb, pixels} = scanout(grab, [@bg, {10, 10}])
    assert fb != console_fb
    assert pixels[{10, 10}] == "00ff00"
    IO.puts("\nDRM: scanout fb #{fb} (console was #{console_fb}): #{inspect(pixels)}")

    # A state change on A reaches the scanout.
    :ok = rpc(a, Solve, :dispatch, [app, :counter, :increment, nil])
    await_scanout(grab, @bg, "0000ff")

    # A touch on the button: kernel input device -> B's renderer -> A's app.
    Process.sleep(1_000)
    touch_at(touch, @button)
    assert eventually(fn -> rpc(a, Render, :count, [app]) == 2 end, 5_000)
    await_scanout(grab, @bg, "ff0000")

    :ok = rpc(a, Home.Render, :stop, [session])
  end
end
