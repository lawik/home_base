defmodule Home.Capability do
  @moduledoc """
  One piece of hardware a node vends: a mic, a speaker, a display, a radio, a sensor, a
  light (`Home.Light`).

  `availability`:

    * `:always` - vended as soon as the node is up; hardware is started at boot.
    * `:on_request` - hardware is off until a lease starts it, and off again on the last release.
    * `:off` - present but disabled by the owner; never vended.

  `shared`: whether several leases can be held at once. `nil` (default) means the kind's
  default (`shareable?/1`); a `:video_in` whose adapter fans one stream out to every
  holder (e.g. an ONVIF camera proxied by `Home.Onvif`) sets it to `true`.

  ## Runtime capabilities

  Most capabilities come from the manifest at boot and run under the static
  `Home.Capability.Supervisor`. `add/1` starts one at runtime instead, under the
  `Home.Capability.Runtime` dynamic supervisor next to it: it is vended (joins `:pg`,
  shows up in `Home.Registry.list/1` on every node) as soon as `add/1` returns.
  `remove/1` revokes its leases (holders get `{:lease_revoked, ref}`, as for
  `Home.Lease.revoke_all/0`), turns its hardware off and stops it, so it disappears
  from the registry everywhere. Runtime capabilities are not persisted here; whoever
  adds them re-adds them at boot (see `Home.Onvif`).
  """

  @kinds [
    :audio_in,
    :audio_out,
    :video_in,
    :display,
    :input,
    :zigbee,
    :thread,
    :sensor,
    :presence,
    :light
  ]

  @enforce_keys [:id, :kind]
  defstruct [
    :id,
    :kind,
    availability: :always,
    adapter: nil,
    max_age: nil,
    shared: nil,
    meta: %{}
  ]

  @type id :: String.t()
  @type kind ::
          :audio_in
          | :audio_out
          | :video_in
          | :display
          | :input
          | :zigbee
          | :thread
          | :sensor
          | :presence
          | :light
  @type ref :: {node(), id()}
  @type t :: %__MODULE__{
          id: id(),
          kind: kind(),
          availability: :always | :on_request | :off,
          adapter: module() | {module(), keyword()} | nil,
          max_age: pos_integer() | nil,
          shared: boolean() | nil,
          meta: map()
        }

  def kinds, do: @kinds

  @doc "Lease max age in ms: the capability's own, else 10 min for capture kinds, 60 min otherwise."
  def max_age(%__MODULE__{max_age: ms}) when is_integer(ms), do: ms
  def max_age(%__MODULE__{kind: kind}) when kind in [:audio_in, :video_in], do: :timer.minutes(10)
  def max_age(%__MODULE__{}), do: :timer.minutes(60)

  @doc """
  Whether several leases can be held at once: the capability's own `shared`, else the
  kinds whose adapter mixes or layers them (`:audio_out`, `:display`).
  """
  def shareable?(%__MODULE__{shared: shared}) when is_boolean(shared), do: shared
  def shareable?(%__MODULE__{kind: kind}), do: kind in [:audio_out, :display]

  @doc """
  Start a capability on this node at runtime (see "Runtime capabilities").
  `cap` is a `Home.Capability` or a map/keyword of its fields.

  Returns `{:ok, pid}` once it is vended, or `{:error, reason}`: `:already_exists`
  (a static or runtime capability with that id runs here), `:off`,
  `{:unknown_kind, kind}`, or the server's init error.
  """
  @spec add(t() | map() | keyword()) :: {:ok, pid()} | {:error, term()}
  def add(%__MODULE__{} = cap) do
    cond do
      cap.kind not in @kinds ->
        {:error, {:unknown_kind, cap.kind}}

      cap.availability == :off ->
        {:error, :off}

      true ->
        # Check-then-start under a node-local lock so two adds of one id can't race.
        :global.trans({{__MODULE__, cap.id}, self()}, fn -> start_runtime(cap) end, [node()])
    end
  end

  def add(attrs) when is_map(attrs) or is_list(attrs), do: add(struct!(__MODULE__, attrs))

  defp start_runtime(cap) do
    if local_server(cap.id) do
      {:error, :already_exists}
    else
      case DynamicSupervisor.start_child(__MODULE__.Runtime, __MODULE__.Server.child_spec(cap)) do
        {:ok, pid} -> {:ok, pid}
        {:error, {reason, _child}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Remove a runtime capability from this node: its leases are revoked (holders get
  `{:lease_revoked, ref}`), its hardware is turned off and it stops being vended.
  Returns `{:error, :not_found}` for an unknown id and `{:error, :static}` for a
  manifest capability.
  """
  @spec remove(id()) :: :ok | {:error, :not_found | :static}
  def remove(id) do
    case local_server(id) do
      nil ->
        {:error, :not_found}

      pid ->
        if pid in runtime_pids(),
          do: __MODULE__.Server.remove(pid),
          else: {:error, :static}
    end
  end

  @doc "Ids of the capabilities added on this node at runtime."
  @spec runtime() :: [id()]
  def runtime do
    for pid <- runtime_pids(), info = safe_info(pid), do: info.cap.id
  end

  defp runtime_pids do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(__MODULE__.Runtime),
        is_pid(pid),
        do: pid
  end

  defp safe_info(pid) do
    __MODULE__.Server.info(pid)
  catch
    :exit, _ -> nil
  end

  defp local_server(id) do
    case :pg.get_local_members(:home, {:cap, node(), id}) do
      [pid | _] -> pid
      [] -> nil
    end
  end
end
