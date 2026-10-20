defmodule AikidoTest.MiddlewareTest.PassThrough do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule AikidoTest.MiddlewareTest.Tagging do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, opts, next) do
    next.(signal, Map.put(ctx, :tag, opts[:tag]))
  end
end

defmodule AikidoTest.MiddlewareTest.Outer do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    ctx = Map.update(ctx, :order, [:outer], &(&1 ++ [:outer]))

    case next.(signal, ctx) do
      {:ok, ctx, dirs} -> {:ok, Map.update!(ctx, :order, &(&1 ++ [:outer_after])), dirs}
      {:error, ctx, reason} -> {:error, Map.update!(ctx, :order, &(&1 ++ [:outer_after])), reason}
    end
  end
end

defmodule AikidoTest.MiddlewareTest.Inner do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    ctx = Map.update(ctx, :order, [:inner], &(&1 ++ [:inner]))
    next.(signal, ctx)
  end
end

defmodule AikidoTest.MiddlewareTest.Swallow do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    case next.(signal, ctx) do
      {:error, ctx, _reason} -> {:ok, ctx, []}
      ok -> ok
    end
  end
end

defmodule AikidoTest.MiddlewareTest do
  use ExUnit.Case, async: true

  describe("use Aikido.Middleware") do
    test "middleware modules implement the behaviour" do
      assert function_exported?(AikidoTest.MiddlewareTest.PassThrough, :on_signal, 4)
      assert function_exported?(AikidoTest.MiddlewareTest.Tagging, :on_signal, 4)
    end

    test "behaviour is set" do
      assert Aikido.Middleware in AikidoTest.MiddlewareTest.PassThrough.module_info()[:attributes][
               :behaviour
             ]

      assert Aikido.Middleware in AikidoTest.MiddlewareTest.Tagging.module_info()[:attributes][
               :behaviour
             ]
    end

    test "callback receives signal, ctx, opts, next" do
      next = fn _sig, ctx -> {:ok, ctx, []} end
      sig = %Aikido.Signal{type: "x", source: "/test", id: "1"}

      assert {:ok, %{} = ctx, []} =
               AikidoTest.MiddlewareTest.PassThrough.on_signal(sig, %{}, %{}, next)

      assert ctx == %{}
    end

    test "opts are passed verbatim and let middleware close over per-registration data" do
      next = fn _sig, ctx -> {:ok, ctx, []} end
      sig = %Aikido.Signal{type: "x", source: "/test", id: "1"}
      {:ok, ctx, _} = AikidoTest.MiddlewareTest.Tagging.on_signal(sig, %{}, %{tag: :hot}, next)
      assert ctx.tag == :hot
      {:ok, ctx, _} = AikidoTest.MiddlewareTest.Tagging.on_signal(sig, %{}, %{tag: :cold}, next)
      assert ctx.tag == :cold
    end
  end

  describe("next-passing chain composition") do
    test "middleware composes outside-in" do
      sig = %Aikido.Signal{type: "x", source: "/test", id: "1"}
      base = fn _sig, ctx -> {:ok, ctx, []} end
      chain_inner = fn s, c -> AikidoTest.MiddlewareTest.Inner.on_signal(s, c, %{}, base) end

      chain_outer = fn s, c ->
        AikidoTest.MiddlewareTest.Outer.on_signal(s, c, %{}, chain_inner)
      end

      {:ok, ctx, _} = chain_outer.(sig, %{order: []})
      assert ctx.order == [:outer, :inner, :outer_after]
    end
  end

  describe("tagged-tuple chain semantics") do
    test "middleware that swallows {:error, _, _} returns {:ok, ctx, []}" do
      sig = %Aikido.Signal{type: "x", source: "/test", id: "1"}
      base = fn _sig, ctx -> {:error, ctx, :boom} end
      chain = fn s, c -> AikidoTest.MiddlewareTest.Swallow.on_signal(s, c, %{}, base) end
      assert {:ok, %{}, []} = chain.(sig, %{})
    end
  end
end
