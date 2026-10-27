defmodule Home.VideoNegotiationTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Adapters.Video.SynthCamera
  alias Home.Test.{DeclaredCamera, MediaHelpers, VideoHelpers}

  @moduletag timeout: 120_000

  # B's "hardware" decoder (FFmpeg under the name) takes up to 640×480; C has only the
  # software decoder.
  @small_hw [element: :software, name: "small hw", max_size: {640, 480}]

  defp camera(id, {w, h}, notify, adapter \\ SynthCamera, meta \\ %{}) do
    %{
      id: id,
      kind: :video_in,
      availability: :on_request,
      adapter: adapter,
      meta: Map.merge(%{notify: notify, w: w, h: h, fps: 30}, meta)
    }
  end

  defp display(id, {w, h}),
    do: %{id: id, kind: :display, adapter: Home.Adapters.Display, meta: %{w: w, h: h}}

  setup do
    # A camera whose stream is fixed: 1280×720, high profile.
    fixed = [
      %{
        element: :software,
        hardware: true,
        name: "fixed",
        profiles: [:high],
        sizes: [{1280, 720}],
        size: {1280, 720},
        fps: 30,
        max_fps: 30
      }
    ]

    [{a, _}, {b, _}, {c, _}] =
      start_cluster("vneg",
        a: [
          device_id: "cameras",
          capabilities: [
            camera("cam320", {320, 240}, self()),
            camera("cam720", {1280, 720}, self()),
            camera("fixed", {1280, 720}, self(), DeclaredCamera, %{video: fixed})
          ],
          media: [ports: 41_600..41_619]
        ],
        b: [
          device_id: "small",
          capabilities: [display("disp0", {640, 480})],
          media: [ports: 41_620..41_639],
          video: [decoders: [@small_hw]]
        ],
        c: [
          device_id: "big",
          capabilities: [display("big", {1280, 720})],
          media: [ports: 41_640..41_659]
        ]
      )

    for n <- [a, b, c] do
      eventually(fn -> length(rpc(n, Home.Registry, :list, [])) == 5 end)
      rpc(n, MediaHelpers, :preload)
    end

    %{a: a, b: b, c: c}
  end

  defp video_path(node, video) do
    media = rpc(node, Home.Render.Video, :media, [video])
    rpc(node, Home.Media.Session, :info, [media]).video
  end

  defp frames_shown(node, cap_id, size, ms) do
    Node.spawn(node, VideoHelpers, :watch, [self(), cap_id, size, ms])
    count_shown(MapSet.new())
  end

  defp count_shown(shown) do
    receive do
      {:shown, _cap, n, _t} -> count_shown(MapSet.put(shown, n))
      {:watch_done, _cap, _polls} -> MapSet.size(shown)
      {:synth_frame, _cap, _n, _t} -> count_shown(shown)
    after
      10_000 -> flunk("watcher did not finish")
    end
  end

  test "capabilities publish what they encode and decode", %{a: a, b: b, c: c} do
    support = Map.new(rpc(c, Home.Media.Video, :list, []), &{&1.ref, &1})

    assert [%{name: "x264", hardware: false, size: {320, 240}}] = support[{a, "cam320"}].encode
    assert [%{name: "fixed", profiles: [:high]}] = support[{a, "fixed"}].encode

    assert [%{name: "small hw", hardware: true}, %{name: "FFmpeg", hardware: false}] =
             support[{b, "disp0"}].decode

    assert [%{name: "FFmpeg"}] = support[{c, "big"}].decode
  end

  test "a camera the display's hardware takes is decoded there", %{a: a, b: b, c: c} do
    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "cam320"}, [on: {b, "disp0"}]])

    path = video_path(c, video)
    assert path.size == {320, 240}
    assert %{{^b, "disp0"} => %{name: "small hw"}} = path.decoders

    assert frames_shown(b, "disp0", {320, 240}, 2_000) >= 30
    :ok = rpc(c, Home.Render, :stop, [video])
  end

  test "x264 scales a camera down to what the hardware takes", %{a: a, b: b, c: c} do
    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "cam720"}, [on: {b, "disp0"}]])

    path = video_path(c, video)
    assert path.size == {640, 360}
    assert path.level == 30

    # SynthVideo's code blocks are sized for the camera's frame, before scaling.
    assert frames_shown(b, "disp0", {1280, 720}, 2_000) >= 30
    :ok = rpc(c, Home.Render, :stop, [video])
  end

  test "a stream the hardware can't take isn't shown, unless the display decodes in software",
       %{a: a, b: b, c: c} do
    assert {:error, {:media_failed, {:no_video_path, [failure]}}} =
             rpc(c, Home.Render, :show_video, [{a, "fixed"}, [on: {b, "disp0"}]])

    assert failure.sink == {b, "disp0"}
    assert failure.decoder == "small hw"
    assert {:size, {1280, 720}, {640, 480}} = failure.reason

    # Nothing left held or running.
    for ref <- [{a, "fixed"}, {b, "disp0"}],
        do: eventually(fn -> match?(%{status: :idle}, cap(c, ref)) end)

    eventually(fn -> Enum.all?([a, b, c], &(rpc(&1, MediaHelpers, :media_children) == 0)) end)

    {:ok, video} =
      rpc(c, Home.Render, :show_video, [{a, "fixed"}, [on: {b, "disp0"}, decoder: :software]])

    path = video_path(c, video)
    assert path.profile == :high
    assert path.size == {1280, 720}
    assert %{{^b, "disp0"} => %{name: "FFmpeg", hardware: false}} = path.decoders

    assert frames_shown(b, "disp0", {1280, 720}, 2_000) >= 30
    :ok = rpc(c, Home.Render, :stop, [video])
  end

  test "a display that can't take a running stream can't join it", %{a: a, b: b, c: c} do
    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "cam720"}, [on: {c, "big"}]])
    assert video_path(c, video).size == {1280, 720}

    assert {:error, {:no_video_path, [%{sink: {^b, "disp0"}, reason: {:size, _, _}}]}} =
             rpc(c, Home.Render, :move, [video, [to: {b, "disp0"}]])

    # Still on the big display, and B's is free.
    assert rpc(c, Home.Render, :target, [video]) == {c, "big"}
    eventually(fn -> match?(%{status: :idle}, cap(c, {b, "disp0"})) end)
    assert frames_shown(c, "big", {1280, 720}, 1_000) >= 15
    :ok = rpc(c, Home.Render, :stop, [video])
  end

  test "check/3 answers without leasing anything", %{a: a, b: b, c: c} do
    assert {:ok, %{size: {640, 360}}} =
             rpc(c, Home.Media.Video, :check, [{a, "cam720"}, [{b, "disp0"}]])

    assert {:error, {:no_video_path, _}} =
             rpc(c, Home.Media.Video, :check, [{a, "fixed"}, [{b, "disp0"}]])

    assert {:ok, %{size: {1280, 720}}} =
             rpc(c, Home.Media.Video, :check, [{a, "fixed"}, [{b, "disp0"}], [decoder: :software]])

    assert {:error, {:not_found, {^a, "nope"}}} =
             rpc(c, Home.Media.Video, :check, [{a, "fixed"}, [{a, "nope"}]])

    assert %{status: :idle} = cap(c, {a, "fixed"})
  end

  defp cap(node, ref), do: Enum.find(rpc(node, Home.Registry, :list, []), &(&1.ref == ref))
end
