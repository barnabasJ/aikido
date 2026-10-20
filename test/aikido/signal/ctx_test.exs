defmodule AikidoTest.SignalCtxTest.Actions.CaptureContext do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    ctx = input.context.aikido

    Aikido.Types.ActionResult.new(
      state: %{workflow_id: Map.get(ctx, :workflow_id), user: Map.get(ctx, :user)},
      directives: []
    )
  end
end

defmodule AikidoTest.SignalCtxTest.ContextProbe do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :context_probe, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.SignalCtxTest.Actions.CaptureContext
    end
  end
end

defmodule AikidoTest.SignalCtxTest do
  @moduledoc """
  Tests for `Aikido.Signal` helpers and end-to-end ctx delivery into the
  native Ash action implementation.
  """
  use ExUnit.Case, async: true

  describe("put/3 + get/3 + ctx/1") do
    test "writes and reads a single key" do
      {:ok, sig} = Aikido.Signal.new("t.x", %{}, source: "/x")
      sig = Aikido.Signal.put(sig, :workflow_id, "t-1")
      assert Aikido.Signal.get(sig, :workflow_id) == "t-1"
      assert Aikido.Signal.ctx(sig) == %{workflow_id: "t-1"}
    end

    test "default for missing key" do
      {:ok, sig} = Aikido.Signal.new("t.x", %{}, source: "/x")
      assert Aikido.Signal.get(sig, :missing) == nil
      assert Aikido.Signal.get(sig, :missing, :fallback) == :fallback
    end

    test "merge/2 combines into existing ctx (right-biased)" do
      {:ok, sig} = Aikido.Signal.new("t.x", %{}, source: "/x")

      sig =
        sig
        |> Aikido.Signal.put(:workflow_id, "t-1")
        |> Aikido.Signal.merge(%{workflow_id: "t-2", user: "u"})

      assert Aikido.Signal.get(sig, :workflow_id) == "t-2"
      assert Aikido.Signal.get(sig, :user) == "u"
    end

    test "delete/2 removes a key" do
      {:ok, sig} = Aikido.Signal.new("t.x", %{}, source: "/x")

      sig =
        sig
        |> Aikido.Signal.put(:workflow_id, "t-1")
        |> Aikido.Signal.put(:tenant, "acme")
        |> Aikido.Signal.delete(:tenant)

      assert Aikido.Signal.ctx(sig) == %{workflow_id: "t-1"}
    end

    test "inherit/2 copies source ctx into target without overwriting target keys" do
      {:ok, src} = Aikido.Signal.new("a", %{}, source: "/a")
      src = Aikido.Signal.merge(src, %{workflow_id: "src", user: "u"})
      {:ok, dst} = Aikido.Signal.new("b", %{}, source: "/b")
      dst = Aikido.Signal.put(dst, :workflow_id, "dst")
      merged = Aikido.Signal.inherit(dst, src)
      assert Aikido.Signal.get(merged, :workflow_id) == "dst"
      assert Aikido.Signal.get(merged, :user) == "u"
    end
  end

  describe("context delivery into native actions") do
    test "native action receives the signal context" do
      {:ok, sig} = Aikido.Signal.new("context_probe", %{}, source: "/test")

      sig =
        sig
        |> Aikido.Signal.put(:workflow_id, "abc-123")
        |> Aikido.Signal.put(:user, "alice")

      assert {:ok,
              %Aikido.Types.ActionResult{
                state: %{workflow_id: "abc-123", user: "alice"},
                directives: []
              }} =
               then(sig, fn signal ->
                 AikidoTest.SignalCtxTest.ContextProbe
                 |> Ash.ActionInput.for_action(
                   :context_probe,
                   Map.put(signal.data || %{}, :state, %{}),
                   context: %{aikido: Map.put(Aikido.Signal.ctx(sig), :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)
    end

    test "without an explicit signal, ctx defaults to %{}" do
      assert {:ok,
              %Aikido.Types.ActionResult{state: %{workflow_id: nil, user: nil}, directives: []}} =
               then(%Aikido.Signal{id: nil, type: "test", source: "/test"}, fn signal ->
                 AikidoTest.SignalCtxTest.ContextProbe
                 |> Ash.ActionInput.for_action(
                   :context_probe,
                   Map.put(signal.data || %{}, :state, %{}),
                   context: %{aikido: Map.put(%{}, :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)
    end
  end
end
