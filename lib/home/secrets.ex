defmodule Home.Secrets do
  @moduledoc """
  Credentials that are the same on every node (HA token and URL, MQTT, API keys). Any node
  can `put/2`; the whole set carries a version and is broadcast on PubSub `"secrets"`.
  A node that sees a peer come up asks it for its set and keeps whichever is newer, so
  late joiners catch up. Persisted in `Home.data_dir/0`. Not encrypted at rest (deferred).
  """

  use GenServer

  @topic "secrets"

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def get(key, default \\ nil) do
    case fetch(key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  def fetch(key), do: Map.fetch(snapshot().data, key)
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})
  def delete(key), do: GenServer.call(__MODULE__, {:delete, key})
  def version, do: snapshot().version
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  ## Server

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Home.PubSub, @topic)
    :net_kernel.monitor_nodes(true)
    state = read() || %{version: {0, node()}, data: %{}}
    for peer <- Node.list(), do: ask(peer)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:put, key, value}, _from, state),
    do: {:reply, :ok, bump(state, Map.put(state.data, key, value))}

  def handle_call({:delete, key}, _from, state),
    do: {:reply, :ok, bump(state, Map.delete(state.data, key))}

  @impl true
  def handle_info({:secrets, remote}, state), do: {:noreply, merge(state, remote)}

  def handle_info({:nodeup, peer}, state) do
    ask(peer)
    {:noreply, state}
  end

  def handle_info({:nodedown, _}, state), do: {:noreply, state}

  defp ask(peer) do
    me = self()

    Task.start(fn ->
      try do
        send(me, {:secrets, GenServer.call({__MODULE__, peer}, :snapshot)})
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp bump(%{version: {n, _}}, data) do
    state = %{version: {n + 1, node()}, data: data}
    persist(state)
    Phoenix.PubSub.broadcast_from(Home.PubSub, self(), @topic, {:secrets, state})
    state
  end

  # Versions are {counter, node}: highest counter wins, node name breaks ties.
  defp merge(state, %{version: v} = remote) when v > state.version do
    persist(remote)
    Phoenix.PubSub.local_broadcast(Home.PubSub, "secrets:changed", {:secrets_changed, v})
    remote
  end

  defp merge(state, _), do: state

  defp persist(state), do: File.write!(file(), :erlang.term_to_binary(state))

  defp read do
    case File.read(file()) do
      {:ok, bin} -> :erlang.binary_to_term(bin)
      _ -> nil
    end
  end

  defp file, do: Path.join(Home.data_dir(), "secrets")
end
