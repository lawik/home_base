defmodule Home.ActivityThrottleTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Activity
  alias Home.Test.ActivityProbe

  setup do
    opts = [capabilities: [%{id: "input0", kind: :input, adapter: Home.Test.FakeAdapter}]]
    [{a, _}, {b, _}] = start_cluster("m9t", a: opts, b: opts)

    Node.spawn(b, ActivityProbe, :subscriber, [self(), {a, "input0"}])
    assert_receive {:subscribed, ^b, pid}
    on_exit(fn -> send(pid, :stop) end)
    %{a: a, b: b}
  end

  defp collect(timeout) do
    receive do
      {:activity, _node, at, ev} -> [{at, ev} | collect(timeout)]
    after
      timeout -> []
    end
  end

  test "many emitters of one key: one event per interval and the final one is never lost",
       %{a: a} do
    interval = 50

    for _round <- 1..3 do
      result =
        rpc(a, ActivityProbe, :race, [{a, "input0"}, :input, :touch, 8, 150, [throttle: interval]])

      assert result in [:ok, :throttled]
      received = collect(interval + 300)

      assert [_, _ | _] = received
      assert %{data: %{final: true}} = received |> List.last() |> elem(1)

      times = Enum.map(received, &elem(&1, 0))
      gaps = Enum.zip_with(times, tl(times), &(&2 - &1))
      # Arrival times on b jitter a little; two publishes in one interval would be ~0 apart.
      assert Enum.all?(gaps, &(&1 >= interval - 20)), "gaps #{inspect(gaps)}"
    end
  end

  test "a held-back event goes out when Activity restarts, and Activity works after", %{
    a: a,
    b: b
  } do
    cap = {a, "input0"}

    assert [:ok, :throttled] =
             rpc(a, ActivityProbe, :burst, [cap, :input, :touch, 2, 0, [throttle: 10_000]])

    assert [{_, %{data: %{i: 1}}}] = collect(200)

    old = rpc(a, Process, :whereis, [Activity])
    :ok = rpc(a, GenServer, :stop, [Activity, :crash])

    # Well before its 10 s interval would have let it out.
    assert [{_, %{data: %{i: 2}}}] = collect(1_000)
    assert %{data: %{i: 2}} = rpc(b, Activity, :last, [cap, :input])

    new = eventually(fn -> rpc(a, Process, :whereis, [Activity]) end)
    assert new != old

    # The restarted server got the event back from b's snapshot, and throttles afresh.
    eventually(fn -> match?(%{data: %{i: 2}}, rpc(a, Activity, :last, [cap, :input])) end)

    assert [:ok, :throttled] =
             rpc(a, ActivityProbe, :burst, [cap, :input, :touch, 2, 0, [throttle: 300]])

    assert [{_, %{data: %{i: 1}}}, {_, %{data: %{i: 2}}}] = collect(700)
  end
end
