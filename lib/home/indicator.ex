defmodule Home.Indicator do
  @moduledoc """
  The "mic on, held by …" indicator (plan §4.4): which capabilities are on and who
  holds them, with a "Revoke all" button that calls `Home.Lease.revoke_all/0` on this
  node. Solve holds the state (`Home.Indicator.App`, `Home.Indicator.Leases`), Emerge
  draws it (`Home.Indicator.Viewport`); it is an ordinary app, so any display can show
  it:

      {:ok, session} = Home.Render.show({Home.Indicator.Viewport, []}, on: {node, "disp0"})

  Revoke all drops every lease on this node, and that includes the indicator's own
  lease when it is drawn on this node's display: the session stops like any other.
  To keep the indicator up, run this process, which shows it and shows it again
  whenever its session ends (after `retry` ms, default 1 s):

      children = [{Home.Indicator, on: {node(), "disp0"}}]

  Options: `:on` (required, a display `{node, cap_id}`), `:node` (only that node's
  capabilities; default all), `:retry`. `session/1` returns the current session pid.
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The render session currently showing the indicator, or nil."
  def session(pid), do: GenServer.call(pid, :session)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    target = Keyword.fetch!(opts, :on)
    app_opts = Keyword.take(opts, [:node])
    state = %{target: target, app_opts: app_opts, retry: opts[:retry] || 1_000, session: nil}
    {:ok, show(state)}
  end

  @impl true
  def handle_call(:session, _from, state), do: {:reply, state.session, state}

  @impl true
  def handle_info({:DOWN, _, :process, pid, _reason}, %{session: pid} = state) do
    Process.send_after(self(), :show, state.retry)
    {:noreply, %{state | session: nil}}
  end

  def handle_info(:show, %{session: nil} = state), do: {:noreply, show(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{session: session}) do
    if session, do: Home.Render.stop(session)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp show(state) do
    spec = {Home.Indicator.Viewport, state.app_opts}

    case Home.Render.show(spec, on: state.target, purpose: "lease indicator") do
      {:ok, session} ->
        Process.monitor(session)
        %{state | session: session}

      {:error, reason} ->
        Logger.debug("lease indicator on #{inspect(state.target)}: #{inspect(reason)}")
        Process.send_after(self(), :show, state.retry)
        state
    end
  end
end
