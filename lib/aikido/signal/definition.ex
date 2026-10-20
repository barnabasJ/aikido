defmodule Aikido.Signal.Definition do
  @moduledoc false
  use Spark.Dsl, default_extensions: [extensions: [Aikido.Signal.Dsl]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      use Ash.Type.NewType, subtype_of: :map, lazy_init?: true

      @impl Ash.Type.NewType
      def type_constraints(constraints, _subtype_constraints) do
        Keyword.merge(constraints, Aikido.Signal.Definition.payload_constraints(__MODULE__))
      end

      @impl Ash.Type
      def cast_input(value, constraints) do
        with {:ok, value} <- Aikido.Signal.Definition.payload_defaults(__MODULE__, value),
             {:ok, constraints} <- do_init(constraints) do
          super(value, constraints)
        end
      end

      @impl Ash.Type
      def apply_constraints(value, constraints) do
        with {:ok, constraints} <- do_init(constraints) do
          super(value, constraints)
        end
      end
    end
  end

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    quote do
      @doc "Construct this typed signal and materialize its runtime metadata."
      def new(data, opts \\ []), do: Aikido.Signal.from_definition(__MODULE__, data, opts)

      @doc "Construct this typed signal, raising on invalid data."
      def new!(data, opts \\ []), do: new(data, opts) |> Ash.Helpers.unwrap_or_raise!()
    end
  end

  @doc false
  def payload_constraints(module) do
    fields =
      Enum.map(Aikido.Signal.Info.schema(module), fn attribute ->
        {attribute.name,
         [
           type: attribute.type,
           allow_nil?: attribute.allow_nil?,
           constraints: attribute.constraints
         ]}
      end)

    [fields: fields, preserve_nil_values?: true]
  end

  @doc false
  def payload_defaults(module, value) do
    case Ash.Type.cast_input(:map, value, []) do
      {:ok, value} when is_map(value) ->
        {:ok,
         Enum.reduce(Aikido.Signal.Info.schema(module), value, fn attribute, values ->
           if !is_nil(attribute.default) && !Map.has_key?(values, attribute.name) &&
                !Map.has_key?(values, Atom.to_string(attribute.name)) do
             Map.put(values, attribute.name, Ash.Helpers.resolve_default(attribute.default))
           else
             values
           end
         end)}

      _ ->
        {:error, "Signal definition data must be a map"}
    end
  end
end
