defmodule Home.OnvifTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Test.{FakeOnvif, FakeRtspCamera, MediaHelpers, Render, VideoHelpers}

  @moduletag timeout: 180_000
  @moduletag :capture_log

  @video {320, 240}
  @user "admin"
  @password "s3cret pw"

  defp display(id),
    do: %{id: id, kind: :display, adapter: Home.Adapters.Display, meta: %{w: 320, h: 240}}

  setup_all do
    # The fake camera's pipeline runs on this node, whose logger is at debug.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  setup do
    rtsp = start_supervised!({FakeRtspCamera, notify: self(), size: @video, fps: 30})

    onvif =
      start_supervised!(
        {FakeOnvif, rtsp: FakeRtspCamera.url(rtsp), username: @user, password: @password}
      )

    [{a, apeer}, {b, _}, {c, _}] =
      start_cluster("mo",
        a: [device_id: "nvr", capabilities: [], media: [ports: 42_100..42_119]],
        b: [
          device_id: "kitchen",
          capabilities: [display("disp0"), display("disp1")],
          media: [ports: 42_120..42_139]
        ],
        c: [device_id: "hall", capabilities: [display("disp2")], media: [ports: 42_140..42_159]]
      )

    for n <- [a, b, c] do
      eventually(fn -> length(rpc(n, Home.Registry, :list, [])) == 3 end, 15_000)
      rpc(n, MediaHelpers, :preload)
    end

    %{a: a, b: b, c: c, apeer: apeer, rtsp: rtsp, onvif: onvif, info: FakeOnvif.info(onvif)}
  end

  defp add_camera(ctx, opts \\ []) do
    opts = Keyword.merge([username: @user, password: @password, id: "porch"], opts)
    rpc(ctx.a, Home.Onvif, :add_camera, [ctx.info.url, opts], 30_000)
  end

  defp rpc(node, mod, fun, args, timeout), do: :erpc.call(node, mod, fun, args, timeout)

  defp cam(node, id \\ "porch") do
    Enum.find(rpc(node, Home.Registry, :list, [[kind: :video_in]]), &(elem(&1.ref, 1) == id))
  end

  test "unicast WS-Discovery finds the camera", ctx do
    host = "127.0.0.1:#{ctx.info.discovery_port}"

    assert [found] =
             rpc(ctx.a, Home.Onvif, :discover, [[multicast: false, hosts: [host], timeout: 500]])

    assert found.xaddrs == [ctx.info.url]
    assert found.endpoint == ctx.info.endpoint
    assert found.name == "FakeCam"
    assert "dn:NetworkVideoTransmitter" in found.types

    # A discovered camera can be added as is.
    assert {:ok, {_, "cam-127-0-0-1-" <> _}} =
             rpc(ctx.a, Home.Onvif, :add_camera, [found, [username: @user, password: @password]])
  end

  test "periodic discovery reports unconfigured cameras without adding them", ctx do
    %{a: a, b: b} = ctx
    probe = [multicast: false, hosts: ["127.0.0.1:#{ctx.info.discovery_port}"], timeout: 300]
    Node.spawn(b, Home.Test.Holders, :relay, [self(), "onvif"])
    assert_receive {:subscribed, _}, 5_000

    stop_node(a, ctx.apeer)
    start_again(a, onvif: [discover_every: 500, discover: probe])
    await_mesh([a, b, ctx.c])

    assert_receive {:relayed, {:onvif_discovered, ^a, [%{endpoint: endpoint}]}}, 5_000
    assert endpoint == ctx.info.endpoint
    assert rpc(a, Home.Onvif, :list_cameras, []) == []
    assert cam(a) == nil

    # Once configured it is no longer reported.
    {:ok, _} = add_camera(ctx)
    assert_receive {:relayed, {:onvif_discovered, ^a, []}}, 5_000
  end

  test "add_camera checks the credentials and vends the camera on every node", ctx do
    %{a: a, b: b, c: c} = ctx

    assert {:error, :unauthorized} = add_camera(ctx, password: "wrong")
    assert rpc(a, Home.Onvif, :list_cameras, []) == []
    assert cam(a) == nil
    # The camera saw digest-authenticated requests and refused them.
    assert {"GetDeviceInformation", false} in FakeOnvif.requests(ctx.onvif)

    assert {:ok, {^a, "porch"}} = add_camera(ctx)
    assert {:error, :already_exists} = add_camera(ctx)

    for n <- [a, b, c] do
      info = eventually(fn -> cam(n) end)
      assert info.ref == {a, "porch"}
      assert info.cap.availability == :on_request
      assert info.hardware == :off

      assert %{
               codec: :h264,
               w: 320,
               h: 240,
               fps: 30,
               manufacturer: "Home Test",
               model: "FakeCam 1",
               profile: "main",
               source: :onvif
             } = info.cap.meta

      # Credentials stay on the owning node.
      refute inspect(info) =~ @password
    end

    assert [%{id: "porch", username: @user} = listed] = rpc(a, Home.Onvif, :list_cameras, [])
    refute inspect(listed) =~ @password
    refute inspect(rpc(b, Home.Secrets, :snapshot, [])) =~ @password

    # The RTSP stream isn't opened until someone leases the camera.
    assert FakeRtspCamera.stats(ctx.rtsp) == %{active: 0, sessions: 0}
  end

  test "show_video on another node shows the camera; the last release closes the stream",
       ctx do
    %{a: a, b: b, c: c} = ctx
    {:ok, _} = add_camera(ctx)
    eventually(fn -> cam(c) end)
    flush_frames()

    t0 = :os.system_time(:microsecond)
    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "porch"}, [on: {b, "disp0"}]])
    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 4_000])
    {sent, shown} = collect_frames()

    # Only camera frames: an empty display reads as frame 0.
    shown = Map.filter(shown, fn {n, _} -> Map.has_key?(sent, n) end)
    first = shown |> Map.values() |> Enum.min()
    latencies = latencies(sent, shown)

    IO.puts(
      "\nonvif camera -> display: first frame #{div(first - t0, 1_000)} ms after show_video, " <>
        "#{map_size(shown)} distinct frames in 4 s, latency median " <>
        "#{percentile(latencies, 0.5)} ms, p95 #{percentile(latencies, 0.95)} ms"
    )

    # Changing frames, live.
    assert map_size(shown) >= 60
    assert percentile(latencies, 0.95) <= 250
    assert first - t0 <= 2_500_000
    assert %{active: 1, sessions: 1} = FakeRtspCamera.stats(ctx.rtsp)
    assert %{status: :leased, hardware: :on} = cam(c)

    :ok = rpc(c, Home.Render, :stop, [video])
    eventually(fn -> FakeRtspCamera.stats(ctx.rtsp).active == 0 end)
    eventually(fn -> match?(%{status: :idle, hardware: :off}, cam(c)) end)
    eventually(fn -> Enum.all?([a, b, c], &(rpc(&1, MediaHelpers, :media_children) == 0)) end)
  end

  test "fan-out to two displays on two nodes over one RTSP connection", ctx do
    %{a: a, b: b, c: c} = ctx
    {:ok, _} = add_camera(ctx)
    eventually(fn -> cam(c) end)

    {:ok, v1} = rpc(c, Home.Render, :show_video, [{a, "porch"}, [on: {b, "disp0"}]])
    {:ok, v2} = rpc(b, Home.Render, :show_video, [{a, "porch"}, [on: {c, "disp2"}]])

    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 3_000])
    Node.spawn(c, VideoHelpers, :watch, [self(), "disp2", @video, 3_000])
    shown = collect_shown(2)

    for disp <- [{b, "disp0"}, {c, "disp2"}] do
      assert map_size(shown[disp]) >= 45, "#{inspect(disp)}: #{map_size(shown[disp])} frames"
    end

    # Two leases, two media sessions, one camera connection.
    assert %{active: 1, sessions: 1} = FakeRtspCamera.stats(ctx.rtsp)
    assert %{leases: 2} = cam(a)

    # A late joiner gets the cached GOP and shows a picture well within a GOP.
    t0 = :os.system_time(:microsecond)
    {:ok, v3} = rpc(c, Home.Render, :show_video, [{a, "porch"}, [on: {b, "disp1"}]])
    Node.spawn(b, VideoHelpers, :watch, [self(), "disp1", @video, 1_000])
    assert_receive {:shown, {^b, "disp1"}, n, t1} when n > 0, 2_000
    IO.puts("\nonvif late joiner: first frame #{div(t1 - t0, 1_000)} ms after show_video")
    assert %{active: 1, sessions: 1} = FakeRtspCamera.stats(ctx.rtsp)

    :ok = rpc(c, Home.Render, :stop, [v1])
    :ok = rpc(c, Home.Render, :stop, [v3])
    eventually(fn -> match?(%{leases: 1, hardware: :on}, cam(a)) end)
    assert FakeRtspCamera.stats(ctx.rtsp).active == 1

    :ok = rpc(b, Home.Render, :stop, [v2])
    eventually(fn -> FakeRtspCamera.stats(ctx.rtsp).active == 0 end)
    eventually(fn -> match?(%{status: :idle, hardware: :off}, cam(a)) end)
  end

  test "the holder dying releases the lease and closes the stream", ctx do
    %{a: a, c: c} = ctx
    {:ok, _} = add_camera(ctx)
    holder = Node.spawn(c, Process, :sleep, [:infinity])
    {:ok, _lease} = rpc(c, Home.Lease, :acquire, [{a, "porch"}, [for: holder]])
    eventually(fn -> FakeRtspCamera.stats(ctx.rtsp).active == 1 end)

    Process.exit(holder, :kill)
    eventually(fn -> FakeRtspCamera.stats(ctx.rtsp).active == 0 end)
    eventually(fn -> match?(%{status: :idle, hardware: :off}, cam(a)) end)
  end

  test "remove_camera revokes the lease and drops the capability everywhere", ctx do
    %{a: a, b: b, c: c} = ctx
    {:ok, _} = add_camera(ctx)
    eventually(fn -> cam(c) end)

    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "porch"}, [on: {b, "disp0"}]])
    ref = Process.monitor(video)
    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 3_000])
    assert_receive {:shown, {^b, "disp0"}, n, _} when n > 0, 3_000

    assert :ok = rpc(a, Home.Onvif, :remove_camera, ["porch"])

    assert_receive {:DOWN, ^ref, :process, ^video, {:shutdown, {:media, reason}}}, 5_000
    assert inspect(reason) =~ "lease_revoked" or inspect(reason) =~ "capability"

    for n <- [a, b, c], do: eventually(fn -> cam(n) == nil end)
    assert FakeRtspCamera.stats(ctx.rtsp).active == 0
    eventually(fn -> match?(%{status: :idle}, cam_any(b, {b, "disp0"})) end)
    assert rpc(b, Render, :shown, ["disp0"]) == nil
    assert rpc(a, Home.Onvif, :list_cameras, []) == []
    assert {:error, :not_found} = rpc(a, Home.Onvif, :remove_camera, ["porch"])
  end

  test "camera configuration survives a restart of its node", ctx do
    %{a: a, b: b, c: c} = ctx
    {:ok, _} = add_camera(ctx)
    file = Path.join(rpc(a, Home, :data_dir, []), "onvif_cameras")
    assert File.exists?(file)
    assert File.stat!(file).mode |> Bitwise.band(0o077) == 0

    stop_node(a, ctx.apeer)
    for n <- [b, c], do: eventually(fn -> cam(n) == nil end)

    start_again(a)
    await_mesh([a, b, c])
    rpc(a, MediaHelpers, :preload)

    for n <- [a, b, c], do: eventually(fn -> cam(n) end, 10_000)
    assert [%{id: "porch"}] = rpc(a, Home.Onvif, :list_cameras, [])

    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "porch"}, [on: {b, "disp0"}]])
    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 1_000])
    {_sent, shown} = collect_frames()
    assert map_size(shown) >= 10
    :ok = rpc(c, Home.Render, :stop, [video])
  end

  test "a camera that drops the connection is reconnected; the picture resumes", ctx do
    %{a: a, b: b, c: c} = ctx
    {:ok, _} = add_camera(ctx)
    eventually(fn -> cam(c) end)

    {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "porch"}, [on: {b, "disp0"}]])
    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 3_000])
    assert_receive {:shown, {^b, "disp0"}, n, _} when n > 0, 3_000
    collect_frames()

    FakeRtspCamera.drop_clients(ctx.rtsp)
    eventually(fn -> FakeRtspCamera.stats(ctx.rtsp).sessions == 2 end, 10_000)

    # Same video session, same lease, new frames.
    flush_frames()
    Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 2_000])
    {_sent, shown} = collect_frames()
    assert map_size(shown) >= 20
    assert rpc(c, Process, :alive?, [video])
    assert %{active: 1} = FakeRtspCamera.stats(ctx.rtsp)

    :ok = rpc(c, Home.Render, :stop, [video])
    eventually(fn -> FakeRtspCamera.stats(ctx.rtsp).active == 0 end)
  end

  ## Helpers

  defp cam_any(node, ref), do: Enum.find(rpc(node, Home.Registry, :list, []), &(&1.ref == ref))

  defp flush_frames do
    receive do
      {:synth_frame, _, _, _} -> flush_frames()
      {:shown, _, _, _} -> flush_frames()
      {:watch_done, _, _} -> flush_frames()
    after
      0 -> :ok
    end
  end

  # Frame numbers the camera sent (with times) and first shown, until the watcher is done.
  defp collect_frames(sent \\ %{}, shown \\ %{}) do
    receive do
      {:synth_frame, _cap, n, t} -> collect_frames(Map.put(sent, n, t), shown)
      {:shown, _cap, n, t} -> collect_frames(sent, Map.put_new(shown, n, t))
      {:watch_done, _cap, _polls} -> {sent, shown}
    after
      10_000 -> flunk("watcher did not finish")
    end
  end

  # Frames shown per display, until `watchers` watchers are done.
  defp collect_shown(watchers, acc \\ %{})
  defp collect_shown(0, acc), do: acc

  defp collect_shown(watchers, acc) do
    receive do
      {:shown, cap, n, t} ->
        collect_shown(watchers, Map.update(acc, cap, %{n => t}, &Map.put_new(&1, n, t)))

      {:watch_done, _cap, _} ->
        collect_shown(watchers - 1, acc)
    after
      10_000 -> flunk("watchers did not finish")
    end
  end

  defp latencies(sent, shown) do
    for {n, t} <- shown, Map.has_key?(sent, n), do: (t - sent[n]) / 1_000
  end

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, round(p * (length(sorted) - 1))))
  end
end
