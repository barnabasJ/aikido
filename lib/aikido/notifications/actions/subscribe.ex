defmodule Aikido.Notifications.Actions.Subscribe do
  @moduledoc "Resolves subscription bindings and requests same-process topic registration."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, registrations} <-
           Aikido.Notifications.Registrations.resolve(input.context.aikido.agent) do
      subscribe(input.arguments.state.registrations, registrations)
    end
  end

  defp subscribe(registrations, registrations), do: Aikido.Types.ActionResult.new(changes: nil)

  defp subscribe([], registrations) do
    directives =
      registrations
      |> Enum.uniq_by(&{&1.module, &1.name, &1.topic})
      |> Enum.map(fn registration ->
        registration
        |> Map.take([:module, :name, :topic])
        |> Aikido.Notifications.Directives.Subscribe.new!()
      end)

    Aikido.Types.ActionResult.new(
      changes: %{registrations: registrations},
      directives: directives
    )
  end

  defp subscribe(_existing, _registrations) do
    {:error,
     Ash.Error.Action.InvalidArgument.exception(
       field: :bindings,
       message: "Notification bindings changed; restart the agent to rebuild subscriptions"
     )}
  end
end
