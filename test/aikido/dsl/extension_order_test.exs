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
  use Aikido.Agent

  agent do
    name "host_order_test"

    middleware [
      Aikido.Dsl.ExtensionOrderTest.MiddlewareA,
      Aikido.Dsl.ExtensionOrderTest.MiddlewareB,
      Aikido.Dsl.ExtensionOrderTest.MiddlewareC
    ]
  end
end

defmodule Aikido.Dsl.ExtensionOrderTest.HostReverseOrder do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "host_reverse_order"

    middleware [
      Aikido.Dsl.ExtensionOrderTest.MiddlewareC,
      Aikido.Dsl.ExtensionOrderTest.MiddlewareB,
      Aikido.Dsl.ExtensionOrderTest.MiddlewareA
    ]
  end
end

defmodule Aikido.Dsl.ExtensionOrderTest do
  @moduledoc "Native agent middleware follows its declaration order."
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
