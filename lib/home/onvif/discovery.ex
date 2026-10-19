defmodule Home.Onvif.Discovery do
  @moduledoc """
  WS-Discovery for ONVIF devices: a `Probe` for `dn:NetworkVideoTransmitter` sent to the
  multicast group 239.255.255.250:3702 and/or directly (unicast) to given hosts, for
  networks where multicast doesn't get through (Wi-Fi isolation, VLANs, tailnets).
  Every `ProbeMatch` that comes back within the timeout becomes one
  `%Home.Onvif.Discovery{}`, deduplicated by endpoint address.

  `ExOnvif.Discovery` only probes by multicast and keeps its parser private, so this
  module builds the probe and parses matches itself (SweetXml, as ExOnvif does).
  """

  import SweetXml, only: [sigil_x: 2, xpath: 2, xpath: 3, add_namespace: 3, transform_by: 2]
  require Logger

  @group {239, 255, 255, 250}
  @port 3702
  @timeout 2_000

  @soap "http://www.w3.org/2003/05/soap-envelope"
  @wsa "http://schemas.xmlsoap.org/ws/2004/08/addressing"
  @wsd "http://schemas.xmlsoap.org/ws/2005/04/discovery"

  defstruct [:endpoint, :name, :hardware, :from, xaddrs: [], types: [], scopes: []]

  @type t :: %__MODULE__{
          endpoint: String.t(),
          name: String.t() | nil,
          hardware: String.t() | nil,
          from: {:inet.ip_address(), :inet.port_number()},
          xaddrs: [String.t()],
          types: [String.t()],
          scopes: [String.t()]
        }

  @doc """
  Probe and collect matches for `:timeout` ms.

  Options:

    * `:multicast` - probe the multicast group (default `true`).
    * `:hosts` - unicast targets: `"10.0.0.5"`, `"10.0.0.5:3702"` or `{ip, port}`.
    * `:timeout` - how long to collect matches, ms (#{@timeout}).
    * `:ip` - local address to send from (and the multicast interface).
    * `:port` - destination port for hosts given without one, and for multicast (3702).
  """
  @spec probe(keyword()) :: [t()]
  def probe(opts \\ []) do
    port = Keyword.get(opts, :port, @port)
    timeout = Keyword.get(opts, :timeout, @timeout)
    message_id = "uuid:" <> uuid()

    socket_opts =
      [:binary, active: true, multicast_ttl: 2, multicast_loop: true] ++
        case Keyword.get(opts, :ip) do
          nil -> []
          ip -> [ip: parse_ip!(ip), multicast_if: parse_ip!(ip)]
        end

    {:ok, socket} = :gen_udp.open(0, socket_opts)
    payload = probe_message(message_id)

    targets =
      if(Keyword.get(opts, :multicast, true), do: [{@group, port}], else: []) ++
        Enum.map(Keyword.get(opts, :hosts, []), &target(&1, port))

    for {ip, p} <- targets do
      case :gen_udp.send(socket, ip, p, payload) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("onvif probe to #{:inet.ntoa(ip)}:#{p}: #{inspect(reason)}")
      end
    end

    deadline = System.monotonic_time(:millisecond) + timeout
    matches = collect(socket, message_id, deadline, %{})
    :gen_udp.close(socket)
    Map.values(matches) |> Enum.sort_by(& &1.endpoint)
  end

  defp collect(socket, message_id, deadline, acc) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:udp, ^socket, ip, port, data} ->
        acc =
          data
          |> parse(message_id)
          |> Enum.reduce(acc, fn match, acc ->
            Map.put_new(acc, match.endpoint, %{match | from: {ip, port}})
          end)

        collect(socket, message_id, deadline, acc)
    after
      wait -> acc
    end
  end

  @doc false
  # The ProbeMatches in `data` that answer `message_id` (any, if nil).
  def parse(data, message_id \\ nil) do
    doc = SweetXml.parse(data, namespace_conformant: true, quiet: true)

    relates_to =
      xpath(doc, ns(~x"/s:Envelope/s:Header/a:RelatesTo/text()"s))

    if message_id == nil or relates_to == message_id do
      doc
      |> xpath(ns(~x"/s:Envelope/s:Body/d:ProbeMatches/d:ProbeMatch"l),
        endpoint: ns(~x"./a:EndpointReference/a:Address/text()"s),
        types: ns(~x"./d:Types/text()"s) |> transform_by(&String.split/1),
        scopes: ns(~x"./d:Scopes/text()"s) |> transform_by(&String.split/1),
        xaddrs: ns(~x"./d:XAddrs/text()"s) |> transform_by(&String.split/1)
      )
      |> Enum.map(fn match ->
        struct!(__MODULE__,
          endpoint: match.endpoint,
          types: match.types,
          scopes: match.scopes,
          # Link-local addresses are rarely reachable from elsewhere; keep them last.
          xaddrs: Enum.sort_by(match.xaddrs, &String.contains?(&1, "//169.254.")),
          name: scope(match.scopes, "name"),
          hardware: scope(match.scopes, "hardware")
        )
      end)
    else
      []
    end
  catch
    # Not XML, or not WS-Discovery: some other device on the multicast group.
    :exit, _ -> []
  end

  defp scope(scopes, key) do
    Enum.find_value(scopes, fn scope ->
      case String.split(scope, "onvif://www.onvif.org/#{key}/", parts: 2) do
        ["", value] -> URI.decode(value)
        _ -> nil
      end
    end)
  end

  defp ns(xpath) do
    xpath
    |> add_namespace("s", @soap)
    |> add_namespace("a", @wsa)
    |> add_namespace("d", @wsd)
  end

  @doc false
  def probe_message(message_id) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <s:Envelope xmlns:s="#{@soap}" xmlns:a="#{@wsa}" xmlns:d="#{@wsd}" \
    xmlns:dn="http://www.onvif.org/ver10/network/wsdl">\
    <s:Header>\
    <a:MessageID>#{message_id}</a:MessageID>\
    <a:To s:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>\
    <a:Action s:mustUnderstand="true">#{@wsd}/Probe</a:Action>\
    </s:Header>\
    <s:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></s:Body>\
    </s:Envelope>\
    """
  end

  defp target({ip, port}, _default) when is_tuple(ip), do: {ip, port}

  defp target(host, default) when is_binary(host) do
    case String.split(host, ":") do
      [h, p] -> {resolve!(h), String.to_integer(p)}
      [h] -> {resolve!(h), default}
    end
  end

  defp resolve!(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> ip
      {:error, reason} -> raise ArgumentError, "can't resolve #{host}: #{inspect(reason)}"
    end
  end

  defp parse_ip!(ip) when is_tuple(ip), do: ip
  defp parse_ip!(ip) when is_binary(ip), do: resolve!(ip)

  defp uuid, do: Ecto.UUID.generate()
end
