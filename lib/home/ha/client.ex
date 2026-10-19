defmodule Home.HA.Client do
  @moduledoc """
  Minimal Home Assistant WebSocket API client: authenticate, send commands, get results.
  Each call opens a connection, runs its commands and closes; placement changes rarely.
  """

  @timeout 10_000

  @doc """
  The area name for the HA device whose `identifiers` include `device_id` (as sent in
  MQTT discovery, e.g. `["mqtt", device_id]`). `{:ok, nil}` if the device has no area.
  """
  def area_for_device(url, token, device_id) do
    with {:ok, [devices, areas]} <-
           run(url, token, [
             %{type: "config/device_registry/list"},
             %{type: "config/area_registry/list"}
           ]) do
      case Enum.find(devices, &has_identifier?(&1, device_id)) do
        nil ->
          {:error, {:device_not_found, device_id}}

        %{"area_id" => nil} ->
          {:ok, nil}

        %{"area_id" => area_id} ->
          {:ok, Enum.find_value(areas, fn a -> a["area_id"] == area_id && a["name"] end)}
      end
    end
  end

  defp has_identifier?(device, device_id) do
    Enum.any?(device["identifiers"] || [], fn
      [_domain, ^device_id] -> true
      _ -> false
    end)
  end

  @doc "Run commands in order over one authenticated connection; returns their results."
  def run(url, token, commands) do
    uri = URI.parse(url)
    {http, ws} = if uri.scheme in ["https", "wss"], do: {:https, :wss}, else: {:http, :ws}
    port = uri.port || if(http == :https, do: 443, else: 80)

    with {:ok, conn} <- Mint.HTTP.connect(http, uri.host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws, conn, "/api/websocket", []),
         {:ok, conn, ws_state} <- await_upgrade(conn, ref) do
      session = %{conn: conn, ref: ref, ws: ws_state, buffer: []}

      try do
        with {:ok, session, %{"type" => "auth_required"}} <- recv(session),
             {:ok, session} <- send_json(session, %{type: "auth", access_token: token}),
             {:ok, session, %{"type" => "auth_ok"}} <- recv(session) do
          commands
          |> Enum.with_index(1)
          |> Enum.reduce_while({:ok, session, []}, fn {cmd, id}, {:ok, session, acc} ->
            with {:ok, session} <- send_json(session, Map.put(cmd, :id, id)),
                 {:ok, session, %{"id" => ^id, "success" => true, "result" => r}} <- recv(session) do
              {:cont, {:ok, session, [r | acc]}}
            else
              {:ok, _session, other} -> {:halt, {:error, {:ha, other}}}
              error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, _session, results} -> {:ok, Enum.reverse(results)}
            error -> error
          end
        else
          {:ok, _session, %{"type" => "auth_invalid"} = msg} ->
            {:error, {:auth_invalid, msg["message"]}}

          {:ok, _session, other} ->
            {:error, {:unexpected, other}}

          error ->
            error
        end
      after
        Mint.HTTP.close(session.conn)
      end
    end
  end

  defp await_upgrade(conn, ref, acc \\ %{}) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            acc =
              Enum.reduce(responses, acc, fn
                {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
                {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
                {:done, ^ref}, acc -> Map.put(acc, :done, true)
                _, acc -> acc
              end)

            if acc[:done] do
              Mint.WebSocket.new(conn, ref, acc.status, acc.headers)
            else
              await_upgrade(conn, ref, acc)
            end

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            await_upgrade(conn, ref, acc)
        end
    after
      @timeout -> {:error, :timeout}
    end
  end

  defp send_json(session, map) do
    {:ok, ws, data} = Mint.WebSocket.encode(session.ws, {:text, Jason.encode!(map)})

    case Mint.WebSocket.stream_request_body(session.conn, session.ref, data) do
      {:ok, conn} -> {:ok, %{session | conn: conn, ws: ws}}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp recv(%{buffer: [msg | rest]} = session), do: {:ok, %{session | buffer: rest}, msg}

  defp recv(session) do
    receive do
      message ->
        case Mint.WebSocket.stream(session.conn, message) do
          {:ok, conn, responses} ->
            {ws, frames} =
              Enum.reduce(responses, {session.ws, []}, fn
                {:data, ref, data}, {ws, acc} when ref == session.ref ->
                  {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)
                  {ws, acc ++ frames}

                _, acc ->
                  acc
              end)

            msgs = for {:text, text} <- frames, do: Jason.decode!(text)
            recv(%{session | conn: conn, ws: ws, buffer: session.buffer ++ msgs})

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            recv(session)
        end
    after
      @timeout -> {:error, :timeout}
    end
  end
end
