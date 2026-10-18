defmodule Aikido.Dsl.MiddlewareTest.MinimalMiddleware do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule Aikido.Dsl.MiddlewareTest.ConfigurableMiddleware do
  @moduledoc false
  use Aikido.Middleware

  middleware do
    description "Retries on transient failures."

    schema max_retries: [type: :pos_integer, default: 3],
           backoff_ms: [type: :pos_integer, default: 100]
  end

  @impl true
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end

defmodule Aikido.Dsl.MiddlewareTest.MiddlewareAgent do
  @moduledoc false
  use Aikido.Agent,
    middleware: [Aikido.Dsl.MiddlewareTest.MinimalMiddleware],
    default_slices: false

  agent do
    name "middleware_agent"
  end
end

defmodule Aikido.Dsl.MiddlewareTest do
  use ExUnit.Case, async: true

  describe("middleware behaviour") do
    test "minimal middleware implements Aikido.Middleware behaviour" do
      behaviours =
        Aikido.Dsl.MiddlewareTest.MinimalMiddleware.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Aikido.Middleware in behaviours
    end

    test "user-defined on_signal/4 is exported" do
      assert function_exported?(Aikido.Dsl.MiddlewareTest.MinimalMiddleware, :on_signal, 4)
    end

    test "bare middleware is not classified as a slice host" do
      refute Spark.Dsl.is?(Aikido.Dsl.MiddlewareTest.MinimalMiddleware, Aikido.Slice)
    end
  end

  describe("middleware DSL section") do
    test "configurable middleware compiles" do
      assert function_exported?(Aikido.Dsl.MiddlewareTest.ConfigurableMiddleware, :on_signal, 4)
    end

    test "Aikido.Dsl.Middleware exposes a `:middleware` section" do
      section_names = Enum.map(Aikido.Dsl.Middleware.sections(), & &1.name)
      assert :middleware in section_names
    end
  end

  describe("agent integration with middleware") do
    nil

    test "middleware appears in middleware/1, not slices/1" do
      assert Enum.any?(
               Aikido.Dsl.Agent.Info.middleware(Aikido.Dsl.MiddlewareTest.MiddlewareAgent),
               &match?({Aikido.Dsl.MiddlewareTest.MinimalMiddleware, _}, &1)
             )

      refute Aikido.Dsl.MiddlewareTest.MinimalMiddleware in Aikido.Dsl.Agent.Info.slices(
               Aikido.Dsl.MiddlewareTest.MiddlewareAgent
             )
    end
  end
end
