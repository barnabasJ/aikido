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
    field :id, :string do
      description "Unique entry identifier"
      allow_nil? false
      constraints trim?: false, allow_empty?: true
    end

    field :seq, :integer do
      description "Monotonic sequence within thread"
      default 0
      allow_nil? false
    end

    field :at, :integer do
      description "Timestamp (ms)"
      allow_nil? false
    end

    field :kind, :atom do
      description "Entry type - open, any atom accepted"
      default :note
      allow_nil? false
    end

    field :payload, :map do
      description "Kind-specific data"
      allow_nil? false
      default %{}
    end

    field :refs, :map do
      description "Cross-references to other primitives"
      allow_nil? false
      default %{}
    end
  end

  @type t :: %__MODULE__{}
end
