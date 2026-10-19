# The M0/M1 check against a running qemu guest: run as host node nv1, from the home_base
# repo root, with the guest booted (scripts/qemu.sh start) and optionally nv2 running:
#
#   mix run --no-start nerves/home_node/scripts/demo.exs [--no-reboot] [--no-power-cycle]
#
# Exits non-zero on the first failed check. scripts/demo.sh wraps all of it.

Code.require_file("host_setup.exs", __DIR__)

defmodule Demo do
  @qemu Path.expand("qemu.sh", __DIR__)

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
      guest in Node.list() and ids(guest_caps(guest)) == ["mic0", "pir0", "temp0"]
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

opts = System.argv()
Logger.configure(level: :warning)
guest = HostNode.guest()

me =
  HostNode.start(1, [
    %{id: "spk-nv1", kind: :audio_out, adapter: Home.Adapters.Null, meta: %{channels: 2}}
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
  Demo.check!(Demo.ids(infos) == ["mic0", "pir0", "temp0"], "guest capabilities listed")
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
