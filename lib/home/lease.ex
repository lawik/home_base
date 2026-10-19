defmodule Home.Lease do
  @moduledoc """
  All use of a capability goes through a lease.

      {:ok, lease} = Home.Lease.acquire({node, "mic0"}, for: self(), purpose: "intercom")
      :ok = Home.Lease.release(lease)

  The capability's server on the owning node is the single lease owner. It monitors the
  holder; holder death releases the lease. Leases older than the capability's max age
  (counted from the last `renew/1`) are expired by `Home.Lease.Watchdog`, and the holder
  gets `{:lease_expired, ref}`. `revoke_all/0` drops every lease on this node
  (holders get `{:lease_revoked, ref}`).
  """

  alias Home.Capability

  @enforce_keys [:ref, :cap, :holder, :server]
  defstruct [:ref, :cap, :holder, :server, :endpoint, :purpose]

  @type t :: %__MODULE__{
          ref: reference(),
          cap: Capability.ref(),
          holder: pid(),
          server: pid(),
          endpoint: term(),
          purpose: String.t() | nil
        }

  @spec acquire(Capability.ref(), keyword()) :: {:ok, t()} | {:error, term()}
  def acquire(cap_ref, opts \\ []) do
    holder = Keyword.get(opts, :for, self())
    timeout = Keyword.get(opts, :timeout, 10_000)

    with {:ok, pid} <- Home.Registry.whereis(cap_ref) do
      GenServer.call(pid, {:acquire, holder, Keyword.get(opts, :purpose)}, timeout)
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec release(t()) :: :ok
  def release(%__MODULE__{server: pid, ref: ref}) do
    GenServer.call(pid, {:release, ref})
  catch
    # The owning node or server is gone; so is the lease.
    :exit, _ -> :ok
  end

  @spec renew(t()) :: :ok | {:error, :unknown_lease}
  def renew(%__MODULE__{server: pid, ref: ref}), do: GenServer.call(pid, {:renew, ref})

  @doc "Make `pid` the holder: the lease now lives and dies with `pid` instead."
  @spec handover(t(), pid()) :: {:ok, t()} | {:error, :unknown_lease}
  def handover(%__MODULE__{server: server, ref: ref} = lease, pid) do
    with :ok <- GenServer.call(server, {:handover, ref, pid}) do
      {:ok, %{lease | holder: pid}}
    end
  end

  @doc "Drop every lease on this node and turn its on-request hardware off. No confirmation."
  @spec revoke_all() :: :ok
  def revoke_all do
    Enum.each(Home.Capability.Server.local_servers(), &GenServer.call(&1, :revoke_all))
  end
end
