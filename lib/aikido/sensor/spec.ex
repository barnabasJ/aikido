defmodule Aikido.Sensor.Spec do
  @moduledoc """
  The normalized representation of a sensor specification.

  Contains all metadata needed to configure and run a sensor,
  including the module, name, description, configuration, and schema.

  ## Fields

  - `module` - The sensor module (required)
  - `name` - Sensor name (required)
  - `description` - Optional sensor description
  - `config` - Configuration map for the sensor (default: %{})
  - `schema` - Optional Ash field contract for introspection

  ## Examples

      Sensor.Spec.new!(%{module: MySensor, name: "my_sensor"})
      # => %Sensor.Spec{module: MySensor, name: "my_sensor", config: %{}}

      Sensor.Spec.new(%{module: MySensor, name: "my_sensor", config: %{interval: 1000}})
      # => {:ok, %Sensor.Spec{module: MySensor, name: "my_sensor", config: %{interval: 1000}}}
  """

  use Ash.TypedStruct

  typed_struct do
    field :module, :atom, allow_nil?: false, description: "The sensor module"

    field :name, :string,
      allow_nil?: false,
      description: "Sensor name",
      constraints: [trim?: false, allow_empty?: true]

    field :description, :string,
      allow_nil?: true,
      description: "Sensor description",
      constraints: [trim?: false, allow_empty?: true]

    field :config, :map,
      allow_nil?: false,
      default: %{},
      description: "Configuration for the sensor"

    field :schema, :term, allow_nil?: true, description: "Ash field contract for introspection"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for Sensor.Spec."
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema

  @doc """
  Creates a new Sensor.Spec from a map of attributes.

  Returns `{:ok, spec}` or `{:error, reason}`.

  ## Examples

      Sensor.Spec.new(%{module: MySensor, name: "my_sensor"})
      # => {:ok, %Sensor.Spec{module: MySensor, name: "my_sensor", config: %{}}}

      Sensor.Spec.new(%{name: "missing_module"})
      # => {:error, validation_errors}
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    Aikido.Schema.cast(@schema, attrs)
  end

  def new(_), do: {:error, Aikido.Error.validation_error("Sensor.Spec requires a map")}

  @doc """
  Creates a new Sensor.Spec from a map, raising on error.

  ## Examples

      Sensor.Spec.new!(%{module: MySensor, name: "my_sensor"})
      # => %Sensor.Spec{module: MySensor, name: "my_sensor", config: %{}}
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} ->
        spec

      {:error, reason} ->
        raise Aikido.Error.validation_error("Invalid Sensor.Spec", details: reason)
    end
  end
end
