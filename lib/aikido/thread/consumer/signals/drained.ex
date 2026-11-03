defmodule Aikido.Thread.Consumer.Signals.Drained do
  @moduledoc "Every known live source confirmed its committed head for this drain."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.drained"

    schema do
      attribute :request_id, :string do
        description "The originating drain signal ID."
        allow_nil? false
      end

      attribute :checkpoints, {:array, Aikido.Thread.Consumer.Types.Source} do
        description "Native source cursors committed by the application, containing no entry payloads."
        allow_nil? false
      end
    end
  end
end
