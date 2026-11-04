defmodule Aikido.Team.PolicyChecks.MemberMessaging do
  @moduledoc """
  Authorizes a current principal's Team Send for explicitly listed signal types.

  Combine with application identity and payload permission checks. A type grant
  does not restrict a signal's model options, metadata or other payload fields.
  Types are exact names, with no wildcard expansion or default permission.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def init(options) do
    Spark.Options.validate(options,
      types: [type: {:list, :string}, required: true],
      timeout_ms: [type: :pos_integer, default: 100]
    )
  end

  @impl true
  def describe(_options),
    do: "the current requester principal may send this permitted Team signal"

  @impl true
  def match?(actor, %{subject: %{action: %{name: :send}} = input}, options) do
    data = Map.get(input.arguments, :data, input.arguments)

    with true <- data[:type] in options[:types],
         {:ok, coordinator} <- Aikido.Team.MemberIdentity.coordinator(input),
         %{topology: topology} <- coordinator.agent.state[:team],
         true <- data[:member] == :self or Map.has_key?(topology.nodes, data[:member]) do
      Aikido.Team.MemberIdentity.matches?(
        coordinator,
        data[:requester],
        %{actor: actor, tenant: input.tenant},
        options[:timeout_ms]
      )
    else
      {:error, error} -> {:error, error}
      _not_a_permitted_message -> false
    end
  end

  def match?(_actor, _context, _options), do: false
end
