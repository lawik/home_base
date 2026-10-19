defmodule HomeNode.EpmdTest do
  use ExUnit.Case, async: false

  alias HomeNode.Epmd

  setup do
    Application.put_env(:home_node, :epmd,
      port: 4370,
      routes: %{"home@10.0.3.15" => {{127, 0, 0, 1}, 41470}}
    )

    on_exit(fn -> Application.delete_env(:home_node, :epmd) end)
  end

  test "unrouted nodes are dialed at the host in their name on the fixed port" do
    assert Epmd.address_please(~c"home", ~c"100.64.0.7", :inet) == {:ok, {100, 64, 0, 7}, 4370, 6}
    assert Epmd.port_please(~c"home", {100, 64, 0, 7}) == {:port, 4370, 6}
    assert Epmd.listen_port_please(~c"home", ~c"100.64.0.7") == {:ok, 4370}
  end

  test "a route rewrites the address and port but not the name" do
    assert Epmd.address_please(~c"home", ~c"10.0.3.15", :inet) == {:ok, {127, 0, 0, 1}, 41470, 6}
    assert Epmd.port_please(~c"home", {10, 0, 3, 15}) == {:port, 41470, 6}
    assert Epmd.listen_port_please(~c"home", ~c"10.0.3.15") == {:ok, 41470}
  end

  test "no epmd" do
    assert Epmd.start_link() == :ignore
    assert {:ok, creation} = Epmd.register_node(~c"home", 4370, :inet)
    assert creation in 1..3
    assert Epmd.names(~c"localhost") == {:error, :address}
  end
end
