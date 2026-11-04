defmodule Aikido.Agent.Actions.AdoptInherited do
  @moduledoc "Adopt declared own-state configuration under the receiving agent's native authority."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    context = input.context.aikido
    delivery = context.__delivery__
    changes = input.arguments.changes
    sender_config = Aikido.Agent.Info.team_config(delivery.sender.resource)

    with :ok <- validate_sender_fields(sender_config, Map.keys(changes)),
         :ok <- Aikido.Team.InheritedAttributes.validate(context.agent_module, Map.keys(changes)) do
      Aikido.Types.ActionResult.new(
        changes: changes,
        directives: acknowledgement(input.arguments, context)
      )
    end
  end

  defp validate_sender_fields(config, fields) do
    if config && Enum.all?(fields, &(&1 in config.reconcile_inherit)) do
      :ok
    else
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :changes,
         message: "The coordinating team did not declare these attributes in reconcile_inherit."
       )}
    end
  end

  defp acknowledgement(arguments, context) do
    config = Aikido.Agent.Info.team_config(context.agent_module)

    if config && config.reconcile_inherit != [] do
      []
    else
      [
        Aikido.Team.Delivery.inheritance_result(
          context.__delivery__.sender.pid,
          arguments.operation_id,
          arguments.member
        )
      ]
    end
  end
end
