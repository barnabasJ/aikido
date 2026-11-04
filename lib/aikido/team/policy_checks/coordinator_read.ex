defmodule Aikido.Team.PolicyChecks.CoordinatorRead do
  @moduledoc """
  Native policy check for a finite coordination read by its current principal.

  Combine with application identity, organization and tenant restrictions.
  This grants no general inspect permission or Team control permission.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def init(options),
    do: Spark.Options.validate(options, timeout_ms: [type: :pos_integer, default: 100])

  @impl true
  def describe(_options), do: "the principal may read its current Team coordination view"

  @impl true
  def match?(actor, %{subject: %{action: %{name: :team_coordination}} = input}, options) do
    with {:ok, coordinator} <- Aikido.Team.MemberIdentity.coordinator(input) do
      Aikido.Team.MemberIdentity.matches?(
        coordinator,
        input.arguments.requester,
        %{actor: actor, tenant: input.tenant},
        options[:timeout_ms]
      )
    end
  end

  def match?(_actor, _context, _options), do: false
end
