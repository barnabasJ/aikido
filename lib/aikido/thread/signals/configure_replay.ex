defmodule Aikido.Thread.Signals.ConfigureReplay do
  @moduledoc "Enable retained replay and merge metadata without rewriting existing history."
  use Aikido.Signal

  signal do
    type "aikido.thread.configure_replay"

    schema do
      attribute :path, :atom do
        description "Thread mount whose replay configuration is being updated."
        default :thread
        allow_nil? false
      end

      attribute :metadata, :map do
        description "Metadata patch merged with existing user metadata; it grants no authority."
        default %{}
        allow_nil? false
      end
    end
  end
end
