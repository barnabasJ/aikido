defmodule Aikido.Jido.GenerationTest do
  use ExUnit.Case, async: true

  test "generated resource and command BEAMs survive compilation and loading" do
    agent = Aikido.Jido.Examples.Counter
    resource = agent.ash_resource()
    assert Code.ensure_loaded?(resource)
    assert :code.which(resource) |> List.to_string() |> String.ends_with?(".beam")
    assert {:ok, {:ok, signal}} = resource.add_signal(%{amount: 2})
    assert signal.type == "counter.add"
    assert signal.data == %{amount: 2}
    assert agent.instantiate!(id: "pure-example").state == %{count: 0}
  end

  test "unsupported input schemas produce a compile-time diagnostic" do
    assert_raise ArgumentError, ~r/unsupported Zoi schema/, fn ->
      Code.compile_string("""
      defmodule Aikido.JidoTest.Unsupported do
        use Jido.Agent, name: "unsupported"
        use Aikido.Jido
        routes do
          signal_source "/unsupported"
          route "unsupported.input", as: :input do
            action %{value: value}, schema: Zoi.object(%{value: Zoi.tuple({Zoi.string(), Zoi.integer()})}) do
              {:ok, %{value: value}}
            end
          end
        end
      end
      """)
    end
  end

  test "MFA-shaped Zoi defaults stay data rather than executing as Ash defaults" do
    Code.compile_string("""
    defmodule Aikido.JidoTest.DataDefault do
      use Jido.Agent, name: "data_default"
      use Aikido.Jido
      routes do
        signal_source "/data-default"
        route "data.input", as: :input_data do
          action %{value: value}, schema: Zoi.object(%{value: Zoi.any() |> Zoi.default({Kernel, :raise, ["data default executed"]})}) do
            {:ok, %{value: value}}
          end
        end
      end
    end
    """)

    resource = Module.concat([Aikido.JidoTest.DataDefault, Ash])
    assert {:ok, {:ok, %Jido.Signal{data: %{}}}} = apply(resource, :input_data_signal, [%{}])
  end
end
