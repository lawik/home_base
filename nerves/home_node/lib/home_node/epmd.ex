defmodule HomeNode.Epmd do
  @moduledoc """
  An epmd replacement (`kernel` `epmd_module`) for a home cluster: no epmd daemon, every
  node listens on one fixed distribution port, and a node's address is the host part of
  its name. That is what the Tailscale setup wants (plan §2.2), and stock `erl_epmd` with
  `-start_epmd false -erl_epmd_port 4370` does the same.

  On top of that it takes static routes, for when the address a peer must dial is not the
  one in the node's name. That is the case behind NAT, e.g. a qemu guest on user-mode
  networking: the guest is `home@10.0.3.15` but the host reaches it through a `hostfwd`
  port on 127.0.0.1. Node names must stay the same on both sides (the handshake checks
  them), so the route rewrites only where the TCP connection goes.

  Configured from the `:home_node` app env, read when distribution starts and on every
  connection attempt:

      config :kernel, epmd_module: HomeNode.Epmd
      config :home_node, :epmd,
        port: 4370,
        routes: %{"home@10.0.3.15" => {{127, 0, 0, 1}, 41470}}

    * `:port` - the port every node listens on and is dialed at, unless a route says
      otherwise. Default 4370.
    * `:routes` - `%{"name@host" => {ip_tuple, port}}`. A route for this node's own name
      sets its listen port (the ip part is then ignored; use kernel's
      `inet_dist_use_interface` to bind an address).
  """

  @default_port 4370

  # The epmd module is started under net_sup; there is nothing to run.
  def start_link, do: :ignore

  def register_node(name, port), do: register_node(name, port, :inet)
  # No epmd to register with. A creation in 1..3 like epmd hands out.
  def register_node(_name, _port, _family), do: {:ok, :rand.uniform(3)}

  def listen_port_please(name, host) do
    case route(name, host) do
      {_ip, port} -> {:ok, port}
      nil -> {:ok, port()}
    end
  end

  def address_please(name, host, family) do
    case route(name, host) do
      {ip, port} ->
        {:ok, ip, port, 6}

      nil ->
        with {:ok, ip} <- :inet.getaddr(host, family), do: {:ok, ip, port(), 6}
    end
  end

  def port_please(name, host), do: port_please(name, host, :infinity)

  def port_please(name, host, _timeout) do
    case route(name, host) do
      {_ip, port} -> {:port, port, 6}
      nil -> {:port, port(), 6}
    end
  end

  def names(_host), do: {:error, :address}

  defp route(name, host) do
    host = if is_tuple(host), do: :inet.ntoa(host), else: host
    Map.get(config(:routes, %{}), "#{name}@#{host}")
  end

  defp port, do: config(:port, @default_port)

  defp config(key, default) do
    :home_node |> Application.get_env(:epmd, []) |> Keyword.get(key, default)
  end
end
