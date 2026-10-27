defmodule Aikido.Jido.SchemaTest do
  use ExUnit.Case, async: true
  alias Aikido.Jido.Schema

  test "native contracts retain defaults, optionality, nullable items and nested fields" do
    schema =
      Zoi.object(%{
        enabled: Zoi.boolean(),
        tags: Zoi.list(Zoi.string() |> Zoi.nullable()) |> Zoi.min(1),
        settings: Zoi.object(%{retries: Zoi.integer() |> Zoi.min(0) |> Zoi.default(2)}),
        note: Zoi.string() |> Zoi.optional(),
        status: Zoi.enum([:ready, :busy]),
        mode: Zoi.enum(["fast", "thorough"]),
        label: Zoi.string() |> Zoi.default("default")
      })

    args = Map.new(Schema.arguments!(schema, %{label: "route"}), &{&1.name, &1})
    assert args.enabled.type == :boolean
    refute args.enabled.allow_nil?
    assert args.tags.type == {:array, :string}
    assert args.tags.constraints[:nil_items?]
    assert args.tags.constraints[:min_length] == 1
    assert args.settings.constraints[:fields][:retries][:type] == :integer
    assert args.settings.constraints[:fields][:retries][:allow_nil?]
    assert args.note.allow_nil?
    assert args.status.constraints == [one_of: [:ready, :busy]]
    assert Regex.match?(args.mode.constraints[:match], "fast")
    refute Regex.match?(args.mode.constraints[:match], "fastest")
    assert args.label.default == {:value, "route"}
  end

  test "unsupported schemas and reserved input names fail explicitly" do
    assert_raise ArgumentError, ~r/unsupported Zoi schema/, fn ->
      Schema.arguments!(Zoi.object(%{value: Zoi.tuple({Zoi.string(), Zoi.integer()})}), %{})
    end

    assert_raise ArgumentError, ~r/requires a Zoi object/, fn ->
      Schema.arguments!(Zoi.string(), %{})
    end

    assert_raise ArgumentError, ~r/unsupported Jido input key :server/, fn ->
      Schema.arguments!(Zoi.object(%{server: Zoi.string()}), %{})
    end
  end
end
