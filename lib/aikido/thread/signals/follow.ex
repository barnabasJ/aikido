defmodule Aikido.Thread.Signals.Follow do
  @moduledoc "Typed payload for `aikido.thread.follow`."
  use Aikido.Signal

  signal do
    type "aikido.thread.follow"

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

      attribute :after, Aikido.Thread.Types.Cursor do
        description "Last SQL-committed position; nil explicitly starts at retained beginning."
      end

      attribute :batch_size, :integer do
        description "Maximum entries in one outstanding batch."
        default 100
        allow_nil? false
        constraints min: 1, max: 1000
      end
    end
  end
end
