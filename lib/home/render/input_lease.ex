defmodule Home.Render.InputLease do
  @moduledoc """
  Holds the `:input` lease of a display for a render session and routes the display's
  input to it (`Home.Render.Compositor.route_input/3`).

  Started (linked) by `Home.Render.Session` and `Home.Render.Video` next to their
  display lease. If the display has no `:input` capability, `start_link/3` returns
  `:ignore` and the compositor keeps sending input to the session on top. If the input
  is held by someone else, it tries again every second, so input follows when the
  holder lets go. A revoked or expired input lease takes input away from the session,
  not the session away from the display; it is then tried again too.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Home.Lease
  alias Home.Render.Compositor

  @retry 1_000

  @doc "Lease `comp`'s input for `target`. `{:ok, pid}` or `:ignore` (no input capability)."
  def start_link(comp, target, purpose) do
    case safe(fn -> Compositor.input_cap(comp) end) do
      {_node, _id} = cap -> GenServer.start_link(__MODULE__, {comp, cap, target, purpose})
      _ -> :ignore
    end
  end

  @doc "The input lease, or nil while not held."
  def lease(pid), do: GenServer.call(pid, :lease)

  def stop(nil), do: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init({comp, cap, target, purpose}) do
    state = %{comp: comp, cap: cap, target: target, purpose: purpose, lease: nil, timer: nil}
    {:ok, acquire(state)}
  end

  @impl true
  def handle_call(:lease, _from, state), do: {:reply, state.lease, state}

  @impl true
  def handle_info(:acquire, state), do: {:noreply, acquire(%{state | timer: nil})}

  def handle_info(:renew, %{lease: nil} = state), do: {:noreply, state}

  def handle_info(:renew, state) do
    case safe(fn -> Lease.renew(state.lease) end) do
      :ok -> {:noreply, schedule(state, :renew, renew_every(state.lease))}
      _ -> {:noreply, acquire(%{state | lease: nil})}
    end
  end

  def handle_info({event, ref}, %{lease: %{ref: ref}} = state)
      when event in [:lease_expired, :lease_revoked] do
    {:noreply, schedule(%{state | lease: nil}, :acquire, @retry)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{lease: nil}), do: :ok

  def terminate(_reason, state) do
    safe(fn -> Compositor.unroute_input(state.comp, state.lease) end)
    Lease.release(state.lease)
    :ok
  end

  defp acquire(state) do
    with {:ok, lease} <- Lease.acquire(state.cap, for: self(), purpose: state.purpose),
         :ok <- route(state, lease) do
      schedule(%{state | lease: lease}, :renew, renew_every(lease))
    else
      {:error, reason} = error ->
        if reason != :busy,
          do: Logger.debug("render: input #{inspect(state.cap)}: #{inspect(error)}")

        schedule(state, :acquire, @retry)
    end
  end

  defp route(state, lease) do
    case safe(fn -> Compositor.route_input(state.comp, lease, state.target) end) do
      :ok ->
        :ok

      error ->
        Lease.release(lease)
        {:error, {:route, error}}
    end
  end

  defp schedule(state, msg, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), msg, ms)}
  end

  defp renew_every(lease) do
    case safe(fn -> Home.Capability.Server.info(lease.server) end) do
      %{cap: cap} -> max(div(Home.Capability.max_age(cap), 3), 100)
      _ -> 20_000
    end
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
