defmodule HomeNode.Distribution do
  @moduledoc """
  Names this node after its address and then starts `home_base`.

  Waits until `interface` has an IPv4 address, starts distribution as
  `<basename>@<that address>` with the release cookie, then starts the `:home_base`
  application. home_base has to come after distribution: its `:pg` groups and node state
  are keyed on `node()`.

  The same address is the default media address (`config :home_base, media: [ip: ...]`):
  sinks on this node bind it and advertise it to sources.

  Today the interface is `eth0` (qemu, Ethernet); with Tailscale it becomes `tailscale0`
  and the node is `home@<tailscale ip>` (plan §2.1).

      config :home_node, :distribution,
        interface: "eth0",
        basename: "home",
        poll: 500
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      interface: Keyword.get(opts, :interface, "eth0") |> to_charlist(),
      basename: Keyword.get(opts, :basename, "home"),
      poll: Keyword.get(opts, :poll, 500)
    }

    {:ok, state, {:continue, :wait}}
  end

  @impl true
  def handle_continue(:wait, state), do: handle_info(:poll, state)

  @impl true
  def handle_info(:poll, state) do
    case ipv4(state.interface) do
      {:ok, ip} ->
        start(state, ip)
        {:noreply, state}

      :error ->
        Process.send_after(self(), :poll, state.poll)
        {:noreply, state}
    end
  end

  defp start(state, ip) do
    name = :"#{state.basename}@#{:inet.ntoa(ip)}"

    unless Node.alive?() do
      {:ok, _} = Node.start(name, :longnames)
      Logger.info("distribution started as #{name}")
    end

    media = Application.get_env(:home_base, :media, [])
    Application.put_env(:home_base, :media, Keyword.put_new(media, :ip, ip))

    {:ok, _} = Application.ensure_all_started(:home_base, :permanent)
    Logger.info("home_base started on #{node()}")
  end

  defp ipv4(interface) do
    with {:ok, ifaddrs} <- :inet.getifaddrs(),
         {_, opts} <- List.keyfind(ifaddrs, interface, 0),
         ip when is_tuple(ip) <-
           Enum.find(Keyword.get_values(opts, :addr), &(tuple_size(&1) == 4)) do
      {:ok, ip}
    else
      _ -> :error
    end
  end
end
