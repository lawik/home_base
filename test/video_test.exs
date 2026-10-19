defmodule Home.VideoTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Adapters.Video.SynthCamera
  alias Home.Test.{MediaHelpers, Render, VideoHelpers}

  @moduletag timeout: 120_000

  @video {320, 240}
  @center {160, 120}
  @hd {1280, 720}

  defp camera(id \\ "cam0", {w, h} \\ @video, notify) do
    %{
      id: id,
      kind: :video_in,
      availability: :on_request,
      adapter: SynthCamera,
      meta: %{notify: notify, w: w, h: h, fps: 30}
    }
  end

  defp display(id \\ "disp0", {w, h} \\ @video),
    do: %{id: id, kind: :display, adapter: Home.Adapters.Display, meta: %{w: w, h: h}}

  setup do
    [{a, apeer}, {b, bpeer}, {c, _}] =
      start_cluster("m5v",
        a: [
          device_id: "laptop",
          capabilities: [camera(self()), camera("cam720", @hd, self())],
          media: [ports: 41_500..41_519]
        ],
        b: [
          device_id: "kitchen",
          capabilities: [display(), display("disp720", @hd)],
          media: [ports: 41_520..41_539]
        ],
        c: [device_id: "server", capabilities: [], media: [ports: 41_540..41_559]]
      )

    for n <- [a, b, c] do
      eventually(fn -> length(rpc(n, Home.Registry, :list, [])) == 4 end)
      rpc(n, MediaHelpers, :preload)
    end

    %{a: a, b: b, c: c, apeer: apeer, bpeer: bpeer}
  end

  defp show_video(ctx) do
    %{a: a, b: b, c: c} = ctx
    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "cam0"}, [on: {b, "disp0"}]])
    assert_receive {:home_hw, "cam0", :on}, 5_000
    video
  end

  test "camera on A shown on B's display, started from C", ctx do
    %{a: a, b: b, c: c} = ctx
    video = show_video(ctx)
    assert node(video) == c
    assert rpc(b, Render, :shown, ["disp0"]) == video

    # Both leases are held by the video's media session.
    for ref <- [{a, "cam0"}, {b, "disp0"}], do: assert(%{status: :leased} = cap(c, ref))

    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 3_000])
    {sent, shown} = collect_frames()
    latencies = latencies(sent, shown)
    report("camera A -> display B", latencies, sent)

    # Most frames get through and are drawn with the right number.
    assert length(latencies) >= 60
    assert p95(latencies) <= 250

    # Stream events reach the activity store.
    eventually(fn -> rpc(c, Home.Activity, :last, [{a, "cam0"}, :video_in]) end)

    # Stopping turns the camera off and releases both leases.
    :ok = rpc(c, Home.Render, :stop, [video])
    assert_receive {:home_hw, "cam0", :off}, 5_000

    for ref <- [{a, "cam0"}, {b, "disp0"}],
        do: eventually(fn -> match?(%{status: :idle}, cap(c, ref)) end)

    eventually(fn -> Enum.all?([a, b, c], &(rpc(&1, MediaHelpers, :media_children) == 0)) end)
    assert rpc(b, Render, :shown, ["disp0"]) == nil
  end

  test "720p camera at 30 fps, 3 Mbps", ctx do
    %{a: a, b: b, c: c} = ctx
    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "cam720"}, [on: {b, "disp720"}]])
    assert_receive {:home_hw, "cam720", :on}, 5_000

    Node.spawn(b, VideoHelpers, :watch, [self(), "disp720", @hd, 3_000])
    {sent, shown} = collect_frames()
    latencies = latencies(sent, shown)
    report("720p camera A -> display B", latencies, sent)
    assert length(latencies) >= 45
    assert p95(latencies) <= 250

    :ok = rpc(c, Home.Render, :stop, [video])
    assert_receive {:home_hw, "cam720", :off}, 5_000
  end

  test "a camera already in use: show_video fails and leaves the display as it was", ctx do
    %{a: a, b: b, c: c} = ctx
    holder = Node.spawn(c, Process, :sleep, [:infinity])
    {:ok, _lease} = rpc(c, Home.Lease, :acquire, [{a, "cam0"}, [for: holder]])

    assert {:error, _} = rpc(c, Home.Render, :show_video, [{a, "cam0"}, [on: {b, "disp0"}]])
    assert rpc(b, Render, :shown, ["disp0"]) == nil
    eventually(fn -> match?(%{status: :idle}, cap(c, {b, "disp0"})) end)
    assert rpc(c, MediaHelpers, :media_children) == 0
    Process.exit(holder, :kill)
  end

  test "display node dies: the video session ends and the camera closes", ctx do
    %{a: a, c: c, bpeer: bpeer} = ctx
    video = show_video(ctx)
    ref = Process.monitor(video)
    assert_receive {:synth_frame, _, _, _}, 5_000

    stop(bpeer)

    assert_receive {:DOWN, ^ref, :process, ^video, {:shutdown, {:media, _}}}, 5_000
    assert_receive {:home_hw, "cam0", :off}, 5_000

    eventually(fn -> match?(%{status: :idle, hardware: :off}, cap(a, {a, "cam0"})) end)

    eventually(fn -> rpc(a, MediaHelpers, :media_children) == 0 end)
    eventually(fn -> rpc(c, MediaHelpers, :media_children) == 0 end)
  end

  test "camera node dies: the video session ends and B's display is free", ctx do
    %{b: b, c: c, apeer: apeer} = ctx
    video = show_video(ctx)
    ref = Process.monitor(video)
    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 500])
    assert_receive {:shown, {^b, "disp0"}, _n, _t}, 5_000

    stop(apeer)

    assert_receive {:DOWN, ^ref, :process, ^video, {:shutdown, {:media, _}}}, 5_000
    eventually(fn -> rpc(b, Render, :shown, ["disp0"]) == nil end)

    eventually(fn -> match?(%{status: :idle}, cap(b, {b, "disp0"})) end)

    eventually(fn -> rpc(b, MediaHelpers, :media_children) == 0 end)
    eventually(fn -> rpc(c, MediaHelpers, :media_children) == 0 end)
  end

  test "video goes on top of a forwarded app; the app is back when it stops", ctx do
    %{b: b, c: c} = ctx
    {app_session, _app} = rpc(c, Render, :show, [{b, "disp0"}])
    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", {150, 100}, &VideoHelpers.red?/1])

    video = show_video(ctx)
    assert rpc(b, Render, :shown, ["disp0"]) == video
    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 1_000])
    {sent, shown} = collect_frames()
    assert length(latencies(sent, shown)) >= 15

    :ok = rpc(c, Home.Render, :stop, [video])
    assert_receive {:home_hw, "cam0", :off}, 5_000
    assert rpc(b, Render, :shown, ["disp0"]) == app_session
    assert rpc(b, VideoHelpers, :await_pixel, ["disp0", {150, 100}, &VideoHelpers.red?/1])
  end

  describe "pixel forwarding" do
    test "an emerge app on A rendered to pixels shows on B, with input flowing back", ctx do
      %{a: a, b: b} = ctx
      app = {Home.Test.PixelApp, [test: self()]}
      {:ok, pixels} = rpc(a, Home.Render, :show_pixels, [app, [on: {b, "disp0"}]])
      assert rpc(b, Render, :shown, ["disp0"]) == pixels
      assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @center, &VideoHelpers.red?/1])

      # Each click on B flips the colour on A, which comes back as pixels.
      rounds =
        for i <- 1..6 do
          t0 = rpc(b, VideoHelpers, :click, ["disp0", {100, 80}])

          assert_receive {:app_input, ^a, {:pointer_button, {:left, :press, [], {100.0, 80.0}}},
                          t_app},
                         5_000

          colour = if rem(i, 2) == 1, do: &VideoHelpers.blue?/1, else: &VideoHelpers.red?/1
          t1 = rpc(b, VideoHelpers, :await_pixel, ["disp0", @center, colour])
          assert t1, "click #{i} not shown on B"
          Process.sleep(100)
          {(t_app - t0) / 1_000, (t1 - t0) / 1_000}
        end

      {input, round_trip} = Enum.unzip(rounds)

      IO.puts(
        "\npixel forwarding A -> B: input B -> A median #{percentile(input, 0.5)} ms, " <>
          "click on B to new pixels on B median #{percentile(round_trip, 0.5)} ms, " <>
          "max #{Enum.max(round_trip)} ms"
      )

      assert percentile(round_trip, 0.5) <= 250

      # Stopping stops the app and frees B's display.
      viewport = rpc(a, :sys, :get_state, [pixels]).app
      :ok = rpc(a, Home.Render, :stop, [pixels])
      eventually(fn -> not rpc(a, Process, :alive?, [viewport]) end)
      assert rpc(b, Render, :shown, ["disp0"]) == nil

      eventually(fn -> match?(%{status: :idle}, cap(a, {b, "disp0"})) end)

      eventually(fn -> Enum.all?([a, b], &(rpc(&1, MediaHelpers, :media_children) == 0)) end)
    end

    test "a non-emerge app sends its own frames and gets input", ctx do
      %{a: a, b: b} = ctx
      app = {Home.Test.PlainPixelApp, [test: self()]}
      {:ok, pixels} = rpc(a, Home.Render, :show_pixels, [app, [on: {b, "disp0"}]])
      assert rpc(b, VideoHelpers, :await_pixel, ["disp0", @center, &VideoHelpers.green?/1])

      rpc(b, VideoHelpers, :click, ["disp0", {10, 20}])
      assert_receive {:plain_input, ^a, {:cursor_button, {:left, 1, [], {10.0, 20.0}}}}, 5_000

      # The app going away ends the session.
      ref = Process.monitor(pixels)
      Process.exit(rpc(a, :sys, :get_state, [pixels]).app, :kill)
      assert_receive {:DOWN, ^ref, :process, _, {:shutdown, {:app, :killed}}}, 5_000
      eventually(fn -> rpc(b, Render, :shown, ["disp0"]) == nil end)
    end
  end

  # A capability's registry entry as `node` sees it.
  defp cap(node, ref), do: Enum.find(rpc(node, Home.Registry, :list, []), &(&1.ref == ref))

  ## Measuring

  # Frame numbers the camera sent (with send times) and first shown on B, until the
  # watcher is done.
  defp collect_frames(sent \\ %{}, shown \\ %{}) do
    receive do
      {:synth_frame, _cap, n, t} -> collect_frames(Map.put(sent, n, t), shown)
      {:shown, _cap, n, t} -> collect_frames(sent, Map.put_new(shown, n, t))
      {:watch_done, _cap, _polls} -> {sent, shown}
    after
      10_000 -> flunk("watcher did not finish")
    end
  end

  defp latencies(sent, shown) do
    for {n, t} <- shown, Map.has_key?(sent, n), do: (t - sent[n]) / 1_000
  end

  defp p95(values), do: percentile(values, 0.95)

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, round(p * (length(sorted) - 1))))
  end

  defp report(label, latencies, sent) do
    IO.puts(
      "\n#{label}: #{length(latencies)} of #{map_size(sent)} frames shown, latency " <>
        "median #{percentile(latencies, 0.5)} ms, p95 #{p95(latencies)} ms, " <>
        "max #{Enum.max(latencies, fn -> nil end)} ms"
    )
  end
end
