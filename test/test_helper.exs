System.cmd("epmd", ["-daemon"])
{:ok, _} = :net_kernel.start(:"primary#{System.pid()}@127.0.0.1", %{name_domain: :longnames})
Node.set_cookie(:home_test_cookie)
ExUnit.start(exclude: [:portaudio])
