defmodule Home.Media.UDPEndpoint do
  @moduledoc """
  Membrane endpoint for one RTP flow: sends what comes in on `:input` from a UDP socket
  on `local_address:local_port_no` to the destination, and puts out what arrives on that
  socket (a sink's RTCP at a source; the RTP itself at a sink).

  `Membrane.UDP.Endpoint`, which it replaces in the media pipelines, raises when a send
  fails, which takes the whole session down. Here a packet that can't be sent is
  dropped: a camera keyframe's burst can fill the socket's send buffer (`:eagain`,
  `:enobufs`), most of all through Tailscale's tunnel, and a peer that just went away
  answers `:econnrefused` or `:ehostunreach`. NACKs and PLIs recover what's lost, and a
  session whose peer is really gone ends when its node does. Drops are counted and logged
  at most every few seconds.

  As with `Membrane.UDP.Endpoint`: the parent gets `{:connection_info, ip, port}` once the
  socket is open, and with `latch?` the destination follows the source of the latest
  packet received.
  """

  use Membrane.Endpoint

  require Membrane.Logger

  alias Membrane.{Buffer, RemoteStream}

  @log_every_ms 5_000

  def_options(
    destination_address: [spec: :inet.ip_address(), description: "Where packets go."],
    destination_port_no: [spec: :inet.port_number(), description: "Their port."],
    local_address: [spec: :inet.ip_address(), default: {0, 0, 0, 0}],
    local_port_no: [spec: :inet.port_number(), default: 0, description: "0 for any."],
    recv_buffer_size: [spec: pos_integer(), default: 1024 * 1024],
    latch?: [
      spec: boolean(),
      default: false,
      description: "Send to wherever the latest received packet came from."
    ]
  )

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: %RemoteStream{type: :packetized}, flow_control: :push)

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       opts: opts,
       socket: nil,
       destination: {opts.destination_address, opts.destination_port_no},
       dropped: %{},
       logged_at: nil
     }}
  end

  @impl true
  def handle_setup(ctx, state) do
    socket_opts = [
      :binary,
      ip: state.opts.local_address,
      active: true,
      recbuf: state.opts.recv_buffer_size
    ]

    case :gen_udp.open(state.opts.local_port_no, socket_opts) do
      {:ok, socket} ->
        {:ok, {ip, port}} = :inet.sockname(socket)
        Membrane.ResourceGuard.register(ctx.resource_guard, fn -> :gen_udp.close(socket) end)
        {[notify_parent: {:connection_info, ip, port}], %{state | socket: socket}}

      {:error, reason} ->
        raise "Error opening UDP socket, reason: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_playing(_ctx, state),
    do: {[stream_format: {:output, %RemoteStream{type: :packetized}}], state}

  @impl true
  def handle_buffer(:input, %Buffer{payload: payload}, _ctx, state) do
    {ip, port} = state.destination

    case :gen_udp.send(state.socket, ip, port, payload) do
      :ok -> {[], state}
      {:error, reason} -> {[], dropped(state, reason)}
    end
  end

  @impl true
  def handle_info({:udp, _socket, ip, port, payload}, %{playback: :playing}, state) do
    state = if state.opts.latch?, do: %{state | destination: {ip, port}}, else: state

    buffer = %Buffer{
      payload: payload,
      metadata: %{
        udp_source_address: ip,
        udp_source_port: port,
        arrival_ts: Membrane.Time.vm_time()
      }
    }

    {[buffer: {:output, buffer}], state}
  end

  def handle_info({:udp, _socket, _ip, _port, _payload}, _ctx, state), do: {[], state}

  def handle_info(_msg, _ctx, state), do: {[], state}

  defp dropped(state, reason) do
    state = %{state | dropped: Map.update(state.dropped, reason, 1, &(&1 + 1))}
    now = System.monotonic_time(:millisecond)

    if state.logged_at == nil or now - state.logged_at >= @log_every_ms do
      {ip, port} = state.destination

      Membrane.Logger.warning(
        "UDP to #{:inet.ntoa(ip)}:#{port}: dropped packets the socket couldn't send " <>
          inspect(state.dropped)
      )

      %{state | logged_at: now}
    else
      state
    end
  end
end
