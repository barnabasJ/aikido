defmodule Aikido.Team.PolicyChecks.MemberDelegation do
  @moduledoc """
  Native policy check for requester-bound delegation to a declared Team sibling.

  Use together with application identity and tenant policy checks. Both the
  external command and owning-resource signal admission evaluate this check;
  an earlier coordination read never grants authority for a later assignment.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def init(options),
    do: Spark.Options.validate(options, timeout_ms: [type: :pos_integer, default: 100])

  @impl true
  def describe(_options), do: "the current requester principal may delegate to this Team member"

  @impl true
  def match?(actor, %{subject: %{action: %{name: :assign_task}} = input}, options) do
    data = Map.get(input.arguments, :data, input.arguments)

    coordinator_request? = data[:requester] in [nil, :self]

    bound_notification? =
      if coordinator_request?,
        do: data[:notify] in [nil, :self],
        else: data[:notify] == data[:requester]

    with true <- bound_notification?,
         {:ok, coordinator} <- Aikido.Team.MemberIdentity.coordinator(input),
         %{topology: topology} <- coordinator.agent.state[:team],
         true <- Map.has_key?(topology.nodes, data[:member]),
         true <- coordinator_request? or data[:member] != data[:requester] do
      Aikido.Team.MemberIdentity.matches?(
        coordinator,
        data[:requester],
        %{actor: actor, tenant: input.tenant},
        options[:timeout_ms]
      )
    else
      {:error, error} -> {:error, error}
      _not_requester_bound -> false
    end
  end

  def match?(_actor, _context, _options), do: false
end
