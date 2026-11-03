defmodule AikidoTest.LegacyCheckpoint.Plain do
  @moduledoc "Ordinary persisted agent shared with the immutable old-version fixture generator."
  use Aikido.Agent, domain: AikidoTest.LegacyCheckpoint.Domain

  agent do
    name "legacy_plain"
    persistence :permanent
    slice :thread, Aikido.Thread.Slice

    schema do
      attribute :label, :string do
        description "Original user value whose identity must survive schema restoration."
        default "original"
      end
    end
  end
end

defmodule AikidoTest.LegacyCheckpoint.Opaque do
  @moduledoc "Application-owned opaque checkpoint retaining the actual old agent resource graph."
  use Aikido.Agent, domain: AikidoTest.LegacyCheckpoint.Domain

  agent do
    name "legacy_opaque"
    persistence :permanent
    slice :thread, Aikido.Thread.Slice

    schema do
      attribute :label, :string do
        description "Original user value retained by the application checkpoint callback."
        default "original"
      end
    end
  end

  @impl true
  def checkpoint(agent, _context), do: {:ok, %{version: 1, agent: agent}}

  @impl true
  def restore(%{version: 1, agent: agent}, _context), do: {:ok, agent}
end

defmodule AikidoTest.LegacyCheckpoint.Domain do
  @moduledoc "Native lifecycle and signal commands used to produce historical fixtures."
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :plain, AikidoTest.LegacyCheckpoint.Plain
    agent :opaque, AikidoTest.LegacyCheckpoint.Opaque
  end
end

defmodule AikidoTest.LegacyCheckpoint.AnonymousAuthority do
  @moduledoc "Anonymous native preparation contract for public fixture resources without actor policies."
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, _scope, _identity), do: {:ok, attributes, nil}

  @impl true
  def restore(nil, _saved, _identity), do: {:ok, %{}}

  @impl true
  def checkpoint(_agent, nil, _identity), do: {:ok, nil}
end

defmodule AikidoTest.LegacyCheckpoint.RefusedAuthority do
  @moduledoc "A revoked native restoration grant used to verify authentication precedes hydration."
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(_attributes, _scope, _identity), do: {:error, :revoked}

  @impl true
  def restore(_credential, _saved, _identity), do: {:error, :revoked}

  @impl true
  def checkpoint(_agent, _credential, _identity), do: {:error, :revoked}
end
