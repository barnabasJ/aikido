defmodule Aikido.Thread.Consumer.Signals.Resume do
  @moduledoc "Resume journal demand after an explicit completed or blocked drain."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.resume"
  end
end
