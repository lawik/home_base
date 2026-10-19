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

  @doc "Media pipelines and sessions currently running on this node."
  def media_children, do: length(DynamicSupervisor.which_children(Home.Media.Supervisor))
end
