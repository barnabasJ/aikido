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
    assert Notify.schema() == Notify

    assert {:ok, %Notify{count: 2}} = Notify.new(recipient: self(), count: "2")
    assert {:error, _} = Notify.new(recipient: self(), count: 0)
    assert {:error, _} = Notify.new(count: 2)
  end

  test "validated custom directives execute their module callback without a protocol" do
    directive = Notify.new!(recipient: self(), count: 2)
    assert {:ok, ^directive} = Aikido.Types.Directive.cast_input(directive, [])
    assert {:ok, result} = Aikido.ActionResult.new(state: %{}, directives: [directive])
    assert result.directives == [directive]
    refute_received {:notified, _}

    assert :ok = Aikido.Directive.exec(directive, nil, nil)
    assert_received {:notified, 2}
  end

  test "ordinary typed structs and arbitrary values are rejected" do
    for value <- [OtherStruct.new!(count: 1), %{}, :unknown, nil] do
      assert {:error, _} = Aikido.Types.Directive.cast_input(value, [])
    end
  end
end
