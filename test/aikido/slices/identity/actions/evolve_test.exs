defmodule AikidoTest.Identity.Actions.EvolveTest do
  use ExUnit.Case, async: true
  alias Jido.Signal
  alias Aikido.Slices.Identity, as: State

  defp sig(data) do
    Signal.new!(%{type: "identity_evolve", source: "/test", data: data})
  end

  describe("native evolve action") do
    test "initializes identity when slice is nil" do
      assert {:ok, %Aikido.ActionResult{state: %State{} = evolved, directives: []}} =
               then(sig(%{days: 0, years: 0}), fn signal ->
                 Aikido.Slices.Identity
                 |> Ash.ActionInput.for_action(:evolve, Map.put(signal.data || %{}, :state, nil),
                   context: %{aikido: Map.put(%{}, :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)

      assert evolved.profile[:age] == 0
    end

    test "evolves identity by years" do
      identity = State.new()

      assert {:ok, %Aikido.ActionResult{state: %State{} = evolved, directives: []}} =
               then(sig(%{days: 0, years: 5}), fn signal ->
                 Aikido.Slices.Identity
                 |> Ash.ActionInput.for_action(
                   :evolve,
                   Map.put(signal.data || %{}, :state, identity),
                   context: %{aikido: Map.put(%{}, :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)

      assert evolved.profile[:age] == 5
    end

    test "evolves identity by days" do
      identity = State.new()

      assert {:ok, %Aikido.ActionResult{state: %State{} = evolved, directives: []}} =
               then(sig(%{days: 730, years: 0}), fn signal ->
                 Aikido.Slices.Identity
                 |> Ash.ActionInput.for_action(
                   :evolve,
                   Map.put(signal.data || %{}, :state, identity),
                   context: %{aikido: Map.put(%{}, :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)

      assert evolved.profile[:age] == 2
    end

    test "evolves identity by combined years and days" do
      identity = State.new()

      assert {:ok, %Aikido.ActionResult{state: %State{} = evolved, directives: []}} =
               then(sig(%{days: 365, years: 3}), fn signal ->
                 Aikido.Slices.Identity
                 |> Ash.ActionInput.for_action(
                   :evolve,
                   Map.put(signal.data || %{}, :state, identity),
                   context: %{aikido: Map.put(%{}, :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)

      assert evolved.profile[:age] == 4
    end

    test "bumps rev on evolve" do
      identity = State.new()
      assert identity.rev == 0

      assert {:ok, %Aikido.ActionResult{state: %State{} = evolved, directives: []}} =
               then(sig(%{days: 0, years: 1}), fn signal ->
                 Aikido.Slices.Identity
                 |> Ash.ActionInput.for_action(
                   :evolve,
                   Map.put(signal.data || %{}, :state, identity),
                   context: %{aikido: Map.put(%{}, :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)

      assert evolved.rev == 1
    end
  end
end
