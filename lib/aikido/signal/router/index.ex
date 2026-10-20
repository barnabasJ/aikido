# Adapted from Jido Signal 3.0.0-beta.5 router/index.ex (Apache-2.0).
# Copyright 2026 Mike Hostetler <mike.hostetler@gmail.com>.
# Aikido modifications: owned modules, native validation, generic envelopes,
# and only immutable construction, lookup, and compiled pattern matching.
# See NOTICE for source provenance and adaptation details.
defmodule Aikido.Signal.Router.Index do
  @moduledoc false

  alias Aikido.Signal.Router

  @doc false
  @spec new([map()]) :: Router.t()
  def new(routes) do
    entries = compile_entries(routes)
    router = %Router{}

    {exact_index, wildcard_index, _next_node_id} =
      index_entries(entries, router.exact_index, router.wildcard_index, 1)

    %{router | exact_index: exact_index, wildcard_index: wildcard_index}
  end

  @doc false
  @spec lookup(Router.t(), String.t(), map()) :: [term()]
  def lookup(%Router{} = router, type, signal) do
    (Map.get(router.exact_index, type, []) ++
       wildcard_matches(router.wildcard_index, type))
    |> Enum.filter(&predicate_matches?(&1.route.match, signal))
    |> Enum.sort_by(&precedence_key/1, :desc)
    |> Enum.flat_map(&targets/1)
  end

  @doc false
  @spec compile_pattern(String.t()) :: String.t() | tuple()
  def compile_pattern(pattern) do
    if wildcard_path?(pattern),
      do: pattern |> String.split(".") |> List.to_tuple(),
      else: pattern
  end

  @doc false
  @spec matches_compiled?(String.t(), String.t() | tuple()) :: boolean()
  def matches_compiled?(type, _pattern) when not is_binary(type), do: false

  def matches_compiled?(type, pattern) when is_binary(pattern), do: type == pattern

  def matches_compiled?(type, pattern) when is_tuple(pattern) do
    match_tuples?(type |> String.split(".") |> List.to_tuple(), pattern)
  end

  defp compile_entries(routes) do
    routes
    |> Enum.with_index()
    |> Enum.map(fn {route, order} ->
      segments = String.split(route.path, ".")

      %{
        route: route,
        segments: segments,
        class: pattern_class(segments),
        complexity: pattern_complexity(segments),
        order: order
      }
    end)
  end

  defp index_entries(entries, exact_index, wildcard_index, next_node_id) do
    Enum.reduce(
      entries,
      {exact_index, wildcard_index, next_node_id},
      fn entry, {exact, wildcard, node_id} ->
        if entry.class == 2 do
          {Map.update(exact, entry.route.path, [entry], &[entry | &1]), wildcard, node_id}
        else
          {wildcard, node_id} = insert_trie(wildcard, entry.segments, entry, node_id)
          {exact, wildcard, node_id}
        end
      end
    )
  end

  defp insert_trie(node, [], entry, next_node_id) do
    {%{node | terminals: [entry | node.terminals]}, next_node_id}
  end

  defp insert_trie(node, [segment | rest], entry, next_node_id) do
    {child, next_node_id} = trie_child(node, segment, next_node_id)
    {child, next_node_id} = insert_trie(child, rest, entry, next_node_id)
    {put_trie_child(node, segment, child), next_node_id}
  end

  defp trie_child(node, "*", next_node_id),
    do: existing_or_new_node(node.single, next_node_id, false)

  defp trie_child(node, "**", next_node_id),
    do: existing_or_new_node(node.multi, next_node_id, true)

  defp trie_child(node, segment, next_node_id),
    do: existing_or_new_node(Map.get(node.exact, segment), next_node_id, false)

  defp existing_or_new_node(nil, next_node_id, globstar?) do
    {new_trie_node(next_node_id, globstar?), next_node_id + 1}
  end

  defp existing_or_new_node(node, next_node_id, _globstar?), do: {node, next_node_id}

  defp new_trie_node(id, globstar?) do
    %{
      id: id,
      exact: %{},
      single: nil,
      multi: nil,
      terminals: [],
      globstar?: globstar?
    }
  end

  defp put_trie_child(node, "*", child), do: %{node | single: child}
  defp put_trie_child(node, "**", child), do: %{node | multi: child}

  defp put_trie_child(node, segment, child) do
    %{node | exact: Map.put(node.exact, segment, child)}
  end

  defp wildcard_matches(
         %{exact: exact, single: nil, multi: nil, terminals: []},
         _type
       )
       when map_size(exact) == 0,
       do: []

  defp wildcard_matches(root, type) do
    segments = type |> String.split(".") |> List.to_tuple()
    {_visited, matches} = walk_trie(root, segments, tuple_size(segments), 0, %{}, [])
    matches
  end

  defp walk_trie(node, segments, segment_count, position, visited, matches) do
    state = {node.id, position}

    if Map.has_key?(visited, state) do
      {visited, matches}
    else
      visited = Map.put(visited, state, true)
      matches = if position == segment_count, do: node.terminals ++ matches, else: matches

      {visited, matches} =
        walk_segment_children(node, segments, segment_count, position, visited, matches)

      {visited, matches} =
        case node.multi do
          nil -> {visited, matches}
          child -> walk_trie(child, segments, segment_count, position, visited, matches)
        end

      if node.globstar? and position < segment_count do
        walk_trie(node, segments, segment_count, position + 1, visited, matches)
      else
        {visited, matches}
      end
    end
  end

  defp walk_segment_children(node, segments, segment_count, position, visited, matches)
       when position < segment_count do
    segment = elem(segments, position)

    {visited, matches} =
      case Map.get(node.exact, segment) do
        nil -> {visited, matches}
        child -> walk_trie(child, segments, segment_count, position + 1, visited, matches)
      end

    case node.single do
      nil -> {visited, matches}
      child -> walk_trie(child, segments, segment_count, position + 1, visited, matches)
    end
  end

  defp walk_segment_children(
         _node,
         _segments,
         _segment_count,
         _position,
         visited,
         matches
       ),
       do: {visited, matches}

  defp wildcard_path?(path), do: String.contains?(path, "*")

  defp pattern_class(segments) do
    cond do
      "**" in segments -> 0
      "*" in segments -> 1
      true -> 2
    end
  end

  defp pattern_complexity(segments) do
    length = length(segments)
    pattern_complexity(segments, length, 0, length * 2000)
  end

  defp pattern_complexity([], _length, _index, score), do: score

  defp pattern_complexity(["*" | rest], length, index, score),
    do: pattern_complexity(rest, length, index + 1, score - 1000 + index * 100)

  defp pattern_complexity(["**" | rest], length, index, score),
    do: pattern_complexity(rest, length, index + 1, score - 2000 + index * 200)

  defp pattern_complexity([_segment | rest], length, index, score),
    do: pattern_complexity(rest, length, index + 1, score + 3000 * (length - index))

  defp precedence_key(entry) do
    {entry.class, entry.complexity, entry.route.priority, -entry.order}
  end

  defp predicate_matches?(match, signal) do
    is_nil(match) or match.(signal) == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp targets(%{route: %{target: targets}}) when is_list(targets),
    do: targets

  defp targets(%{route: %{target: target}}), do: [target]

  defp match_tuples?(type_segments, pattern_segments) do
    do_match_segments(
      type_segments,
      pattern_segments,
      tuple_size(type_segments),
      tuple_size(pattern_segments),
      0,
      0,
      nil,
      nil
    )
  end

  defp do_match_segments(type, pattern, type_size, pattern_size, i, j, star_i, star_j) do
    cond do
      j < pattern_size and elem(pattern, j) == "**" ->
        do_match_segments(type, pattern, type_size, pattern_size, i, j + 1, i, j + 1)

      i < type_size and j < pattern_size and
          segment_matches?(elem(type, i), elem(pattern, j)) ->
        do_match_segments(type, pattern, type_size, pattern_size, i + 1, j + 1, star_i, star_j)

      i == type_size ->
        remaining_multi_wildcards?(pattern, j, pattern_size)

      not is_nil(star_j) and star_i < type_size ->
        next_i = star_i + 1
        do_match_segments(type, pattern, type_size, pattern_size, next_i, star_j, next_i, star_j)

      true ->
        false
    end
  end

  defp segment_matches?(type_segment, pattern_segment),
    do: pattern_segment == "*" or pattern_segment == type_segment

  defp remaining_multi_wildcards?(_pattern, index, size) when index == size, do: true

  defp remaining_multi_wildcards?(pattern, index, size) do
    elem(pattern, index) == "**" and remaining_multi_wildcards?(pattern, index + 1, size)
  end
end
