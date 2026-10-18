defmodule Aikido.Slices.Thread.Entry do
  @moduledoc """
  A single entry in a Thread. Typed by `kind` with kind-specific payload.

  Entries are immutable once appended. The `refs` map provides cross-links
  to other Aikido primitives (signals, instructions, actions).

  ## Entry Kinds

  Kinds are open - any atom is accepted. Recommended kinds include:
  - `:message` - User/assistant/system message
  - `:tool_call` - Tool execution request
  - `:tool_result` - Tool execution result
  - `:signal_in` / `:signal_out` - Signal events
  - `:instruction_start` / `:instruction_end` - Instruction execution
  - `:note` - Human annotation
  - `:error` - Error occurred
  - `:checkpoint` - State snapshot marker

  ## Refs Conventions

  Common ref keys (not enforced):
  - `signal_id` - Associated signal ID
  - `instruction_id` - Associated instruction ID
  - `action` - Action module name
  - `agent_id` - Agent ID
  - `parent_thread_id` / `child_thread_id` - Thread relationships
  """

  @derive Jason.Encoder
  use Ash.TypedStruct

  typed_struct do
    field :id, :string,
      allow_nil?: false,
      description: "Unique entry identifier",
      constraints: [trim?: false, allow_empty?: true]

    field :seq, :integer, allow_nil?: false, description: "Monotonic sequence within thread"
    field :at, :integer, allow_nil?: false, description: "Timestamp (ms)"
    field :kind, :atom, allow_nil?: false, description: "Entry type - open, any atom accepted"
    field :payload, :map, allow_nil?: false, default: %{}, description: "Kind-specific data"

    field :refs, :map,
      allow_nil?: false,
      default: %{},
      description: "Cross-references to other primitives"
  end

  defoverridable new!: 1

  def new!(value) do
    value
    |> then(&Ash.Type.cast_input(__MODULE__, &1))
    |> Ash.Helpers.unwrap_or_raise!()
  end

  defoverridable cast_input: 2
  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) do
    values = Map.merge(Map.from_struct(struct(__MODULE__)), Map.new(value))
    Ash.Type.apply_constraints(:struct, values, __MODULE__.subtype_constraints())
  end

  @type t :: %__MODULE__{}

  @doc "Create a new entry from attributes"
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    now = System.system_time(:millisecond)

    %__MODULE__{
      id: fetch_attr(attrs, :id),
      seq: fetch_attr(attrs, :seq, 0),
      at: fetch_attr(attrs, :at, now),
      kind: fetch_attr(attrs, :kind, :note),
      payload: fetch_attr(attrs, :payload, %{}),
      refs: fetch_attr(attrs, :refs, %{})
    }
  end

  defp fetch_attr(attrs, key, default \\ nil) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      nil -> default
      value -> value
    end
  end
end
