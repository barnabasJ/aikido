defmodule Aikido.Team.Types.Membership do
  @moduledoc "Typed member discovery fact carried in a retained roster entry."
  use Ash.TypedStruct

  typed_struct do
    field :name, :term do
      description "Native topology member name."
      allow_nil? false
    end

    field :reference, Aikido.Agent.Reference do
      description "Durable member address."
      allow_nil? false
    end

    field :previous_reference, Aikido.Agent.Reference do
      description "Prior address when a desired member resource was replaced."
    end

    field :owner, :term do
      description "Logical owner topology name."
    end

    field :event, Aikido.Team.Types.MembershipEvent do
      description "Native topology or activation transition."
      default :added
      allow_nil? false
    end

    field :active?, :boolean do
      description "Whether the source recorded a live incarnation for this fact."
      default false
      allow_nil? false
    end

    field :incarnation, :term do
      description "Native member activation correlation, without a PID."
    end

    field :team?, :boolean do
      description "Whether this member owns a nested roster journal."
      default false
      allow_nil? false
    end
  end
end
