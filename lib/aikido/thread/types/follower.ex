defmodule Aikido.Thread.Types.Follower do
  @moduledoc "A durable consumer address, acknowledged cursor and bounded outstanding range."
  use Ash.TypedStruct

  typed_struct do
    field :consumer, Aikido.Agent.Reference do
      description "Authorized consumer address, never a persisted PID or caller scope."
      allow_nil? false
    end

    field :cursor, Aikido.Thread.Types.Cursor do
      description "Position acknowledged after the consumer's database commit."
      allow_nil? false
    end

    field :batch_size, :integer do
      description "Maximum number of entries offered in one batch."
      default 100
      allow_nil? false
      constraints min: 1, max: 1000
    end

    field :in_flight, Aikido.Thread.Types.Batch do
      description "Only outstanding range; entries remain in the source journal."
    end

    field :notice_id, :string do
      description "Coalesced availability notice; no new private batch is sent without a fresh Follow."
    end

    field :paused?, :boolean do
      description "A gap requires an explicit new Follow cursor before delivery resumes."
      default false
      allow_nil? false
    end
  end
end
