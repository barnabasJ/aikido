defmodule Aikido.DirectiveTest.Notify do
  use Aikido.Directive

  typed_struct do
    field :recipient, :term, allow_nil?: false
    field :count, :integer, allow_nil?: false, constraints: [min: 1]
  end

  @impl true
  def exec(directive, _signal, _runtime) do
    send(directive.recipient, {:notified, directive.count})
    :ok
  end
end

defmodule Aikido.DirectiveTest.OtherStruct do
  use Ash.TypedStruct

  typed_struct do
    field :count, :integer
  end
end

defmodule Aikido.DirectiveTest do
  use ExUnit.Case, async: true

  alias Aikido.DirectiveTest.{Notify, OtherStruct}

  test "the Spark host reuses Ash typed fields and declares the execution behaviour" do
    assert Spark.Dsl.is?(Notify, Aikido.Directive)
    assert Ash.TypedStruct.Dsl in Spark.extensions(Notify)
    assert Spark.implements_behaviour?(Notify, Aikido.Directive)

    assert {:ok, %Notify{count: 2}} = Notify.new(recipient: self(), count: "2")
    assert {:error, _} = Notify.new(recipient: self(), count: 0)
    assert {:error, _} = Notify.new(count: 2)
  end

  test "the directive host generates the public struct type" do
    assert {:ok, types} = Code.Typespec.fetch_types(Aikido.Slices.AiReact.Directives.ToolExec)

    assert Enum.any?(types, fn
             {:type, {:t, {:type, _, :map, fields}, []}} ->
               Enum.any?(fields, fn
                 {:type, _, :map_field_exact,
                  [{:atom, _, :__struct__}, {:atom, _, Aikido.Slices.AiReact.Directives.ToolExec}]} ->
                   true

                 _ ->
                   false
               end)

             _ ->
               false
           end)
  end

  test "validated custom directives execute their module callback without a protocol" do
    directive = Notify.new!(recipient: self(), count: 2)
    assert {:ok, ^directive} = Aikido.Types.Directive.cast_input(directive, [])
    assert {:ok, result} = Aikido.ActionResult.new(state: %{}, directives: [directive])
    assert result.directives == [directive]
    refute_received {:notified, _}

    signal = Jido.Signal.new!("notify", %{})

    runtime =
      Aikido.AgentServer.State.new!(
        id: "notify-test",
        aikido: Aikido.Default,
        agent_module: AikidoTest.TestAgents.Minimal,
        agent: AikidoTest.TestAgents.Minimal.initialize!()
      )

    assert :ok = Aikido.Directive.exec(directive, signal, runtime)
    assert_received {:notified, 2}
  end

  test "raw directive fields are validated before effects can execute" do
    invalid = %Notify{recipient: self(), count: 0}
    assert {:error, _} = Aikido.ActionResult.new(state: %{}, directives: [invalid])
    refute_received {:notified, _}

    assert {:error, _} =
             Aikido.ActionResult.new(
               state: %{},
               directives: [%Aikido.Directives.Schedule{delay_ms: -1, message: :tick}]
             )
  end

  test "ordinary typed structs and arbitrary values are rejected" do
    for value <- [OtherStruct.new!(count: 1), %{}, :unknown, nil] do
      assert {:error, _} = Aikido.Types.Directive.cast_input(value, [])
    end
  end
end
