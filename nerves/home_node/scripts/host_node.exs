# A long-running host member: nvN@10.0.3.2 vending one Null :audio_out capability.
#
#   cd <home_base repo root>
#   mix run --no-start --no-halt nerves/home_node/scripts/host_node.exs 2
#
# Prints node events; stop with Ctrl-C (or kill its pid).

Code.require_file("host_setup.exs", __DIR__)

n =
  case System.argv() do
    [n] -> String.to_integer(n)
    _ -> 2
  end

Logger.configure(level: :info)

node =
  HostNode.start(n, [
    %{id: "spk-nv#{n}", kind: :audio_out, adapter: Home.Adapters.Null, meta: %{channels: 2}}
  ])

IO.puts("#{node} up, cluster: #{inspect(Node.list())}")
:net_kernel.monitor_nodes(true)

Stream.repeatedly(fn ->
  receive do
    {:nodeup, peer} -> IO.puts("#{node}: nodeup #{peer}")
    {:nodedown, peer} -> IO.puts("#{node}: nodedown #{peer}")
  end
end)
|> Stream.run()
