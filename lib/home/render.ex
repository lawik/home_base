defmodule Home.Render do
  @moduledoc """
  Run an emerge app here and draw it on any node's display (§6.1 scene forwarding).

      {:ok, session} = Home.Render.show({MyApp.Viewport, app: MyApp.State}, on: {b, "disp0"})
      :ok = Home.Render.move(session, to: {c, "disp0"})

  The app is an ordinary `use Emerge` viewport, started here with its options plus
  `runtime: [adapter: Home.Render.Remote, adapter_opts: [session: pid]]`. It puts that
  in its config, which is the only change a viewport needs to render remotely:

      def mount(opts) do
        {:ok, %{app: opts[:app]}, %Emerge.Config{runtime: Keyword.get(opts, :runtime, [])}}
      end

  Emerge diffs the app's tree here as it would for a local window; the encoded tree and
  patches go to the display node's `Home.Render.Compositor`, which applies them to its
  own renderer. Element and input events come back to the viewport, so `Event`
  handlers (including `Solve.Lookup.event/2` targets) work unchanged.

  Showing needs a lease on the display (`:display` leases are shared; the latest
  session is drawn on top). The session holds it, renews it and stops the app if it
  is revoked or expires. Stopping the session (`stop/1`) stops the app.
  """

  @doc """
  Start `app_spec` (`{viewport_module, opts}`) on this node, drawn on `on:` (`{node, cap_id}`).
  Returns the session pid. Options: `:on` (required), `:purpose` (lease purpose).
  """
  @spec show({module(), keyword()}, keyword()) :: {:ok, pid()} | {:error, term()}
  def show({module, opts} = _app_spec, show_opts) when is_atom(module) and is_list(opts) do
    target = Keyword.fetch!(show_opts, :on)

    DynamicSupervisor.start_child(
      Home.Render.Supervisor,
      {Home.Render.Session, {{module, opts}, target, show_opts}}
    )
  end

  @doc "Draw the session's app on another display. The app keeps running."
  @spec move(pid(), keyword()) :: :ok | {:error, term()}
  def move(session, to: target), do: Home.Render.Session.move(session, target)

  @doc "Stop the session and its app; the display lease is released."
  @spec stop(pid()) :: :ok
  def stop(session), do: GenServer.stop(session, :normal)

  @doc "The display the session is drawn on."
  @spec target(pid()) :: Home.Capability.ref()
  def target(session), do: Home.Render.Session.target(session)
end
