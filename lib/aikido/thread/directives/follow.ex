defmodule Aikido.Thread.Directives.Follow do
  @moduledoc "Request journal replay using the current consumer's real durable identity."
  use Aikido.Directive

  typed_struct do
    field :source, Aikido.Agent.Reference do
      description "Journal source whose native policies authorize this consumer."
      allow_nil? false
    end

    field :path, :atom do
      description "Source Thread or Team mount."
      default :thread
      allow_nil? false
    end

    field :channel, Aikido.Thread.Types.Channel do
      description "Thread entries or Team membership journal."
      default :thread
      allow_nil? false
    end

    field :request_id, :string do
      description "Consumer credit identity; materialized at this request I/O boundary when omitted."
    end

    field :after, Aikido.Thread.Types.Cursor do
      description "Last SQL-committed cursor; nil explicitly accepts retained beginning."
    end

    field :batch_size, :integer do
      description "Requested bounded number of entries per batch."
      default 100
      allow_nil? false
      constraints min: 1, max: 1000
    end
  end

  @impl true
  def exec(directive, input, runtime) do
    type =
      if directive.channel == :thread,
        do: "aikido.thread.follow",
        else: "aikido.ash.team.follow_roster"

    signal =
      Aikido.Signal.new!(
        type,
        %{
          consumer: Aikido.Agent.Reference.from_runtime(runtime),
          path: directive.path,
          after: directive.after,
          batch_size: directive.batch_size
        },
        id: directive.request_id
      )

    Aikido.Thread.Delivery.send(directive.source, signal, :request, input, runtime)
  end
end
