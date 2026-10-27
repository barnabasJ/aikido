defmodule AikidoTest.TestSignals.Increment do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "increment"

    schema do
      attribute :amount, :integer do
        description "Amount applied to the counter."
        default 1
      end
    end
  end
end

defmodule AikidoTest.TestSignals.Decrement do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "decrement"

    schema do
      attribute :amount, :integer do
        description "Amount applied to the counter."
        default 1
      end
    end
  end
end

defmodule AikidoTest.TestSignals.OptionalInput do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "noop"

    schema do
      attribute :value, :integer do
        description "Optional value used to exercise native argument casting."
      end
    end
  end
end

defmodule AikidoTest.TestSignals.Record do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "record"

    schema do
      attribute :data, :map do
        description "Message payload appended to the agent history."
        default %{}
      end
    end
  end
end

defmodule AikidoTest.TestSignals.Fail do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "fail"

    schema do
      attribute :reason, :string do
        description "Explanation returned by the failing command."
        default "intentional failure"
      end
    end
  end
end

defmodule AikidoTest.TestSignals.StoreValue do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "arithmetic.store"

    schema do
      attribute :value, :integer do
        description "Numeric input supplied to the arithmetic command."
        allow_nil? false
      end
    end
  end
end

defmodule AikidoTest.TestSignals.AddValue do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "arithmetic.add"

    schema do
      attribute :value, :integer do
        description "Numeric input supplied to the arithmetic command."
        allow_nil? false
      end

      attribute :amount, :integer do
        description "Numeric input supplied to the arithmetic command."
        default 1
      end
    end
  end
end

defmodule AikidoTest.TestSignals.Emit do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "events.emit"
  end
end

defmodule AikidoTest.TestSignals.EmitAndSchedule do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "events.emit_and_schedule"
  end
end

defmodule AikidoTest.TestSignals.UpdateAudit do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "audit.update"

    schema do
      attribute :reject?, :boolean do
        description "Whether the audit rejects this workflow update."
        default false
        allow_nil? false
      end
    end
  end
end
