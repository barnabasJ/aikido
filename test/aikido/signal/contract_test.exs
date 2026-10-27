defmodule Aikido.SignalContractTest.Definition do
  use Aikido.Signal

  signal do
    type "contract.event"
    source "/contract"

    schema do
      attribute :required, :term do
        description "Required payload used to verify native presence validation."
        allow_nil? false
      end

      attribute :optional, :term do
        description "Optional value used to verify native default handling."
      end

      attribute :enabled, :boolean do
        description "Boolean option used to verify native default application."
        default true
      end

      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 2
        constraints min: 1
      end
    end
  end
end

defmodule Aikido.SignalContractTest.Defaults do
  use Aikido.Signal

  signal do
    type "contract.defaults"

    schema do
      attribute :number, :integer do
        description "Numeric payload used to verify native constraints and defaults."
        default {__MODULE__, :number, []}
        constraints min: 1
      end

      attribute :value, :term do
        description "Domain value used to verify state transitions and native contracts."
        default &__MODULE__.value/0
      end

      attribute :flag, :boolean do
        description "Boolean value produced by the configured native default."
        default {__MODULE__, :flag, []}
      end

      attribute :literal, :boolean do
        description "Literal false default preserved by native casting."
        default false
      end
    end
  end

  def number do
    send(self(), {:default_evaluated, :number})
    7
  end

  def value do
    send(self(), {:default_evaluated, :value})
    {:function, self()}
  end

  def flag do
    send(self(), {:default_evaluated, :flag})
    true
  end
end

defmodule Aikido.SignalContractTest do
  use ExUnit.Case, async: true

  alias Aikido.Signal
  alias Aikido.SignalContractTest.Definition

  test "constructors materialize metadata and preserve arbitrary data and native scope" do
    scope = %{
      actor: %{id: "alice"},
      tenant: "tenant",
      authorize?: false,
      context: %{token: make_ref()}
    }

    for data <- [nil, false, 42, "text", [:one, self()], {:work, make_ref()}, %{pid: self()}] do
      assert {:ok, %Signal{} = signal} =
               Signal.new("contract.event", data, scope: scope, reply_to: self())

      assert signal.data == data
      assert signal.scope == scope
      assert signal.reply_to == self()
      assert is_binary(signal.id)
      assert {:ok, _, _} = DateTime.from_iso8601(signal.time)
      assert {:ok, ^signal} = Signal.new(signal)
    end
  end

  test "literal descriptors and context helpers do not generate metadata" do
    source = %Signal{type: "source", scope: %{actor: :caller, tenant: "org"}, tracer_context: %{}}
    target = %Signal{type: "target"}

    result =
      target
      |> Signal.put_ctx(%{actor: :override})
      |> Signal.put(:tenant, "other")
      |> Signal.merge(%{request: 1})
      |> Signal.delete(:tenant)
      |> Signal.inherit(source)

    assert result.id == nil
    assert result.time == nil
    assert Signal.ctx(result) == %{actor: :override, tenant: "org", request: 1}
    assert Signal.get(result, :unknown, :fallback) == :fallback
    assert Signal.timestamp(result) == 0
  end

  test "native envelope construction stays pure and explicit materialization preserves identity" do
    assert {:ok, first} = Signal.new(%{type: "contract.event", data: false})
    assert {:ok, ^first} = Signal.new(%{type: "contract.event", data: false})
    assert first.id == nil
    assert first.time == nil
    assert {:ok, ^first} = Ash.Type.cast_input(Signal, first, [])
    assert {:ok, ^first} = Ash.Type.cast_input(Signal, %{type: "contract.event", data: false}, [])
    assert {:ok, materialized} = Signal.materialize(first)
    assert is_binary(materialized.id)
    assert {:ok, _, _} = DateTime.from_iso8601(materialized.time)
    assert {:ok, ^materialized} = Signal.materialize(materialized)
  end

  test "signal-valued directives validate envelopes without generating runtime metadata" do
    signal = %Signal{type: "contract.event", data: false, scope: %{tenant: "org"}}

    for {module, field, options} <- [
          {Aikido.Directives.Emit, :signal, %{}}
        ] do
      assert Ash.TypedStruct.Info.field(module, field).type == Signal
      assert {:ok, directive} = module.new(Map.put(options, field, signal))
      assert %Signal{} = validated = Map.fetch!(directive, field)
      assert validated.data == false
      assert validated.scope == %{tenant: "org"}
      assert validated.id == nil
      assert validated.time == nil
      assert {:error, _} = module.new(Map.put(options, field, %{type: nil}))
    end

    assert {:error, _} =
             Aikido.Types.ActionResult.new(
               state: %{},
               directives: [%Aikido.Directives.Emit{signal: %Signal{type: nil}}]
             )
  end

  test "native typed definition casting preserves false and explicit nil and applies absent defaults" do
    assert {:ok, signal} =
             Definition.new(%{required: false, optional: nil, enabled: false, count: "3"})

    assert signal.type == "contract.event"
    assert signal.source == "/contract"
    assert signal.data == %{required: false, optional: nil, enabled: false, count: 3}
    assert {:ok, defaults} = Definition.new(%{required: self()})
    assert defaults.data == %{required: self(), enabled: true, count: 2}
    assert {:ok, custom} = Definition.new(%{required: {:tuple, self()}}, source: "/override")
    assert custom.source == "/override"
    assert Aikido.Signal.Info.signal_type!(Definition) == "contract.event"

    assert Enum.map(Aikido.Signal.Info.schema(Definition), & &1.name) == [
             :required,
             :optional,
             :enabled,
             :count
           ]
  end

  test "native field validation rejects missing fields and invalid payload types" do
    assert {:error, _} = Definition.new(%{})
    assert {:error, _} = Definition.new(%{required: :ok, count: 0})
    assert {:error, _} = Definition.new(:not_a_map)
    assert {:error, _} = Definition.new(nil)
    assert {:error, _} = Signal.new(%{type: nil})
    assert_raise Ash.Error.Unknown, fn -> Definition.new!(%{}) end
  end

  test "native MFA and function defaults resolve once only for absent atom and string keys" do
    defaults = Aikido.SignalContractTest.Defaults
    assert {:ok, signal} = defaults.new(%{})
    assert signal.data == %{number: 7, value: {:function, self()}, flag: true, literal: false}
    for field <- [:number, :value, :flag], do: assert_received({:default_evaluated, ^field})
    refute_received {:default_evaluated, _}

    for values <- [
          %{number: nil, value: nil, flag: false, literal: nil},
          %{"number" => "11", "value" => false, "flag" => nil, "literal" => false}
        ] do
      assert {:ok, explicit} = defaults.new(values)
      assert explicit.data.value == Map.get(values, :value, Map.get(values, "value"))
      assert explicit.data.flag == Map.get(values, :flag, Map.get(values, "flag"))
      assert explicit.data.number == if(Map.has_key?(values, :number), do: nil, else: 11)
      refute_received {:default_evaluated, _}
    end
  end

  test "explicit identity, timestamp and correlation survive constructor validation" do
    signal =
      Signal.new!("contract.event", :payload,
        id: "identity",
        time: "2026-10-20T00:00:00Z",
        subject: "request"
      )

    assert signal.id == "identity"
    assert signal.subject == "request"
    assert Signal.timestamp(signal) == 1_792_454_400_000
  end
end
