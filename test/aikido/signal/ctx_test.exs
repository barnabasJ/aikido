defmodule AikidoTest.SignalCtxTest.Actions.CaptureContext do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    ctx = input.context.aikido

    Aikido.Types.ActionResult.new(
      changes: %{workflow_id: Map.get(ctx, :workflow_id), user: Map.get(ctx, :user)},
      directives: []
    )
  end
end

defmodule AikidoTest.SignalCtxTest.ContextProbe do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "context_probe"

    schema do
      attribute :workflow_id, :string do
        description "Workflow identifier received through the signal's context."
      end

      attribute :user, :string do
        description "User label received through the signal's context."
      end
    end

    route "context_probe", AikidoTest.SignalCtxTest.Actions.CaptureContext
  end
end

defmodule AikidoTest.SignalCtxTest do
  @moduledoc """
  Tests for `Aikido.Signal` helpers and end-to-end ctx delivery into the
  native Ash action implementation.
  """
  use AikidoTest.Case, async: true

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
    test "native action receives the signal context", context do
      pid = start_server(context, AikidoTest.SignalCtxTest.ContextProbe)
      {:ok, sig} = Aikido.Signal.new("context_probe", %{}, source: "/test")

      sig =
        sig
        |> Aikido.Signal.put(:workflow_id, "abc-123")
        |> Aikido.Signal.put(:user, "alice")

      assert {:ok, %{workflow_id: "abc-123", user: "alice"}} =
               Aikido.AgentServer.call(pid, sig, &{:ok, &1.agent.state.state})
    end

    test "an unscoped signal does not invent caller context", context do
      pid = start_server(context, AikidoTest.SignalCtxTest.ContextProbe)
      signal = Aikido.Signal.new!("context_probe", %{})

      assert {:ok, %{workflow_id: nil, user: nil}} =
               Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state.state})
    end
  end
end
