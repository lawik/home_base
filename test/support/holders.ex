defmodule Home.Test.Holders do
  @moduledoc false
  # Processes spawned on peers (test-module closures don't exist there).

  alias Home.Lease

  @doc "Acquire `cap`, report `{:lease, self(), result}` to `test`, hold until `:release`."
  def holder(test, cap, opts \\ []) do
    send(test, {:lease, self(), Lease.acquire(cap, opts)})

    receive do
      :release -> :ok
    end
  end

  @doc "Subscribe to `topic` on this node and forward everything as `{:relayed, msg}`."
  def relay(to, topic) do
    Phoenix.PubSub.subscribe(Home.PubSub, topic)
    send(to, {:subscribed, self()})
    relay_loop(to)
  end

  defp relay_loop(to) do
    receive do
      :stop ->
        :ok

      msg ->
        send(to, {:relayed, msg})
        relay_loop(to)
    end
  end

  @doc "Acquire and renew every `every` ms until told `:stop_renewing`; then report the next message."
  def renewer(test, cap, every) do
    {:ok, lease} = Lease.acquire(cap)
    send(test, {:got, lease})
    renew_loop(lease, test, every)
  end

  defp renew_loop(lease, test, every) do
    receive do
      :stop_renewing ->
        receive do
          msg -> send(test, {:holder_got, msg})
        end
    after
      every ->
        :ok = Lease.renew(lease)
        renew_loop(lease, test, every)
    end
  end

  @doc "Acquire every cap in `caps`, report `:acquired`, then forward `n` revocations."
  def multi(test, caps, n) do
    for cap <- caps, do: {:ok, _} = Lease.acquire(cap)
    send(test, :acquired)

    for _ <- 1..n do
      receive do
        {:lease_revoked, _} = m -> send(test, m)
      end
    end
  end
end
