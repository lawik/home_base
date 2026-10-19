defmodule Home.Test.Peer do
  @moduledoc false
  # Starts BEAM peers on 127.0.0.1, each running its own Home supervisor.

  def start(name, home_opts) do
    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())],
        wait_boot: 30_000
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :erpc.call(node, __MODULE__, :boot, [home_opts])
    {peer, node}
  end

  def stop(peer) do
    :peer.stop(peer)
  catch
    :exit, _ -> :ok
  end

  @doc false
  def boot(home_opts) do
    Logger.configure(level: :warning)
    Application.load(:home_base)
    for {k, v} <- home_opts, do: Application.put_env(:home_base, k, v)
    {:ok, _} = Application.ensure_all_started(:home_base)
    {:ok, Process.whereis(Home)}
  end

  def rpc(node, mod, fun, args \\ []), do: :erpc.call(node, mod, fun, args, 15_000)

  def eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          raise ExUnit.AssertionError, message: "condition not met in time"
        else
          Process.sleep(50)
          do_eventually(fun, deadline)
        end

      value ->
        value
    end
  end
end
