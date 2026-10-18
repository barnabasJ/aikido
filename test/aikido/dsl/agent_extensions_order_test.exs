defmodule Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareA do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareB do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareC do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule Aikido.Dsl.AgentExtensionsOrderTest.OrderedAgent do
  @moduledoc false
  use Aikido.Agent,
    middleware: [
      Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareA,
      Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareB,
      Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareC
    ]

  agent do
    name "ordered_agent"
  end
end

defmodule Aikido.Dsl.AgentExtensionsOrderTest.InterleavedAgent do
  @moduledoc false
  use Aikido.Agent,
    middleware: [
      Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareA,
      Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareC,
      Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareB
    ]

  agent do
    name "interleaved_agent"
  end
end

defmodule Aikido.Dsl.AgentExtensionsOrderTest do
  use ExUnit.Case, async: true

  test "middleware/0 preserves the `extensions: […]` keyword-list order" do
    assert [
             {Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareA, _},
             {Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareB, _},
             {Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareC, _}
           ] = Aikido.Dsl.Agent.Info.middleware(Aikido.Dsl.AgentExtensionsOrderTest.OrderedAgent)
  end

  test "user-chosen order is preserved verbatim" do
    assert [
             {Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareA, _},
             {Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareC, _},
             {Aikido.Dsl.AgentExtensionsOrderTest.MiddlewareB, _}
           ] =
             Aikido.Dsl.Agent.Info.middleware(
               Aikido.Dsl.AgentExtensionsOrderTest.InterleavedAgent
             )
  end
end
