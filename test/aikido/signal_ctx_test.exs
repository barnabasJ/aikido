defmodule AikidoTest.SignalCtxTest.ContextProbe.Implementation do
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
      run AikidoTest.SignalCtxTest.ContextProbe.Implementation
    end
  end
end

defmodule AikidoTest.SignalCtxTest do
  @moduledoc """
  Tests for `Aikido.SignalCtx` helpers and end-to-end ctx delivery into the
  native Ash action implementation.
  """
  use ExUnit.Case, async: true

  describe("put/3 + get/3 + ctx/1") do
    test "writes and reads a single key" do
      {:ok, sig} = Jido.Signal.new("t.x", %{}, source: "/x")
      sig = Aikido.SignalCtx.put(sig, :workflow_id, "t-1")
      assert Aikido.SignalCtx.get(sig, :workflow_id) == "t-1"
      assert Aikido.SignalCtx.ctx(sig) == %{workflow_id: "t-1"}
    end

    test "default for missing key" do
      {:ok, sig} = Jido.Signal.new("t.x", %{}, source: "/x")
      assert Aikido.SignalCtx.get(sig, :missing) == nil
      assert Aikido.SignalCtx.get(sig, :missing, :fallback) == :fallback
    end

    test "merge/2 combines into existing ctx (right-biased)" do
      {:ok, sig} = Jido.Signal.new("t.x", %{}, source: "/x")

      sig =
        sig
        |> Aikido.SignalCtx.put(:workflow_id, "t-1")
        |> Aikido.SignalCtx.merge(%{workflow_id: "t-2", user: "u"})

      assert Aikido.SignalCtx.get(sig, :workflow_id) == "t-2"
      assert Aikido.SignalCtx.get(sig, :user) == "u"
    end

    test "delete/2 removes a key" do
      {:ok, sig} = Jido.Signal.new("t.x", %{}, source: "/x")

      sig =
        sig
        |> Aikido.SignalCtx.put(:workflow_id, "t-1")
        |> Aikido.SignalCtx.put(:tenant, "acme")
        |> Aikido.SignalCtx.delete(:tenant)

      assert Aikido.SignalCtx.ctx(sig) == %{workflow_id: "t-1"}
    end

    test "inherit/2 copies source ctx into target without overwriting target keys" do
      {:ok, src} = Jido.Signal.new("a", %{}, source: "/a")
      src = Aikido.SignalCtx.merge(src, %{workflow_id: "src", user: "u"})
      {:ok, dst} = Jido.Signal.new("b", %{}, source: "/b")
      dst = Aikido.SignalCtx.put(dst, :workflow_id, "dst")
      merged = Aikido.SignalCtx.inherit(dst, src)
      assert Aikido.SignalCtx.get(merged, :workflow_id) == "dst"
      assert Aikido.SignalCtx.get(merged, :user) == "u"
    end
  end

  describe("context delivery into native actions") do
    test "native action receives the signal context" do
      {:ok, sig} = Jido.Signal.new("context_probe", %{}, source: "/test")

      sig =
        sig
        |> Aikido.SignalCtx.put(:workflow_id, "abc-123")
        |> Aikido.SignalCtx.put(:user, "alice")

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
                   context: %{aikido: Map.put(Aikido.SignalCtx.ctx(sig), :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)
    end

    test "without an explicit signal, ctx defaults to %{}" do
      assert {:ok,
              %Aikido.Types.ActionResult{state: %{workflow_id: nil, user: nil}, directives: []}} =
               then(%Jido.Signal{id: nil, type: "test", source: "/test"}, fn signal ->
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
