defmodule Aikido.Thread.Signals.Retry do
  @moduledoc "Typed payload for `aikido.thread.retry`."
  use Aikido.Signal

  signal do
    type "aikido.thread.retry"

    schema do
      attribute :consumer, Aikido.Agent.Reference do
        description "Durable consumer address authorized by the source."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Source mount receiving this request."
        default :thread
        allow_nil? false
      end

      attribute :notice_id, :string do
        description "Current availability notice to retry."
        allow_nil? false
      end

      attribute :generation, :string do
        description "Generation containing that batch."
        allow_nil? false
      end
    end
  end
end
