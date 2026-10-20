defmodule AikidoTest.Support.TestTracer do
  @moduledoc false
  @behaviour Ash.Tracer
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def get_spans, do: Agent.get(__MODULE__, & &1)

  @impl true
  def start_span(type, name) do
    parent = get_span_context()
    ref = make_ref()
    Process.put({__MODULE__, :parents}, [parent | Process.get({__MODULE__, :parents}, [])])
    Process.put({__MODULE__, :span}, ref)
    pid = self()
    Agent.update(__MODULE__, &[{:start, ref, type, name}, {:parent, ref, parent, pid} | &1])
    :ok
  end

  @impl true
  def stop_span do
    ref = get_span_context()
    Agent.update(__MODULE__, &[{:stop, ref} | &1])
    [parent | parents] = Process.get({__MODULE__, :parents})
    Process.put({__MODULE__, :parents}, parents)
    set_span_context(parent)
  end

  @impl true
  def set_metadata(type, metadata) do
    ref = get_span_context()
    Agent.update(__MODULE__, &[{:metadata, ref, type, metadata} | &1])
    :ok
  end

  @impl true
  def set_error(error, opts) do
    ref = get_span_context()
    Agent.update(__MODULE__, &[{:exception, ref, error, opts} | &1])
    :ok
  end

  @impl true
  def get_span_context, do: Process.get({__MODULE__, :span})
  @impl true
  def set_span_context(context) do
    Process.put({__MODULE__, :span}, context)
    :ok
  end
end
