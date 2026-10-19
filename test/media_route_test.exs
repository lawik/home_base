defmodule Home.MediaRouteTest do
  use ExUnit.Case, async: true

  @guest {10, 0, 3, 15}
  @lo {127, 0, 0, 1}

  test "no routes leaves destinations alone" do
    assert Home.Media.route([{@guest, 41_480}], %{}) == [{@guest, 41_480}]
  end

  test "an ip route keeps the port" do
    assert Home.Media.route([{@guest, 41_480}, {@lo, 1}], %{@guest => @lo}) ==
             [{@lo, 41_480}, {@lo, 1}]
  end

  test "an exact {ip, port} route wins over an ip route" do
    routes = %{@guest => @lo, {@guest, 41_480} => {@lo, 5_000}}

    assert Home.Media.route([{@guest, 41_480}, {@guest, 41_481}], routes) ==
             [{@lo, 5_000}, {@lo, 41_481}]
  end
end
