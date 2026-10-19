defmodule HomeNode.Probe do
  @moduledoc """
  A registered relay for the synthetic adapters' `notify:` messages.

  A manifest in config can't name a pid, so the qemu manifest sets
  `notify: HomeNode.Probe` on its synthetic mic, speaker and camera. Anything that wants
  their timestamps (`{:synth_click, ...}`, `{:capture_onset, ...}`, `{:synth_frame, ...}`,
  `{:home_hw, ...}`) subscribes, from any node:

      :erpc.call(guest, HomeNode.Probe, :subscribe, [self()])

  Every message the probe gets is forwarded to every subscriber until it exits.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def unsubscribe(pid), do: GenServer.call(__MODULE__, {:unsubscribe, pid})

  @impl true
  def init(subs), do: {:ok, subs}

  @impl true
  def handle_call({:subscribe, pid}, _from, subs) do
    subs = if Map.has_key?(subs, pid), do: subs, else: Map.put(subs, pid, Process.monitor(pid))
    {:reply, :ok, subs}
  end

  def handle_call({:unsubscribe, pid}, _from, subs) do
    {mref, subs} = Map.pop(subs, pid)
    if mref, do: Process.demonitor(mref, [:flush])
    {:reply, :ok, subs}
  end

  @impl true
  def handle_info({:DOWN, _mref, :process, pid, _reason}, subs),
    do: {:noreply, Map.delete(subs, pid)}

  def handle_info(msg, subs) do
    for pid <- Map.keys(subs), do: send(pid, msg)
    {:noreply, subs}
  end
end
