defmodule Aikido.Thread.Consumer.Signals.DrainBlocked do
  @moduledoc "A drain paused because a source cannot safely reach a committed head."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.drain_blocked"

    schema do
      attribute :request_id, :string do
        description "The originating drain signal ID."
        allow_nil? false
      end

      attribute :source, Aikido.Thread.Consumer.Types.Source do
        description "Source with an explicit gap, authorization, availability or sink failure."
        allow_nil? false
      end
    end
  end
end
