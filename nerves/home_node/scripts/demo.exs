# The checks against a running qemu guest (cluster, registry, leases, media across the
# NAT, reboot and power cycle): run as host node nv1, from the home_base repo root, with
# the guest booted (scripts/qemu.sh start) and optionally nv2 running:
#
#   mix run --no-start nerves/home_node/scripts/demo.exs \
#     [--no-media] [--no-reboot] [--no-power-cycle]
#
# Exits non-zero on the first failed check. scripts/demo.sh wraps all of it.

Code.require_file("host_setup.exs", __DIR__)

defmodule Demo do
  @qemu Path.expand("qemu.sh", __DIR__)
  @guest_ids ["cam0", "disp0", "mic0", "pir0", "spk0", "temp0"]

  def guest_ids, do: @guest_ids

  def step(title, fun) do
    IO.puts("\n== #{title}")
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    IO.puts("   ok (#{System.monotonic_time(:millisecond) - t0} ms)")
    result
  end

  def check!(true, _what), do: :ok
  def check!(false, what), do: fail!(what)

  def fail!(what) do
    IO.puts("   FAILED: #{what}")
    System.halt(1)
  end

  def eventually(what, timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop(what, deadline, fun)
  end

  defp loop(what, deadline, fun) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          fail!("timed out waiting for #{what}")
        else
          Process.sleep(200)
          loop(what, deadline, fun)
        end

      value ->
        value
    end
  end

  def show(infos) do
    for i <- infos do
      IO.puts(
        "   #{inspect(i.ref)} kind=#{i.cap.kind} availability=#{i.cap.availability} " <>
          "status=#{i.status} hardware=#{i.hardware} device=#{i.device_id}"
      )
    end

    infos
  end

  def ids(infos), do: infos |> Enum.map(fn %{ref: {_, id}} -> id end) |> Enum.sort()

  # Straight from the owning server, bypassing the registry's short info cache.
  def info(cap) do
    with {:ok, pid} <- Home.Registry.whereis(cap), do: Home.Capability.Server.info(pid)
  catch
    :exit, _ -> nil
  end

  def guest_caps(guest), do: Home.Registry.list(node: guest)

  def wait_joined(guest, timeout) do
    eventually("#{guest} to join with its capabilities", timeout, fn ->
      guest in Node.list() and ids(guest_caps(guest)) == @guest_ids
    end)
  end

  def wait_down(guest, timeout) do
    eventually("#{guest} to go down", timeout, fn -> guest not in Node.list() end)
  end

  def lease_round(guest) do
    mic = {guest, "mic0"}
    check!(match?(%{status: :idle, hardware: :off}, info(mic)), "mic0 idle and off before")
    {:ok, lease} = Home.Lease.acquire(mic, purpose: "home_node demo")
    IO.puts("   acquired #{inspect(lease.cap)} endpoint=#{inspect(lease.endpoint)}")
    leased = info(mic)
    IO.puts("   mic0 now status=#{leased.status} hardware=#{leased.hardware}")
    check!(match?(%{status: :leased, hardware: :on, leases: 1}, leased), "mic0 leased and on")

    :ok = Home.Lease.release(lease)
    released = info(mic)
    IO.puts("   released; mic0 now status=#{released.status} hardware=#{released.hardware}")
    check!(match?(%{status: :idle, hardware: :off}, released), "mic0 idle and off after")
  end

  def qemu(args) do
    {out, code} = System.cmd(@qemu, args, stderr_to_stdout: true)
    for line <- String.split(out, "\n", trim: true), do: IO.puts("   " <> line)
    check!(code == 0, "qemu.sh #{Enum.join(args, " ")}")
  end
end

# After Demo: it uses Demo.eventually/3 and Demo.fail!/1.
Code.require_file("media_checks.exs", __DIR__)

opts = System.argv()
Logger.configure(level: :warning)
guest = HostNode.guest()

# nv1 records what it plays and has a synthetic mic and a headless display, so media to
# and from the guest can be measured here.
me =
  HostNode.start(1, [
    %{
      id: "spk-nv1",
      kind: :audio_out,
      adapter: Home.Adapters.Audio.CaptureSpeaker,
      meta: %{channels: 2, notify: self()}
    },
    %{
      id: "mic-nv1",
      kind: :audio_in,
      availability: :on_request,
      adapter: Home.Adapters.Audio.SynthMic,
      meta: %{click_every: 300, notify: self()}
    },
    %{id: "disp-nv1", kind: :display, adapter: Home.Adapters.Display, meta: %{w: 320, h: 240}}
  ])

IO.puts("host node #{me}, looking for #{guest}")

Demo.step("cluster forms: #{guest} joins, within 90 s", fn ->
  Demo.wait_joined(guest, 90_000)
  IO.puts("   Node.list() = #{inspect(Node.list())}")
  peers_seen_by_guest = :erpc.call(guest, Node, :list, [])
  IO.puts("   on guest, Node.list() = #{inspect(peers_seen_by_guest)}")
  Demo.check!(me in peers_seen_by_guest, "guest sees #{me}")
end)

Demo.step("Home.Registry.list(node: guest) from the host", fn ->
  infos = Demo.show(Demo.guest_caps(guest))
  Demo.check!(Demo.ids(infos) == Demo.guest_ids(), "guest capabilities listed")
end)

Demo.step("Home.Registry.list() on the guest (via :erpc) shows host capabilities", fn ->
  infos = Demo.show(:erpc.call(guest, Home.Registry, :list, []))
  Demo.check!({me, "spk-nv1"} in Enum.map(infos, & &1.ref), "guest sees spk-nv1")

  if :"nv2@10.0.3.2" in Node.list(),
    do: Demo.check!({:"nv2@10.0.3.2", "spk-nv2"} in Enum.map(infos, & &1.ref), "guest sees nv2")
end)

Demo.step("Home.Registry.list(kind: :presence) from the guest's point of view", fn ->
  infos = Demo.show(:erpc.call(guest, Home.Registry, :list, [[kind: :presence]]))
  Demo.check!(Demo.ids(infos) == ["pir0"], "kind filter")
end)

Demo.step("lease {guest, mic0} (:on_request) from the host: hardware on, then off", fn ->
  Demo.lease_round(guest)
end)

Demo.step("holder death on the host releases the guest's mic0", fn ->
  holder = spawn(fn -> Process.sleep(:infinity) end)
  {:ok, _lease} = Home.Lease.acquire({guest, "mic0"}, for: holder, purpose: "dies")
  Demo.check!(Demo.info({guest, "mic0"}).hardware == :on, "mic0 on while held")
  Process.exit(holder, :kill)

  Demo.eventually("mic0 released after holder death", 5_000, fn ->
    match?(%{status: :idle, hardware: :off}, Demo.info({guest, "mic0"}))
  end)
end)

unless "--no-media" in opts do
  # Load all code on both sides first (both run in interactive mode).
  DemoMedia.preload(node())
  DemoMedia.preload(guest)
  :ok = :erpc.call(guest, HomeNode.Probe, :subscribe, [self()])
  # The guest's wall clock moves during the run (NTP pulls it in after boot), so each timed
  # step converts guest times with an offset re-measured every 200 ms.
  offset = fn ->
    clock = DemoMedia.clock_offset(guest)

    IO.puts(
      "   guest clock - host clock = #{div(clock.offset_us, 1000)} ms " <>
        "(+- #{div(clock.rtt_us, 2000)} ms, best :erpc round trip #{clock.rtt_us} us)"
    )

    {clock.offset_us, DemoMedia.track_offset(guest)}
  end

  drift = fn {before, tracker} ->
    moved = div(DemoMedia.clock_offset(guest).offset_us - before, 1000)
    IO.puts("   guest clock moved #{moved} ms relative to the host during this step (tracked)")
    Agent.stop(tracker)
  end

  sane = fn lat ->
    Demo.check!(Enum.min(lat) >= -5, "no negative latencies (clock offset holds)")
  end

  Demo.step("audio: guest mic0 (:on_request, synthetic) -> nv1 capture speaker", fn ->
    off = offset.()
    lat = DemoMedia.audio({guest, "mic0"}, {me, "spk-nv1"}, guest, elem(off, 1), 4_000)
    IO.puts("   click -> played on nv1: #{DemoMedia.stats(lat)}")
    drift.(off)
    sane.(lat)
    Demo.check!(length(lat) >= 8, "at least 8 clicks heard in 4 s")
    Demo.check!(DemoMedia.p95(lat) <= 250, "p95 <= 250 ms")

    Demo.eventually("mic0 off after the session", 5_000, fn ->
      match?(%{status: :idle, hardware: :off}, Demo.info({guest, "mic0"}))
    end)
  end)

  Demo.step("audio: nv1 mic (synthetic) -> guest spk0 capture speaker", fn ->
    off = offset.()
    lat = DemoMedia.audio({me, "mic-nv1"}, {guest, "spk0"}, guest, elem(off, 1), 4_000)
    IO.puts("   click -> played on guest: #{DemoMedia.stats(lat)}")
    drift.(off)
    sane.(lat)
    Demo.check!(length(lat) >= 8, "at least 8 clicks heard in 4 s")
    Demo.check!(DemoMedia.p95(lat) <= 250, "p95 <= 250 ms")
  end)

  Demo.step("video: guest cam0 (synthetic H.264, 320x240@30) -> nv1 headless display", fn ->
    off = offset.()
    v = DemoMedia.video({guest, "cam0"}, {me, "disp-nv1"}, guest, elem(off, 1), 4_000)
    IO.puts("   frames sent #{v.sent}, shown on nv1 #{v.shown}")
    IO.puts("   capture -> on nv1's screen: #{DemoMedia.stats(v.latencies)}")
    drift.(off)
    sane.(v.latencies)
    Demo.check!(length(v.latencies) >= 60, "at least 60 frames shown in 4 s")
    Demo.check!(DemoMedia.p95(v.latencies) <= 250, "p95 <= 250 ms")

    Demo.eventually("cam0 off after the video", 5_000, fn ->
      match?(%{status: :idle, hardware: :off}, Demo.info({guest, "cam0"}))
    end)
  end)

  Demo.step("scene forwarding: emerge app on nv1 -> guest disp0 (headless, 160x120)", fn ->
    disp = {guest, "disp0"}
    session = DemoMedia.show_app(disp)
    DemoMedia.await_pixel(disp, {100, 80}, &DemoMedia.red?/1, 20_000)
    DemoMedia.await_pixel(disp, {10, 10}, &DemoMedia.green?/1, 5_000)
    IO.puts("   guest draws the app: background red, button green")
    button = DemoMedia.button_id(session)

    {fetch_us, _} = :timer.tc(fn -> DemoMedia.pixel(disp, {0, 0}) end)

    rounds =
      for i <- 1..6 do
        want = if rem(i, 2) == 1, do: &DemoMedia.blue?/1, else: &DemoMedia.red?/1
        t0 = DemoMedia.press(disp, button)
        t_app = receive do: ({:app_pressed, t} -> t), after: (5_000 -> Demo.fail!("no press"))
        t1 = DemoMedia.await_pixel(disp, {100, 80}, want, 5_000)
        {(t1 - t0) / 1_000, (t_app - t0) / 1_000}
      end

    {total, input} = Enum.unzip(rounds)
    IO.puts("   press on guest -> app on nv1 -> new colour on guest: #{DemoMedia.stats(total)}")
    IO.puts("     of which press on guest -> app on nv1: #{DemoMedia.stats(input)}")

    IO.puts(
      "     (each poll fetches the guest's 160x120 frame over :erpc, #{div(fetch_us, 1000)} ms)"
    )

    Home.Render.stop(session)
  end)

  :erpc.call(guest, HomeNode.Probe, :unsubscribe, [self()])
  DemoMedia.flush()
end

unless "--no-reboot" in opts do
  Demo.step("guest reboots (Nerves.Runtime.reboot/0) and rejoins on its own", fn ->
    :net_kernel.monitor_nodes(true)
    :erpc.cast(guest, Nerves.Runtime, :reboot, [])
    Demo.wait_down(guest, 60_000)
    t0 = System.monotonic_time(:millisecond)
    IO.puts("   #{guest} down")
    Demo.wait_joined(guest, 180_000)
    IO.puts("   rejoined #{System.monotonic_time(:millisecond) - t0} ms after nodedown")
    Demo.show(Demo.guest_caps(guest))
    Demo.lease_round(guest)
  end)
end

unless "--no-power-cycle" in opts do
  Demo.step("guest power-cycled (qemu killed and restarted) rejoins on its own", fn ->
    Demo.qemu(["stop"])
    Demo.wait_down(guest, 30_000)
    Demo.qemu(["start"])
    t0 = System.monotonic_time(:millisecond)
    Demo.wait_joined(guest, 180_000)
    IO.puts("   rejoined #{System.monotonic_time(:millisecond) - t0} ms after qemu start")
    Demo.lease_round(guest)
  end)
end

IO.puts("\nALL CHECKS PASSED")
