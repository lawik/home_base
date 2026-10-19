defmodule Home.V4L2CameraTest do
  # A real V4L2 device: a v4l2loopback node fed by ffmpeg's test pattern. Needs root (to
  # load the module) and ffmpeg; excluded by default, run with `mix test --only v4l2`.
  use Home.Test.ClusterCase, async: false

  alias Home.Test.{MediaHelpers, Render}

  @moduletag :v4l2
  @moduletag timeout: 120_000

  @device "/dev/video42"

  setup do
    unless File.exists?(@device) do
      {_, 0} =
        System.cmd("modprobe", [
          "v4l2loopback",
          "video_nr=42",
          "card_label=home_test",
          "exclusive_caps=1"
        ])
    end

    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg not found")

    port =
      Port.open({:spawn_executable, ffmpeg}, [
        :binary,
        :exit_status,
        args:
          ~w(-hide_banner -loglevel error -nostdin -re -f lavfi -i testsrc2=size=320x240:rate=30
             -pix_fmt yuv420p -f v4l2 #{@device})
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)]) end)
    # The loopback device has no format until the writer has started.
    Process.sleep(1_000)

    camera = %{
      id: "cam0",
      kind: :video_in,
      availability: :on_request,
      adapter: Home.Adapters.Video.Camera,
      meta: %{device: @device, fps: 30}
    }

    display = %{
      id: "disp0",
      kind: :display,
      adapter: Home.Adapters.Display,
      meta: %{w: 320, h: 240}
    }

    [{a, _}, {b, _}] =
      start_cluster("m5cam",
        a: [capabilities: [camera], media: [ports: 41_600..41_619]],
        b: [capabilities: [display], media: [ports: 41_620..41_639]]
      )

    for n <- [a, b] do
      eventually(fn -> length(rpc(n, Home.Registry, :list, [])) == 2 end)
      rpc(n, MediaHelpers, :preload)
    end

    %{a: a, b: b}
  end

  test "a V4L2 camera on A shown on B", %{a: a, b: b} do
    {:ok, video} = rpc(a, Home.Render, :show_video, [{a, "cam0"}, [on: {b, "disp0"}]])

    assert [%{status: :leased, hardware: :on}] =
             rpc(a, Home.Registry, :list, [[kind: :video_in, node: a]])

    # testsrc2 is colourful and moving: B's picture is not black and changes.
    pixel = fn -> rpc(b, Render, :pixel, ["disp0", {100, 100}]) end
    first = eventually(fn -> (p = pixel.()) not in [nil, {0, 0, 0, 255}] and p end, 10_000)
    eventually(fn -> pixel.() != first end, 5_000)

    :ok = rpc(a, Home.Render, :stop, [video])

    eventually(fn ->
      match?(
        [%{status: :idle, hardware: :off}],
        rpc(a, Home.Registry, :list, [[kind: :video_in]])
      )
    end)

    eventually(fn -> rpc(a, MediaHelpers, :media_children) == 0 end)
  end
end
