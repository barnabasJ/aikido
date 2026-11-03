defmodule Aikido.Thread.Signals.Gap do
  @moduledoc "Typed payload for `aikido.thread.gap`."
  use Aikido.Signal

  signal do
    type "aikido.thread.gap"

    schema do
      attribute :request_id, :string do
        description "Follow request selecting this response; source gap notices may reference another source turn."
        allow_nil? false
      end

      attribute :source, Aikido.Agent.Reference do
        description "Durable source identity."
        allow_nil? false
      end

      attribute :consumer, Aikido.Agent.Reference do
        description "Durable consumer address authorized by the source."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Source mount receiving this request."
        default :thread
        allow_nil? false
      end

      attribute :channel, Aikido.Thread.Types.Channel do
        description "Owning Thread or Team roster journal."
        allow_nil? false
      end

      attribute :requested, Aikido.Thread.Types.Cursor do
        description "Cursor which cannot be satisfied."
        allow_nil? false
      end

      attribute :available, Aikido.Thread.Types.Cursor do
        description "Earliest position from which retained replay can start."
        allow_nil? false
      end

      attribute :reason, Aikido.Thread.Types.GapReason do
        description "Explicit reset, pruning or invalid future cursor reason."
        allow_nil? false
      end
    end
  end
end
