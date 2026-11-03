defmodule Aikido.Thread.Signals.Unfollow do
  @moduledoc "Typed payload for `aikido.thread.unfollow`."
  use Aikido.Signal

  signal do
    type "aikido.thread.unfollow"

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
    end
  end
end
