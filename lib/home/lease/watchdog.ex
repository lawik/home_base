defmodule Home.Lease.Watchdog do
  @moduledoc """
  Backstop for holders that are alive but stuck: every `interval` ms, expires leases on
  this node that have not been renewed within their capability's max age.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run one sweep now. Returns the number of leases expired."
  def sweep do
    Home.Capability.Server.local_servers()
    |> Enum.map(&Home.Capability.Server.expire_overdue/1)
    |> Enum.sum()
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 1_000)
    {:ok, schedule(%{interval: interval})}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    Process.send_after(self(), :sweep, state.interval)
    state
  end
end
