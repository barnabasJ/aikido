defmodule Aikido.Dsl.NativeRoutesTest.Reducer do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context), do: Aikido.Types.ActionResult.new(changes: nil)
end

defmodule Aikido.Dsl.NativeRoutesTest.Slice do
  use Aikido.Slice

  slice do
    name "gated_slice"
    route "gated.run", :reduce, match: &__MODULE__.allowed?/1, priority: -12
  end

  actions do
    action :reduce, Aikido.Types.ActionResult do
      public? false
      argument :state, :map
      run Aikido.Dsl.NativeRoutesTest.Reducer
    end
  end

  def allowed?(signal), do: Map.get(signal.data, :allowed, false)
end

defmodule Aikido.Dsl.NativeRoutesTest.Agent do
  use Aikido.Agent

  agent do
    name "gated_agent"
    slice :gate, Aikido.Dsl.NativeRoutesTest.Slice
  end
end

defmodule Aikido.Dsl.NativeRoutesTest do
  use ExUnit.Case, async: true

  test "slice predicates and priorities survive native route expansion" do
    route =
      Enum.find(
        Aikido.Agent.Info.routes(Aikido.Dsl.NativeRoutesTest.Agent),
        &(elem(&1, 0) == "gated.run")
      )

    assert {"gated.run", predicate, {Aikido.Dsl.NativeRoutesTest.Slice, :reduce}, -12} = route
    assert is_function(predicate, 1)
    router = Aikido.Signal.Router.new!([route])

    assert {:ok, [{Aikido.Dsl.NativeRoutesTest.Slice, :reduce}]} =
             Aikido.Signal.Router.route(router, Aikido.Signal.new!("gated.run", %{allowed: true}))

    assert {:error, _} =
             Aikido.Signal.Router.route(
               router,
               Aikido.Signal.new!("gated.run", %{allowed: false})
             )
  end
end
