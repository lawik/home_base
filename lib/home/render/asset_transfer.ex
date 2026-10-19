defmodule Home.Render.AssetTransfer do
  @moduledoc """
  The TCP side channel for large assets (§6.1: "A streams them once, over a TCP socket
  if large"). Small assets go to the display's compositor as one distribution message;
  an asset of `asset_tcp_threshold` bytes or more goes over a TCP connection instead,
  so a large image does not hold up the distribution link (heartbeats, other traffic)
  while it is copied.

  The display's node listens (`listen/3`, on its render address: `Home.config(:render)`
  `:ip`, default the media address, and `:asset_ports`, default an ephemeral port). The app's node connects (`send_file/3`), sends the
  one-time token and the bytes; the receiver checks size and sha256, stores the file
  in the cache and acks with one byte.

      config :home_base, render: [asset_tcp_threshold: 256 * 1024, asset_ports: 50_100..50_119]
  """

  require Logger

  @default_threshold 256 * 1024
  @timeout 30_000

  @doc "Assets of at least this many bytes go over TCP."
  def threshold,
    do: Keyword.get(Home.config(:render, []), :asset_tcp_threshold, @default_threshold)

  @doc "This node's address and TCP port range for receiving assets."
  def address do
    {media_ip, _ports} = Home.Media.address()
    render = Home.config(:render, [])
    {Keyword.get(render, :ip, media_ip), Keyword.get(render, :asset_ports, [0])}
  end

  @doc """
  Start a receiver for one asset of `size` bytes with sha256 `hash`, written to `dest`.
  Returns `{:ok, {ip, port, token}}` for the sender. The receiver gives up after 30 s.
  """
  def listen(hash, size, dest) do
    {ip, ports} = address()

    with {:ok, lsock, port} <- open(ip, Enum.to_list(ports)) do
      token = :crypto.strong_rand_bytes(16)

      {:ok, pid} =
        Task.start(fn ->
          receive do
            :go -> :ok
          end

          with {:error, reason} <- receive_one(lsock, token, size, hash, dest),
               do: Logger.warning("render: asset #{hash} over TCP failed: #{inspect(reason)}")
        end)

      :ok = :gen_tcp.controlling_process(lsock, pid)
      send(pid, :go)
      {:ok, {ip, port, token}}
    end
  end

  @doc "Send the file at `path` to a receiver started with `listen/3`. Waits for its ack."
  def send_file({ip, port, token}, path, timeout \\ @timeout) do
    with {:ok, sock} <-
           :gen_tcp.connect(ip, port, [:binary, active: false, packet: :raw], timeout) do
      try do
        with :ok <- :gen_tcp.send(sock, token),
             {:ok, _sent} <- :file.sendfile(path, sock),
             {:ok, <<1>>} <- :gen_tcp.recv(sock, 1, timeout) do
          :ok
        else
          {:ok, <<0>>} -> {:error, :rejected}
          error -> error
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end

  defp open(_ip, []), do: {:error, :no_free_port}

  defp open(ip, [port | rest]) do
    case :gen_tcp.listen(port, [:binary, ip: ip, active: false, packet: :raw, reuseaddr: true]) do
      {:ok, lsock} ->
        {:ok, port} = :inet.port(lsock)
        {:ok, lsock, port}

      {:error, :eaddrinuse} ->
        open(ip, rest)

      error ->
        error
    end
  end

  defp receive_one(lsock, token, size, hash, dest) do
    accepted = :gen_tcp.accept(lsock, @timeout)
    :gen_tcp.close(lsock)

    with {:ok, sock} <- accepted do
      try do
        result =
          with {:ok, ^token} <- :gen_tcp.recv(sock, byte_size(token), @timeout),
               :ok <- receive_file(sock, size, hash, dest) do
            :ok
          else
            {:ok, _other} -> {:error, :bad_token}
            error -> error
          end

        :gen_tcp.send(sock, if(result == :ok, do: <<1>>, else: <<0>>))
        result
      after
        :gen_tcp.close(sock)
      end
    end
  end

  defp receive_file(sock, size, hash, dest) do
    tmp = dest <> ".tmp#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.dirname(dest))

    result =
      File.open(tmp, [:write, :binary, :raw], fn file ->
        copy(sock, file, size, :crypto.hash_init(:sha256))
      end)

    case result do
      {:ok, {:ok, digest}} ->
        if Base.encode16(digest, case: :lower) == hash do
          File.rename!(tmp, dest)
          :ok
        else
          File.rm(tmp)
          {:error, :hash_mismatch}
        end

      {:ok, error} ->
        File.rm(tmp)
        error

      error ->
        File.rm(tmp)
        error
    end
  end

  defp copy(_sock, _file, 0, acc), do: {:ok, :crypto.hash_final(acc)}

  defp copy(sock, file, left, acc) do
    case :gen_tcp.recv(sock, min(left, 1024 * 1024), @timeout) do
      {:ok, data} ->
        :ok = :file.write(file, data)
        copy(sock, file, left - byte_size(data), :crypto.hash_update(acc, data))

      error ->
        error
    end
  end
end
