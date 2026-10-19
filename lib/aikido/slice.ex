defmodule Aikido.Slice do
  @moduledoc """
  A Slice is a declarative bundle of agent-state schema, actions, signal
  routes and schedules.

  The mounting agent assigns its key in `agent.state`. Native Ash actions
  receive the slice in `input.arguments.state` and return `Aikido.ActionResult`.
  `use Aikido.Slice` creates an embedded Ash resource host; schema declarations
  become attributes on that resource.

  Cross-cutting behaviour (auditing, persistence, retries, transformation)
  belongs in `Aikido.Middleware`, not here. The Slice / Middleware split is the
  hard line between "what an agent does" (slices + actions) and "what
  happens around each signal" (middleware).

  ## Example

      defmodule MyApp.ChatSlice do
        use Aikido.Slice

        slice do
          name "chat"
          schema do
            attribute :messages, {:array, :term}, default: []
          end
        end

        signal_routes do
          route "chat.send", {__MODULE__, :send_message}
        end

        actions do
          action :send_message, Aikido.ActionResult do
            argument :state, :term
            argument :message, :string, allow_nil?: false
            run MyApp.Chat.SendMessage
          end
        end
      end

  ## Sections

  - `slice do … end` — slice identity (`name`, `description`,
    `category`, `vsn`, `otp_app`, `schema`, `config_schema`, `tags`).
  - `signal_routes do … end` — `route "type", Action, opts` entries.
  - `schedules do … end` — `schedule "cron", Action, %{data}` entries.
  - `capabilities do … end` — `capability :name` entries.
  - `requires do … end` — `requires :kind, :name` entries.

  Declare reducers in the native `actions do … end` section. Implement them
  with `Ash.Resource.Actions.Implementation` and return directives for I/O.
  """

  defmacro __using__(_opts) do
    quote do
      use Ash.Resource,
        data_layer: :embedded,
        validate_domain_inclusion?: false,
        extensions: [Aikido.Dsl.Slice]
    end
  end

  @doc false
  @spec validate_slice_name(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_slice_name(name, _opts \\ []) do
    case Aikido.Util.validate_name(name, []) do
      {:error, %{message: message}} when is_binary(message) ->
        {:error, message}

      _ ->
        {:ok, name}
    end
  end

  @doc false
  @spec validate_slice_actions([module()], keyword()) ::
          {:ok, [module()]} | {:error, String.t()}
  def validate_slice_actions(actions, _opts \\ []) do
    case Aikido.Util.validate_actions(actions, []) do
      {:error, %{message: message}} when is_binary(message) ->
        {:error, message}

      _ ->
        {:ok, actions}
    end
  end
end
