defmodule Aikido.Slices.Thread.Entry do
  @moduledoc """
  A single entry in a Thread. Typed by `kind` with kind-specific payload.

  Entries are immutable once appended. The `refs` map provides cross-links
  to other Aikido primitives (signals and actions).

  ## Entry Kinds

  Kinds are open - any atom is accepted. Recommended kinds include:
  - `:message` - User/assistant/system message
  - `:tool_call` - Tool execution request
  - `:tool_result` - Tool execution result
  - `:signal_in` / `:signal_out` - Signal events
  - `:note` - Human annotation
  - `:error` - Error occurred
  - `:checkpoint` - State snapshot marker

  ## Refs Conventions

  Common ref keys (not enforced):
  - `signal_id` - Associated signal ID
  - `action` - Native Ash action reference
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

    field :seq, :integer,
      default: 0,
      allow_nil?: false,
      description: "Monotonic sequence within thread"

    field :at, :integer, allow_nil?: false, description: "Timestamp (ms)"

    field :kind, :atom,
      default: :note,
      allow_nil?: false,
      description: "Entry type - open, any atom accepted"

    field :payload, :map, allow_nil?: false, default: %{}, description: "Kind-specific data"

    field :refs, :map,
      allow_nil?: false,
      default: %{},
      description: "Cross-references to other primitives"
  end

  @type t :: %__MODULE__{}
end
