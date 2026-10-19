System.cmd("epmd", ["-daemon"])
{:ok, _} = :net_kernel.start(:"primary#{System.pid()}@127.0.0.1", %{name_domain: :longnames})

# The test node only drives peers. It must not be a home_base member itself (it would mesh
# with other test runs' nodes through epmd and leak secrets/activity into the peers), and
# each run gets its own cookie so concurrent runs on this machine can't connect at all.
Application.stop(:home_base)
Node.set_cookie(:"home_test_#{System.pid()}")

# Element events for pixel forwarding and display-side hit-testing need
# `EmergeSkia.inject_input/2`, which the precompiled 0.5.0 NIF lacks: build emerge's NIF
# from source (`EMERGE_SKIA_BUILD=true`, see docs/EMERGE-FORWARDING.md) to run them.
inject = if Home.Test.Render.inject_supported?(), do: [], else: [:emerge_inject]

ExUnit.start(exclude: [:portaudio, :v4l2] ++ inject)
