defmodule Aikido.Signal.RouterTest do
  use ExUnit.Case, async: true

  alias Aikido.Signal.Router

  test "trie and compiled matcher agree with an independent bounded exhaustive glob oracle" do
    patterns =
      for depth <- 1..4,
          segments <- sequences(["a", "b", "*", "**"], depth),
          not Enum.member?(Enum.chunk_every(segments, 2, 1, :discard), ["**", "**"]),
          do: segments

    types = for depth <- 1..5, segments <- sequences(["a", "b"], depth), do: segments

    for pattern <- patterns do
      path = Enum.join(pattern, ".")
      router = Router.new!([{path, :hit}])
      compiled = Router.compile_pattern(path)

      for segments <- types do
        type = Enum.join(segments, ".")
        expected = oracle(segments, pattern)
        assert Router.matches_compiled?(type, compiled) == expected, inspect({type, path})

        result = Router.route(router, %{type: type})
        assert match?({:ok, [:hit]}, result) == expected, inspect({type, path, result})
      end
    end
  end

  test "specificity, complexity, priority and registration order apply to every matching declaration" do
    router =
      Router.new!([
        {"**", :glob, 100},
        {"a.*", :single, 100},
        {"a.b", :first},
        {"a.b", :second},
        {"a.b", :third},
        {"a.b", fn _ -> true end, [:predicate, :predicate], 100},
        {"*.b", :later_specificity, 100},
        {"**.a.b", :zero_glob, 100}
      ])

    assert {:ok,
            [
              :predicate,
              :predicate,
              :first,
              :second,
              :third,
              :single,
              :later_specificity,
              :zero_glob,
              :glob
            ]} =
             Router.route(router, %{type: "a.b"})

    assert {:error, %{details: %{reason: :no_handlers_found}}} =
             Router.route(Router.new!([{"a", :prefix}]), %{type: "a.b"})

    assert {:ok, [:once]} = Router.route(Router.new!([{"**.a.**", :once}]), %{type: "a.a.a"})
  end

  test "construction never executes predicates and routing safely excludes unsuccessful predicates" do
    parent = self()

    observed = fn signal ->
      send(parent, {:predicate, signal})
      true
    end

    router = Router.new!([{"a.b", observed, :observed}])
    refute_received {:predicate, _}
    signal = %{type: "a.b", data: [:arbitrary, 123], scope: %{actor: self()}}
    assert {:ok, [:observed]} = Router.route(router, signal)
    assert_received {:predicate, ^signal}

    for predicate <- [
          fn _ -> false end,
          fn _ -> :truthy end,
          fn _ -> raise "no" end,
          fn _ -> throw(:no) end,
          fn _ -> exit(:no) end
        ] do
      router = Router.new!([{"a.b", predicate, :excluded}, {"a.b", :retained}])
      assert {:ok, [:retained]} = Router.route(router, signal)
    end
  end

  test "generic and owned envelopes preserve payload freedom and produce the same targets" do
    router = Router.new!([{"a.b", :hit}])

    assert Router.route(router, %{type: "a.b", data: 42}) ==
             Router.route(router, %Aikido.Signal{
               type: "a.b",
               source: "/test",
               id: "fixture",
               data: 42
             })

    for signal <- [%{type: nil}, %{type: 42}, %{}] do
      assert {:error, %Aikido.Error.RoutingError{}} = Router.route(router, signal)
    end

    refute Router.matches_compiled?(nil, Router.compile_pattern("a.**"))
  end

  test "native structure validation and path grammar reject invalid declarations with structured errors" do
    for path <- [nil, 42, "", ".a", "a.", "a..b", "a.**.**", "a.b*", "a\nb", "a\n"] do
      assert {:error, %Aikido.Error.RoutingError{}} = Router.validate_pattern(path)
      assert {:error, _} = Router.new([{path, :target}])
    end

    for invalid <- [
          [{"a", :target, 101}],
          [{"a", :target, -101}],
          [{"a", :target, :high}],
          [{"a", :not_a_predicate, :target, 0}],
          [:invalid],
          :invalid
        ] do
      assert {:error, %Aikido.Error.ValidationError{}} = Router.new(invalid)
    end

    assert_raise Aikido.Error.ValidationError, fn -> Router.new!([{"a", :target, 101}]) end
    assert {:ok, _} = Router.new([{"a_b.c-d.123", nil, -100}])
  end

  defp sequences(_, 0), do: [[]]

  defp sequences(alphabet, depth),
    do: for(part <- alphabet, rest <- sequences(alphabet, depth - 1), do: [part | rest])

  defp oracle([], []), do: true
  defp oracle(type, ["**" | rest]), do: oracle(type, rest) or consume_glob(type, ["**" | rest])

  defp oracle([part | tail], [pattern | rest]),
    do: (pattern == "*" or pattern == part) and oracle(tail, rest)

  defp oracle(_, _), do: false
  defp consume_glob([], _), do: false
  defp consume_glob([_ | tail], pattern), do: oracle(tail, pattern)
end
