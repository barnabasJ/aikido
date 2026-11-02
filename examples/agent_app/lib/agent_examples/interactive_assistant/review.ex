defmodule AgentExamples.InteractiveAssistant.Review do
  @moduledoc "Waits for the current actor's browser approval using the application transport."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    owner = context.actor.id

    request = %{
      type: "task.review",
      payload: %{
        "title" => input.arguments.title,
        "details" => input.arguments.details,
        "choices" => input.arguments.choices
      }
    }

    case AgentExamples.Playground.request({owner, "hook-requests"}, request, %{
           hook: "review_task"
         }) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error,
         Ash.Error.Action.InvalidArgument.exception(
           field: :approval,
           message: "Approval request ended: #{inspect(reason)}"
         )}
    end
  end
end
