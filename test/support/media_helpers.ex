defmodule Home.Test.MediaHelpers do
  @moduledoc false
  # Runs on peers: acquire leases, start a session and own it until told to stop.

  alias Home.{Lease, Media}

  @doc """
  Acquire `source` and every cap in `sinks`, start a session and report
  `{:session, self(), result}` to `test`. Then wait: on `:stop` stop the session and report
  `{:stopped, self()}`; if the session ends by itself report `{:session_down, self(), reason}`.
  """
  def intercom(test, source, sinks, opts \\ []) do
    {:ok, mic} = Lease.acquire(source, purpose: "intercom")
    spks = for cap <- List.wrap(sinks), do: elem(Lease.acquire(cap, purpose: "intercom"), 1)

    case Media.Session.start(Keyword.merge([source: mic, sinks: spks, codec: :opus], opts)) do
      {:ok, session} ->
        send(test, {:session, self(), {:ok, session}})
        mref = Process.monitor(session)

        receive do
          :stop ->
            :ok = Media.Session.stop(session)
            send(test, {:stopped, self()})

          {:DOWN, ^mref, :process, _, reason} ->
            send(test, {:session_down, self(), reason})
        end

      error ->
        send(test, {:session, self(), error})
    end
  end

  @doc "Inputs of the mixer behind a `Home.Adapters.Audio.Mixer` speaker on this node."
  def mixer_inputs(cap) do
    {:ok, server} = Home.Registry.whereis(cap)
    Home.Media.Mixer.inputs(:sys.get_state(server).astate.mixer)
  end

  @doc """
  Load every module of the loaded applications, as a release in embedded mode does at
  boot. Peers load code lazily, and the first packet through a fresh node otherwise pays
  for loading the RTP/Opus modules, which ends up as permanent playout delay.
  """
  def preload do
    for {app, _, _} <- Application.loaded_applications(),
        {:ok, mods} = :application.get_key(app, :modules),
        do: :code.ensure_modules_loaded(mods)

    :ok
  end

  @doc "Media pipelines and sessions currently running on this node."
  def media_children, do: length(DynamicSupervisor.which_children(Home.Media.Supervisor))
end
