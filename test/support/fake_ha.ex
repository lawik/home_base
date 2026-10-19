defmodule Home.Test.FakeHA do
  @moduledoc false
  # A Home Assistant WebSocket API stand-in (Bandit + WebSock), speaking the real protocol
  # subset home_base uses:
  #
  #   server: {"type":"auth_required","ha_version":...}
  #   client: {"type":"auth","access_token":...}
  #   server: {"type":"auth_ok","ha_version":...} | {"type":"auth_invalid","message":...} + close
  #   client: {"id":n,"type":"config/device_registry/list"}
  #   server: {"id":n,"type":"result","success":true,"result":[device, ...]}
  #
  # Device and area entries are shaped like HA's DeviceEntry.dict_repr / AreaEntry json.
  # Runs on the test node; peers reach it over 127.0.0.1.

  use Agent

  @doc """
  Start on `port`. `devices` is `[{device_id, area_id | nil}]`, `areas` `[{area_id, name}]`.
  """
  def start(port, token, devices, areas) do
    {:ok, agent} =
      Agent.start(fn ->
        %{
          token: token,
          devices: Map.new(devices),
          areas: Map.new(areas),
          requests: [],
          server: nil
        }
      end)

    ha = %{agent: agent, port: port, url: "http://127.0.0.1:#{port}"}
    up(ha)
  end

  @doc "Bring HA (back) up on its port. Returns `ha`."
  def up(%{agent: agent, port: port} = ha) do
    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, agent},
        ip: {127, 0, 0, 1},
        port: port,
        startup_log: false
      )

    Process.unlink(server)
    Agent.update(agent, &%{&1 | server: server})
    ha
  end

  @doc "Take HA down (its data is kept)."
  def down(%{agent: agent}) do
    case Agent.get_and_update(agent, &{&1.server, %{&1 | server: nil}}) do
      nil -> :ok
      server -> Supervisor.stop(server)
    end
  end

  def stop(%{agent: agent} = ha) do
    down(ha)
    Agent.stop(agent)
  end

  def move(%{agent: agent}, device_id, area_id),
    do: Agent.update(agent, &put_in(&1.devices[device_id], area_id))

  def put_area(%{agent: agent}, area_id, name),
    do: Agent.update(agent, &put_in(&1.areas[area_id], name))

  @doc "Commands received so far, oldest first."
  def requests(%{agent: agent}), do: Agent.get(agent, &Enum.reverse(&1.requests))

  @doc false
  def handle(agent, %{"type" => type} = msg) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | requests: [type | state.requests]}

      reply =
        case type do
          "config/device_registry/list" ->
            {:ok, Enum.map(state.devices, &device/1) ++ decoys()}

          "config/area_registry/list" ->
            {:ok, Enum.map(state.areas, &area/1)}

          _ ->
            {:error, "unknown_command", "Unknown command."}
        end

      {result(msg["id"], reply), state}
    end)
  end

  def token(agent), do: Agent.get(agent, & &1.token)

  defp result(id, {:ok, result}), do: %{id: id, type: "result", success: true, result: result}

  defp result(id, {:error, code, message}),
    do: %{id: id, type: "result", success: false, error: %{code: code, message: message}}

  defp device({device_id, area_id}) do
    %{
      area_id: area_id,
      configuration_url: nil,
      config_entries: ["01JCONFIGENTRYMQTT"],
      config_entries_subentries: %{"01JCONFIGENTRYMQTT" => [nil]},
      connections: [],
      created_at: 1_760_000_000.0,
      disabled_by: nil,
      entry_type: nil,
      hw_version: nil,
      id: "dev" <> Base.encode16(:crypto.hash(:md5, device_id), case: :lower),
      identifiers: [["mqtt", device_id]],
      labels: [],
      manufacturer: "home_base",
      model: "Nerves",
      model_id: nil,
      modified_at: 1_760_000_000.0,
      name_by_user: nil,
      name: device_id,
      primary_config_entry: "01JCONFIGENTRYMQTT",
      serial_number: nil,
      sw_version: "0.1.0",
      via_device_id: nil
    }
  end

  # Other devices in the registry: other integrations, a device with several identifiers,
  # a bare-string lookalike, and an identifier whose value is a prefix of ours.
  defp decoys do
    [
      %{device({"zigbee-0x00124b", "garage"}) | identifiers: [["zha", "00:12:4b:00:01"]]},
      %{device({"hue-bridge", "hall"}) | identifiers: [["hue", "001788fffe"], ["hue", "b1"]]},
      %{device({"other", nil}) | identifiers: [["mqtt", "m3-something-else"]]}
    ]
  end

  defp area({area_id, name}) do
    %{
      aliases: [],
      area_id: area_id,
      floor_id: nil,
      humidity_entity_id: nil,
      icon: nil,
      labels: [],
      name: name,
      picture: nil,
      temperature_entity_id: nil,
      created_at: 1_760_000_000.0,
      modified_at: 1_760_000_000.0
    }
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    @impl true
    def init(agent), do: agent

    @impl true
    def call(%{request_path: "/api/websocket"} = conn, agent) do
      conn
      |> WebSockAdapter.upgrade(Home.Test.FakeHA.Socket, agent, timeout: 60_000)
      |> Elixir.Plug.Conn.halt()
    end

    def call(conn, _agent), do: Elixir.Plug.Conn.send_resp(conn, 404, "not found")
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(agent) do
      msg = Jason.encode!(%{type: "auth_required", ha_version: "2026.10.0"})
      {:push, [{:text, msg}], %{agent: agent, authed: false, last_id: 0}}
    end

    @impl true
    def handle_in({text, opcode: :text}, state) do
      handle_msg(Jason.decode!(text), state)
    end

    defp handle_msg(%{"type" => "auth", "access_token" => token}, %{authed: false} = state) do
      if token == Home.Test.FakeHA.token(state.agent) do
        msg = Jason.encode!(%{type: "auth_ok", ha_version: "2026.10.0"})
        {:push, [{:text, msg}], %{state | authed: true}}
      else
        msg = Jason.encode!(%{type: "auth_invalid", message: "Invalid access token or password"})
        {:stop, :normal, 1000, [{:text, msg}], state}
      end
    end

    defp handle_msg(_msg, %{authed: false} = state) do
      msg = Jason.encode!(%{type: "auth_invalid", message: "Auth message incorrectly formatted"})
      {:stop, :normal, 1000, [{:text, msg}], state}
    end

    defp handle_msg(%{"id" => id} = msg, state) when is_integer(id) and id > state.last_id do
      reply = Home.Test.FakeHA.handle(state.agent, msg)
      {:push, [{:text, Jason.encode!(reply)}], %{state | last_id: id}}
    end

    defp handle_msg(msg, state) do
      reply = %{
        id: msg["id"],
        type: "result",
        success: false,
        error: %{code: "id_reuse", message: "Identifier values have to increase."}
      }

      {:push, [{:text, Jason.encode!(reply)}], state}
    end

    @impl true
    def handle_info(_msg, state), do: {:ok, state}
  end
end
