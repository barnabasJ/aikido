defmodule Aikido.Directives.AsyncTask do
  @moduledoc """
  Run blocking work under the agent's task supervisor and report back by signal.

  `Spawn` is the low-level fire-and-forget primitive. Use `AsyncTask` when
  the work has a result that should re-enter the agent's normal signal routes.
  The executor starts a supervised task, normalizes the task's return value, and
  casts one or more signals back to the originating agent.

  The work may return a fully-built `%Jido.Signal{}` when it needs complete
  control over the reply envelope. Otherwise, ordinary `{:ok, value}` and
  `{:error, reason}` results are wrapped using `success_type` and `error_type`.

  ## Result normalization

      %Jido.Signal{} -> signal is cast back as-is
      {:ok, %Jido.Signal{}} -> signal is cast back as-is
      {:signals, signals} -> all signals are cast back
      {:ok, {:signals, signals}} -> all signals are cast back
      {:ok, result} -> success signal with payload + %{result: result}
      {:error, reason} -> error signal with payload + %{reason: reason}
      other -> success signal with payload + %{result: other}
  """

  @default_success_type "aikido.async_task.completed"
  @default_error_type "aikido.async_task.failed"

  @type work :: {module :: module(), function :: atom(), args :: [term()]} | function()
  @type target :: GenServer.server() | nil

  use Ash.TypedStruct

  typed_struct do
    field :work, :term,
      allow_nil?: false,
      description: "MFA or function to execute in a supervised task"

    field :success_type, :string,
      allow_nil?: false,
      default: @default_success_type,
      description: "Signal type emitted for successful non-signal results",
      constraints: [trim?: false, allow_empty?: true]

    field :error_type, :string,
      allow_nil?: false,
      default: @default_error_type,
      description: "Signal type emitted for errors, exits, throws, and crashes",
      constraints: [trim?: false, allow_empty?: true]

    field :payload, :map,
      allow_nil?: false,
      default: %{},
      description: "Static payload merged into reply data"

    field :source, :string,
      allow_nil?: true,
      description: "Signal source for generated reply signals",
      constraints: [trim?: false, allow_empty?: true]

    field :target, :term,
      allow_nil?: true,
      description: "GenServer target for reply signals; defaults to originating agent"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for AsyncTask."
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema
end
