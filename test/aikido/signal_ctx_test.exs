defmodule AikidoTest.SignalCtxTest.TraceProbe.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    ctx = input.context.aikido

    Aikido.ActionResult.new(
      state: %{trace_id: Map.get(ctx, :trace_id), user: Map.get(ctx, :user)},
      directives: []
    )
  end
end

defmodule AikidoTest.SignalCtxTest.TraceProbe do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :trace_probe, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.SignalCtxTest.TraceProbe.Implementation, action: :run}
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
      sig = Aikido.SignalCtx.put(sig, :trace_id, "t-1")
      assert Aikido.SignalCtx.get(sig, :trace_id) == "t-1"
      assert Aikido.SignalCtx.ctx(sig) == %{trace_id: "t-1"}
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
        |> Aikido.SignalCtx.put(:trace_id, "t-1")
        |> Aikido.SignalCtx.merge(%{trace_id: "t-2", user: "u"})

      assert Aikido.SignalCtx.get(sig, :trace_id) == "t-2"
      assert Aikido.SignalCtx.get(sig, :user) == "u"
    end

    test "delete/2 removes a key" do
      {:ok, sig} = Jido.Signal.new("t.x", %{}, source: "/x")

      sig =
        sig
        |> Aikido.SignalCtx.put(:trace_id, "t-1")
        |> Aikido.SignalCtx.put(:tenant, "acme")
        |> Aikido.SignalCtx.delete(:tenant)

      assert Aikido.SignalCtx.ctx(sig) == %{trace_id: "t-1"}
    end

    test "inherit/2 copies source ctx into target without overwriting target keys" do
      {:ok, src} = Jido.Signal.new("a", %{}, source: "/a")
      src = Aikido.SignalCtx.merge(src, %{trace_id: "src", user: "u"})
      {:ok, dst} = Jido.Signal.new("b", %{}, source: "/b")
      dst = Aikido.SignalCtx.put(dst, :trace_id, "dst")
      merged = Aikido.SignalCtx.inherit(dst, src)
      assert Aikido.SignalCtx.get(merged, :trace_id) == "dst"
      assert Aikido.SignalCtx.get(merged, :user) == "u"
    end
  end

  describe("context delivery into native actions") do
    test "native action receives the signal context" do
      {:ok, sig} = Jido.Signal.new("trace_probe", %{}, source: "/test")

      sig =
        sig |> Aikido.SignalCtx.put(:trace_id, "abc-123") |> Aikido.SignalCtx.put(:user, "alice")

      assert {:ok,
              %Aikido.ActionResult{state: %{trace_id: "abc-123", user: "alice"}, directives: []}} =
               then(sig, fn signal ->
                 AikidoTest.SignalCtxTest.TraceProbe
                 |> Ash.ActionInput.for_action(
                   :trace_probe,
                   Map.put(signal.data || %{}, :state, %{}),
                   context: %{aikido: Map.put(Aikido.SignalCtx.ctx(sig), :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)
    end

    test "without an explicit signal, ctx defaults to %{}" do
      assert {:ok, %Aikido.ActionResult{state: %{trace_id: nil, user: nil}, directives: []}} =
               then(struct!(Jido.Signal, id: nil, type: "test", source: "/test"), fn signal ->
                 AikidoTest.SignalCtxTest.TraceProbe
                 |> Ash.ActionInput.for_action(
                   :trace_probe,
                   Map.put(signal.data || %{}, :state, %{}),
                   context: %{aikido: Map.put(%{}, :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)
    end
  end
end
