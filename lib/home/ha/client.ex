defmodule Home.HA.Client do
  @moduledoc """
  Minimal Home Assistant WebSocket API client: authenticate, send commands, get results.
  Each call opens a connection, runs its commands and closes; placement changes rarely.

  The socket is used in passive mode, so the client never touches the calling process's
  mailbox (it runs inside `Home.Registry`).
  """

  @timeout 10_000

  @doc """
  The area name for the HA device whose `identifiers` include `device_id` (as sent in
  MQTT discovery, e.g. `["mqtt", device_id]`). `{:ok, nil}` if the device has no area.
  """
  def area_for_device(url, token, device_id, opts \\ []) do
    with {:ok, [devices, areas]} <-
           run(
             url,
             token,
             [%{type: "config/device_registry/list"}, %{type: "config/area_registry/list"}],
             opts
           ) do
      case Enum.find(devices, &has_identifier?(&1, device_id)) do
        nil ->
          {:error, {:device_not_found, device_id}}

        %{"area_id" => area_id} when is_binary(area_id) ->
          case Enum.find(areas, &(&1["area_id"] == area_id)) do
            %{"name" => name} -> {:ok, name}
            nil -> {:error, {:area_not_found, area_id}}
          end

        _no_area ->
          {:ok, nil}
      end
    end
  end

  defp has_identifier?(device, device_id) do
    Enum.any?(device["identifiers"] || [], fn
      [_domain, ^device_id] -> true
      _ -> false
    end)
  end

  @doc """
  Run commands in order over one authenticated connection; returns their results.
  `opts`: `timeout:` per network step in ms (default 10 s).
  """
  def run(url, token, commands, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    uri = URI.parse(url)
    {http, ws} = if uri.scheme in ["https", "wss"], do: {:https, :wss}, else: {:http, :ws}
    port = uri.port || if(http == :https, do: 443, else: 80)

    connect_opts = [protocols: [:http1], mode: :passive, transport_opts: [timeout: timeout]]

    case Mint.HTTP.connect(http, uri.host, port, connect_opts) do
      {:ok, conn} ->
        session = %{conn: conn, ref: nil, ws: nil, buffer: [], timeout: timeout}

        try do
          with {:ok, session} <- upgrade(session, ws),
               {:ok, session} <- authenticate(session, token) do
            run_commands(session, commands)
          end
        after
          Mint.HTTP.close(session.conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upgrade(session, ws) do
    case Mint.WebSocket.upgrade(ws, session.conn, "/api/websocket", []) do
      {:ok, conn, ref} -> await_upgrade(%{session | conn: conn, ref: ref}, %{data: []})
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp await_upgrade(session, acc) do
    case Mint.HTTP.recv(session.conn, 0, session.timeout) do
      {:ok, conn, responses} ->
        ref = session.ref

        acc =
          Enum.reduce(responses, acc, fn
            {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
            {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
            # Frames sent right after the 101 (HA's auth_required) can arrive with it.
            {:data, ^ref, data}, acc -> %{acc | data: [data | acc.data]}
            {:done, ^ref}, acc -> Map.put(acc, :done, true)
            _, acc -> acc
          end)

        session = %{session | conn: conn}

        if acc[:done] do
          case Mint.WebSocket.new(conn, ref, acc.status, acc.headers, mode: :passive) do
            {:ok, conn, ws} ->
              decode(%{session | conn: conn, ws: ws}, Enum.reverse(acc.data))

            {:error, _conn, reason} ->
              {:error, reason}
          end
        else
          await_upgrade(session, acc)
        end

      {:error, _conn, reason, _} ->
        {:error, reason}
    end
  end

  defp authenticate(session, token) do
    with {:ok, session, %{"type" => "auth_required"}} <- recv(session),
         {:ok, session} <- send_json(session, %{type: "auth", access_token: token}),
         {:ok, session, %{"type" => "auth_ok"}} <- recv(session) do
      {:ok, session}
    else
      {:ok, _session, %{"type" => "auth_invalid"} = msg} ->
        {:error, {:auth_invalid, msg["message"]}}

      {:ok, _session, other} ->
        {:error, {:unexpected, other}}

      error ->
        error
    end
  end

  defp run_commands(session, commands) do
    commands
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, session, []}, fn {cmd, id}, {:ok, session, acc} ->
      with {:ok, session} <- send_json(session, Map.put(cmd, :id, id)),
           {:ok, session, %{"id" => ^id, "type" => "result", "success" => true} = msg} <-
             recv(session) do
        {:cont, {:ok, session, [msg["result"] | acc]}}
      else
        {:ok, _session, %{"success" => false, "error" => error}} ->
          {:halt, {:error, {:ha, error}}}

        {:ok, _session, other} ->
          {:halt, {:error, {:unexpected, other}}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _session, results} -> {:ok, Enum.reverse(results)}
      error -> error
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
    case Mint.WebSocket.recv(session.conn, 0, session.timeout) do
      {:ok, conn, responses} ->
        data = for {:data, ref, data} <- responses, ref == session.ref, do: data

        with {:ok, session} <- decode(%{session | conn: conn}, data), do: recv(session)

      {:error, _conn, reason, _} ->
        {:error, reason}
    end
  end

  # Decode raw websocket data into JSON messages appended to the buffer. HA may coalesce
  # several messages into one JSON array.
  defp decode(session, chunks) do
    Enum.reduce_while(chunks, {:ok, session}, fn data, {:ok, session} ->
      case Mint.WebSocket.decode(session.ws, data) do
        {:ok, ws, frames} ->
          msgs =
            Enum.flat_map(frames, fn
              {:text, text} -> text |> Jason.decode!() |> List.wrap()
              _ -> []
            end)

          {:cont, {:ok, %{session | ws: ws, buffer: session.buffer ++ msgs}}}

        {:error, _ws, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
end
