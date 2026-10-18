defmodule Aikido.Dsl.ExtensionOrderTest.MiddlewareA do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule Aikido.Dsl.ExtensionOrderTest.MiddlewareB do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule Aikido.Dsl.ExtensionOrderTest.MiddlewareC do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule Aikido.Dsl.ExtensionOrderTest.HostOrderTest do
  @moduledoc false
  use Aikido.Agent,
    middleware: [
      Aikido.Dsl.ExtensionOrderTest.MiddlewareA,
      Aikido.Dsl.ExtensionOrderTest.MiddlewareB,
      Aikido.Dsl.ExtensionOrderTest.MiddlewareC
    ],
    default_slices: false

  agent do
    name "host_order_test"
  end
end

defmodule Aikido.Dsl.ExtensionOrderTest.HostReverseOrder do
  @moduledoc false
  use Aikido.Agent,
    middleware: [
      Aikido.Dsl.ExtensionOrderTest.MiddlewareC,
      Aikido.Dsl.ExtensionOrderTest.MiddlewareB,
      Aikido.Dsl.ExtensionOrderTest.MiddlewareA
    ],
    default_slices: false

  agent do
    name "host_reverse_order"
  end
end

defmodule Aikido.Dsl.ExtensionOrderTest do
  @moduledoc """
  Verifies that the `extensions: […]` registration order is preserved
  when classifying entries into plugins / slices / middleware. The
  middleware-chain order is significant for the `on_signal/4`
  pipeline, so the test asserts the host's middleware list mirrors
  declaration order.
  """
  use ExUnit.Case, async: true

  describe("middleware-chain order preservation") do
    test "middleware list mirrors declaration order" do
      middleware = Aikido.Dsl.Agent.Info.middleware(Aikido.Dsl.ExtensionOrderTest.HostOrderTest)
      mods = Enum.map(middleware, fn {mod, _opts} -> mod end)

      assert mods == [
               Aikido.Dsl.ExtensionOrderTest.MiddlewareA,
               Aikido.Dsl.ExtensionOrderTest.MiddlewareB,
               Aikido.Dsl.ExtensionOrderTest.MiddlewareC
             ]
    end

    test "reversing the declaration order reverses the middleware list" do
      middleware =
        Aikido.Dsl.Agent.Info.middleware(Aikido.Dsl.ExtensionOrderTest.HostReverseOrder)

      mods = Enum.map(middleware, fn {mod, _opts} -> mod end)

      assert mods == [
               Aikido.Dsl.ExtensionOrderTest.MiddlewareC,
               Aikido.Dsl.ExtensionOrderTest.MiddlewareB,
               Aikido.Dsl.ExtensionOrderTest.MiddlewareA
             ]
    end
  end
end
