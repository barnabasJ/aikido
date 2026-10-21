defmodule AikidoTest.Identity.Actions.EvolveTest do
  use ExUnit.Case, async: true
  alias Aikido.Identity.Slice, as: State

  describe("native evolve action") do
    test "evolves initialized identity by zero without changing its age" do
      identity = AikidoTest.SliceState.new(State, %{profile: %{age: 0}})

      assert {:ok, %Aikido.Types.ActionResult{state: %State{} = evolved, directives: []}} =
               evolve_identity(identity, %{days: 0, years: 0})

      assert evolved.profile[:age] == 0
    end

    test "evolves identity by years" do
      identity = Ash.create!(State, %{})

      assert {:ok, %Aikido.Types.ActionResult{state: %State{} = evolved, directives: []}} =
               evolve_identity(identity, %{days: 0, years: 5})

      assert evolved.profile[:age] == 5
    end

    test "evolves identity by days" do
      identity = Ash.create!(State, %{})

      assert {:ok, %Aikido.Types.ActionResult{state: %State{} = evolved, directives: []}} =
               evolve_identity(identity, %{days: 730, years: 0})

      assert evolved.profile[:age] == 2
    end

    test "evolves identity by combined years and days" do
      identity = Ash.create!(State, %{})

      assert {:ok, %Aikido.Types.ActionResult{state: %State{} = evolved, directives: []}} =
               evolve_identity(identity, %{days: 365, years: 3})

      assert evolved.profile[:age] == 4
    end

    test "bumps rev on evolve" do
      identity = Ash.create!(State, %{})
      assert identity.rev == 0

      assert {:ok, %Aikido.Types.ActionResult{state: %State{} = evolved, directives: []}} =
               evolve_identity(identity, %{days: 0, years: 1})

      assert evolved.rev == 1
    end
  end

  defp evolve_identity(identity, duration) do
    signal = Aikido.Signal.new!("aikido.identity.evolve", duration, source: "/test")

    Aikido.Identity.Slice
    |> Ash.ActionInput.for_action(:evolve, Map.put(duration, :state, identity),
      context: %{aikido: %{signal: signal}}
    )
    |> Ash.run_action()
  end
end
