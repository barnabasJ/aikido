defmodule Aikido.AgentServer.State.Lifecycle do
  @moduledoc """
  Logical pool identity for keyed agents hosted by DurableServer.

  This metadata contains no process-lifetime policy or persistence hooks.
  """

  use Ash.TypedStruct

  typed_struct do
    field :pool, :atom, allow_nil?: true, description: "Pool name if started via Durable"

    field :pool_key, :term,
      allow_nil?: true,
      description: "Pool key if started via Durable"
  end

  @schema __MODULE__
  defoverridable new!: 1

  defoverridable cast_input: 2
  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints) do
    values = Map.merge(Map.from_struct(struct(__MODULE__)), Map.new(value))
    Ash.Type.apply_constraints(:struct, values, __MODULE__.subtype_constraints())
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec schema() :: Ash.Type.t()
  def schema, do: @schema

  @doc """
  Creates a new Lifecycle state from options.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    attrs = %{
      pool: Keyword.get(opts, :pool),
      pool_key: Keyword.get(opts, :pool_key)
    }

    super(attrs)
  end
end
