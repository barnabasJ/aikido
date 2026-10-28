defmodule Aikido.Agent.StateAction do
  @moduledoc false

  @doc false
  def add(dsl) do
    fields =
      for attribute <- Enum.uniq_by(Ash.Resource.Info.attributes(dsl), & &1.name),
          !attribute.primary_key? do
        {attribute.name, [type: :term, allow_nil?: true]}
      end

    with {:ok, argument} <-
           Ash.Resource.Builder.build_action_argument(:changes, :map,
             allow_nil?: false,
             constraints: [fields: fields, preserve_nil_values?: true]
           ) do
      Ash.Resource.Builder.add_action(dsl, :update, :__aikido_apply_state__,
        public?: false,
        accept: [],
        arguments: [argument],
        require_atomic?: false,
        manual: Aikido.Agent.Actions.ApplyState,
        changes: [Ash.Resource.Builder.build_action_change(Aikido.Agent.Changes.ApplyState)]
      )
    end
  end
end
