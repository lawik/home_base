System.cmd("epmd", ["-daemon"])
{:ok, _} = :net_kernel.start(:"primary#{System.pid()}@127.0.0.1", %{name_domain: :longnames})
# Per-run cookie: parallel test runs on this host must not mesh with each other.
Node.set_cookie(:"home_test_#{System.pid()}")
ExUnit.start()
