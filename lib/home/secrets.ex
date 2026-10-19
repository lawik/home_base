defmodule Home.Secrets do
  @moduledoc """
  Credentials that are the same on every node (HA token and URL, MQTT, API keys). Any node
  can `put/2` or `delete/1`; the whole set is broadcast on PubSub `"secrets"`. When a peer
  comes up (or this server starts) the two exchange sets: each sends its own and asks for
  the other's, so it works whichever side is still booting. Persisted in
  `Home.data_dir/0`, so a node boots with the last set it had. Not encrypted at rest
  (deferred).

  Every key carries its own version `{counter, node}` (a Lamport clock: a put takes the
  highest counter this node has seen plus one). Merging keeps the highest version per key,
  node name breaking ties, and deletes are kept as tombstones. So concurrent puts of
  different keys on different nodes both survive, concurrent puts of the same key converge
  on one value everywhere, and a put on a node that is behind still lands.

  Local changes are announced on PubSub `"secrets:changed"` (this node only) as
  `{:secrets_changed, keys}`.
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

  @doc "The highest version in the set, `{counter, node}`."
  def version, do: snapshot().version

  @doc "`%{version: version, data: %{key => value}}`."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  ## Server

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Home.PubSub, @topic)
    :net_kernel.monitor_nodes(true)
    entries = read() || %{}
    for peer <- Node.list(), do: exchange(peer, entries)
    {:ok, %{entries: entries}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    data = for {k, {_v, {:ok, value}}} <- state.entries, into: %{}, do: {k, value}
    {:reply, %{version: max_version(state.entries), data: data}, state}
  end

  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  def handle_call({:put, key, value}, _from, state),
    do: {:reply, :ok, change(state, key, {:ok, value})}

  def handle_call({:delete, key}, _from, state),
    do: {:reply, :ok, change(state, key, :deleted)}

  @impl true
  def handle_info({:secrets, remote}, state) when is_map(remote),
    do: {:noreply, merge(state, remote)}

  def handle_info({:nodeup, peer}, state) do
    exchange(peer, state.entries)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Push ours and pull theirs. Either may hit a peer whose server isn't up yet; that peer
  # does the same with us when it starts.
  defp exchange(peer, entries) do
    send({__MODULE__, peer}, {:secrets, entries})
    me = self()

    Task.start(fn ->
      try do
        send(me, {:secrets, GenServer.call({__MODULE__, peer}, :entries)})
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp change(state, key, value) do
    {n, _} = max_version(state.entries)
    entries = Map.put(state.entries, key, {{n + 1, node()}, value})
    persist(entries)
    Phoenix.PubSub.broadcast_from(Home.PubSub, self(), @topic, {:secrets, entries})
    changed([key])
    %{state | entries: entries}
  end

  defp merge(state, remote) do
    newer =
      for {key, {version, _} = entry} <- remote,
          not match?({mine, _} when mine >= version, state.entries[key]),
          into: %{},
          do: {key, entry}

    if newer == %{} do
      state
    else
      entries = Map.merge(state.entries, newer)
      persist(entries)
      changed(Map.keys(newer))
      %{state | entries: entries}
    end
  end

  defp max_version(entries) do
    entries |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> {0, node()} end)
  end

  defp changed(keys),
    do: Phoenix.PubSub.local_broadcast(Home.PubSub, "secrets:changed", {:secrets_changed, keys})

  defp persist(entries) do
    tmp = file() <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(entries))
    File.rename!(tmp, file())
  end

  defp read do
    with {:ok, bin} <- File.read(file()) do
      case :erlang.binary_to_term(bin) do
        # Earlier format: one version for the whole set.
        %{version: {_, _} = v, data: data} when is_map(data) ->
          Map.new(data, fn {k, value} -> {k, {v, {:ok, value}}} end)

        entries when is_map(entries) ->
          if Enum.all?(entries, &match?({_, {{n, _}, _}} when is_integer(n), &1)),
            do: entries,
            else: nil

        _ ->
          nil
      end
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp file, do: Path.join(Home.data_dir(), "secrets")
end
