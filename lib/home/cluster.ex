defmodule Home.Cluster do
  @moduledoc """
  Keeps this node connected to every peer its source reports. Re-queries the source every
  `interval` ms and on every nodedown. All nodes mesh fully; none is special.
  """

  use GenServer
  require Logger

  @callback peers(opts :: keyword()) :: {:ok, [node()]} | {:error, term()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Query the source and connect now."
  def sync, do: GenServer.call(__MODULE__, :sync)

  @impl true
  def init(opts) do
    {source, source_opts} =
      case Keyword.get(opts, :source, Home.Cluster.Epmd) do
        {mod, mod_opts} -> {mod, mod_opts}
        mod -> {mod, []}
      end

    :net_kernel.monitor_nodes(true)
    state = %{source: source, opts: source_opts, interval: Keyword.get(opts, :interval, 30_000)}
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, connect(state), state}

  @impl true
  def handle_info(:tick, state) do
    connect(state)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state) do
    connect(state)
    {:noreply, state}
  end

  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  defp connect(%{source: source, opts: opts}) do
    if Node.alive?() do
      case source.peers(opts) do
        {:ok, peers} ->
          for peer <- peers, peer != node(), peer not in Node.list() do
            Node.connect(peer)
          end

          :ok

        {:error, reason} = error ->
          Logger.debug("cluster source #{inspect(source)} failed: #{inspect(reason)}")
          error
      end
    else
      {:error, :not_distributed}
    end
  end
end
