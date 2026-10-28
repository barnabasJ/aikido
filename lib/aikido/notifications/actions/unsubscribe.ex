defmodule Aikido.Notifications.Actions.Unsubscribe do
  @moduledoc "Requests removal of this activation's recorded PubSub subscriptions."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    directives =
      input.arguments.state.registrations
      |> Enum.uniq_by(&{&1.module, &1.name, &1.topic})
      |> Enum.map(fn registration ->
        registration
        |> Map.take([:module, :name, :topic])
        |> Aikido.Notifications.Directives.Unsubscribe.new!()
      end)

    Aikido.Types.ActionResult.new(changes: %{registrations: []}, directives: directives)
  end
end
