defmodule Aikido.Thread.Consumer.Signals.ConfigureRetry do
  @moduledoc "Configure the native bounded sink retry policy under the consumer's write authority."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.configure_retry"

    schema do
      attribute :retry_limit, :integer do
        description "Maximum automatic retries since successful commit or explicit manual retry."
        allow_nil? false
        constraints min: 0, max: 100
      end
    end
  end
end
