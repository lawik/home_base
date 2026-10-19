defmodule Home.Test.ActivityProbe do
  @moduledoc false
  # Activity helpers that run on peers.

  alias Home.Activity

  @doc """
  Poll `Activity.last(cap, kind)` until it holds an event with `data`. Returns
  `{:ok, latency_us, event}`, latency measured from the event's `ts` (all peers share the
  host clock), or `:timeout`.
  """
  def await_last(cap, kind, data, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(cap, kind, data, deadline)
  end

  defp poll(cap, kind, data, deadline) do
    case Activity.last(cap, kind) do
      %{data: ^data} = ev ->
        {:ok, System.system_time(:microsecond) - ev.ts * 1_000, ev}

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(1)
          poll(cap, kind, data, deadline)
        end
    end
  end

  @doc """
  Subscribe with `Activity.subscribe(what)` and forward `{:activity, node(), at, ev}` to
  `to`, `at` being this node's monotonic ms when it arrived.
  """
  def subscriber(to, what) do
    :ok = Activity.subscribe(what)
    send(to, {:subscribed, node(), self()})
    forward(to)
  end

  defp forward(to) do
    receive do
      :stop ->
        :ok

      {:activity, ev} ->
        send(to, {:activity, node(), System.monotonic_time(:millisecond), ev})
        forward(to)
    end
  end

  @doc "Emit `n` events `%{i: 1..n}`, `every` ms apart. Returns the emit results."
  def burst(cap, kind, event, n, every, opts \\ []) do
    for i <- 1..n do
      result = Activity.emit(cap, kind, event, %{i: i}, opts)
      if every > 0, do: Process.sleep(every)
      result
    end
  end
end
