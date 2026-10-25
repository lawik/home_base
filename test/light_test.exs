defmodule Home.LightTest do
  use ExUnit.Case, async: true

  defmodule FakeStrip do
    @behaviour Home.Light.Driver
    @impl true
    def info(_ref), do: %{addressable: true, color_modes: [:rgb], leds: 3}
    @impl true
    def set_color(ref, rgb), do: tell(ref, {:set_color, rgb})
    @impl true
    def set_frame(ref, frame), do: tell(ref, {:set_frame, frame})
    @impl true
    def off(ref), do: tell(ref, :off)

    defp tell(ref, msg) do
      send(ref, msg)
      :ok
    end
  end

  defp lease(endpoint) do
    %Home.Lease{
      ref: make_ref(),
      cap: {node(), "led0"},
      holder: self(),
      server: self(),
      endpoint: endpoint
    }
  end

  test "adapter needs a driver and exposes it as the endpoint" do
    cap = %Home.Capability{id: "led0", kind: :light, meta: %{driver: {FakeStrip, self()}}}
    {:ok, state} = Home.Adapters.Light.init(cap)
    assert Home.Adapters.Light.endpoint(state) == {FakeStrip, self()}
    assert {:ok, _} = Home.Adapters.Light.stop(state)
    assert_received :off

    assert {:error, {:no_driver, "led0"}} =
             Home.Adapters.Light.init(%Home.Capability{id: "led0", kind: :light})
  end

  test ":light is a capability kind" do
    assert :light in Home.Capability.kinds()
    refute Home.Capability.shareable?(%Home.Capability{id: "l", kind: :light})
  end

  test "the lease API calls the driver on the owning node" do
    lease = lease({FakeStrip, self()})
    assert %{addressable: true, leds: 3} = Home.Light.info(lease)
    assert :ok = Home.Light.set_color(lease, {255, 80, 0})
    assert_received {:set_color, {255, 80, 0}}
    assert :ok = Home.Light.set_frame(lease, <<1, 2, 3, 4, 5, 6>>)
    assert_received {:set_frame, <<1, 2, 3, 4, 5, 6>>}
    assert :ok = Home.Light.off(lease)
    assert_received :off
    assert {:error, {:not_a_light, :spk}} = Home.Light.off(lease(:spk))
  end
end
