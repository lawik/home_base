defmodule Home.Render.Remote do
  @moduledoc """
  Emerge renderer adapter (`Emerge.Config.Runtime.adapter`) that draws on another
  node's display through a `Home.Render.Session`.

  It runs in the app's viewport, on the app's node. Emerge's own diffing runs here as
  usual (`Emerge.Engine.encode_full/2`, `Emerge.Engine.diff_state_update/2`); only the
  encoded bytes go to the session, which forwards them to the display's compositor.
  Element and input events come back to the viewport as `{:emerge_skia_event, event}`,
  exactly as from a local renderer, and the viewport routes them with its diff state.

  Selected by `Home.Render.show/2`, which passes the app
  `runtime: [adapter: Home.Render.Remote, adapter_opts: [session: pid]]` to put in its
  `%Emerge.Config{}`.
  """

  @behaviour Emerge.Runtime.Viewport.Renderer

  alias Home.Render.Session

  @impl true
  def start(config, opts) do
    session = Keyword.fetch!(opts, :session)

    case Session.renderer_started(session, config) do
      :ok -> {:ok, session}
      error -> error
    end
  end

  @impl true
  def configure(session, _previous, config), do: Session.configure(session, config)

  @impl true
  def stop(session), do: Session.renderer_stopped(session)

  @impl true
  def running?(session), do: Process.alive?(session)

  @impl true
  def set_input_target(session, pid), do: Session.set_input_target(session, pid)

  @impl true
  def set_log_target(_session, _pid), do: :ok

  # Raw input subscriptions travel as the app's `config.input`, see `configure/3`.
  @impl true
  def set_input_mask(_session, _mask), do: :ok

  @impl true
  def upload_tree(session, tree) do
    {bin, diff_state, assigned} = Emerge.Engine.encode_full(Emerge.Engine.diff_state_new(), tree)
    :ok = Session.upload(session, bin, assigned)
    {diff_state, assigned}
  end

  @impl true
  def patch_tree(session, diff_state, tree) do
    {bin, diff_state, assigned} = Emerge.Engine.diff_state_update(diff_state, tree)
    :ok = Session.patch(session, bin, assigned)
    {diff_state, assigned}
  end
end
