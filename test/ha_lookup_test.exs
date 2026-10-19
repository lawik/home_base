defmodule Home.HALookupTest do
  # The HA area lookup runs beside Home.Registry, not inside it.
  use Home.Test.ClusterCase, async: false

  alias Home.{Registry, Secrets}
  alias Home.Test.FakeHA

  @token "long-lived-token"

  defp start(ha_opts) do
    [{a, _}] =
      start_cluster("m9h",
        a: [
          device_id: "m9-dev-a",
          capabilities: [%{id: "spk0", kind: :audio_out, adapter: Home.Test.FakeAdapter}],
          ha: ha_opts
        ]
      )

    a
  end

  # An "HA" that accepts connections and never says anything. Reports each accept.
  defp hung_ha do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    acceptor = spawn(fn -> accept_forever(listen, test) end)
    on_exit(fn -> Process.exit(acceptor, :kill) end)
    {:ok, port} = :inet.port(listen)
    "http://127.0.0.1:#{port}"
  end

  defp accept_forever(listen, test) do
    case :gen_tcp.accept(listen) do
      # The socket stays open (and silent) as long as this process lives.
      {:ok, _sock} ->
        send(test, :accepted)
        accept_forever(listen, test)

      {:error, _} ->
        :ok
    end
  end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  defp provision(node, url) do
    :ok = rpc(node, Secrets, :put, [:ha_url, url])
    :ok = rpc(node, Secrets, :put, [:ha_token, @token])
  end

  test "a hung HA doesn't block the registry; queued refreshes share one lookup" do
    a = start(timeout: 1_000)
    :ok = rpc(a, Registry, :put_area, ["Kitchen"])
    provision(a, hung_ha())
    # The token arriving started a lookup.
    assert_receive :accepted, 1_000

    callers =
      for _ <- 1..5, do: Task.async(fn -> timed(fn -> rpc(a, Registry, :refresh_area) end) end)

    # Meanwhile the registry answers at once.
    Process.sleep(100)
    assert {ms, :ok} = timed(fn -> rpc(a, Registry, :put_area, ["Hall"]) end)
    assert ms < 200
    assert {ms, [_]} = timed(fn -> rpc(a, Registry, :list, [[kind: :audio_out]]) end)
    assert ms < 200

    # All five got the one lookup's answer, within its timeout, not one after another.
    for {ms, result} <- Task.await_many(callers) do
      assert result == {:error, %Mint.TransportError{reason: :timeout}}
      assert ms < 1_500
    end

    refute_received :accepted
    assert rpc(a, Registry, :area, []) == "Hall"
  end

  test "a lookup that runs past lookup_timeout is killed" do
    a = start(timeout: 5_000, lookup_timeout: 300)
    :ok = rpc(a, Registry, :put_area, ["Kitchen"])
    provision(a, hung_ha())

    assert {ms, {:error, :timeout}} = timed(fn -> rpc(a, Registry, :refresh_area) end)
    assert ms < 1_000
    assert rpc(a, Registry, :area, []) == "Kitchen"
  end

  test "new credentials restart a running lookup; its callers get the new answer" do
    ha = FakeHA.start(free_port(), @token, [{"m9-dev-a", "kitchen"}], [{"kitchen", "Kitchen"}])
    on_exit(fn -> FakeHA.stop(ha) end)

    a = start(timeout: 3_000)
    provision(a, hung_ha())
    assert_receive :accepted, 1_000

    caller = Task.async(fn -> timed(fn -> rpc(a, Registry, :refresh_area) end) end)
    Process.sleep(100)
    :ok = rpc(a, Secrets, :put, [:ha_url, ha.url])

    assert {ms, {:ok, "Kitchen"}} = Task.await(caller)
    assert ms < 1_500
    assert rpc(a, Registry, :area, []) == "Kitchen"
  end

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)
    port
  end
end
