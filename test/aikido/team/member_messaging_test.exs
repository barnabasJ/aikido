defmodule Aikido.TeamMemberMessagingTest do
  use AikidoTest.Case, async: true
  alias Aikido.TeamMemberMessagingTest.{AiReceiver, Coordinator, Domain, Worker}

  @moduletag aikido_instance: Aikido.TeamMemberMessagingTest.Instance,
             aikido_scope_adapter: Aikido.TeamMemberMessagingTest.Authority

  setup do
    Process.register(self(), Aikido.TeamMemberMessagingTest.Observer)
    {:ok, owner: actor(true), alpha: actor(), bravo: actor(), ai_actor: actor()}
  end

  test "the native messaging check requires an explicitly configured type allowlist" do
    assert {:error, _error} = Aikido.Team.PolicyChecks.MemberMessaging.init([])

    assert {:ok, options} =
             Aikido.Team.PolicyChecks.MemberMessaging.init(types: ["test.member.message"])

    assert options[:types] == ["test.member.message"]
  end

  test "a bound child sends to a sibling using the receiver's authority and verified requester provenance",
       ctx do
    root = start_team(ctx)
    members = state(root.pid).team.members
    assert {:ok, _} = send_message(root, :bravo, :alpha, ctx.alpha, "sibling")
    assert_received_message(members.bravo, "sibling", ctx.bravo)
    assert_receive {:message_observed, recipient, "test.member.message", context}, 5_000
    assert recipient == members.bravo
    assert context.actor == ctx.bravo
    assert context.context.aikido_sender.id == root.id
    assert context.context.aikido_sender.resource == Coordinator
    assert_requester(context, :alpha, members.alpha, root)
    assert own(members.alpha).messages_received == 0
  end

  test "child-to-coordinator and logical-owner messaging do not confuse the requester with ownership",
       ctx do
    root = start_team(ctx, logical_owner?: true)
    members = state(root.pid).team.members

    assert {:ok, parent} =
             Aikido.AgentServer.state(members.bravo, &{:ok, Aikido.Ownership.parent(&1)})

    assert parent.pid == members.alpha
    assert {:ok, _} = send_message(root, :self, :bravo, ctx.bravo, "coordinator")
    assert_received_message(root.pid, "coordinator", ctx.owner)
    assert_receive {:message_observed, recipient, "test.member.message", context}, 5_000
    assert recipient == root.pid
    assert_requester(context, :bravo, members.bravo, root)
    assert {:ok, _} = send_message(root, :alpha, :bravo, ctx.bravo, "logical-owner")
    assert_received_message(members.alpha, "logical-owner", ctx.alpha)
  end

  test "coordinator nil and explicit self requester retain their native forms", ctx do
    root = start_team(ctx)
    bravo = state(root.pid).team.members.bravo

    for requester <- [nil, :self] do
      text = inspect(requester)
      assert {:ok, _} = send_message(root, :bravo, requester, ctx.owner, text)
      assert_received_message(bravo, text, ctx.bravo)
      assert_receive {:message_observed, ^bravo, "test.member.message", context}, 5_000
      assert context.context.aikido_requester.member == :self
      assert context.context.aikido_requester.reference.id == root.id
      assert context.context.aikido_requester.incarnation == nil
    end

    assert {:ok, _} = send_message(root, :self, nil, ctx.owner, "own-message")
    assert_received_message(root.pid, "own-message", ctx.owner)
  end

  test "distinct principals cannot forge another requester or coordinator authority", ctx do
    root = start_team(ctx)

    for requester <- [:bravo, nil, :self] do
      assert {:error, %Ash.Error.Forbidden{}} =
               send_message(root, :bravo, requester, ctx.alpha, "forged")
    end

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.coordinator_send(
               root,
               %{
                 member: :bravo,
                 requester: :bravo,
                 type: "test.member.message",
                 payload: %{text: "forged-context", grant: "allowed"}
               },
               scope: scope(ctx.alpha),
               context: %{
                 aikido_requester: %{member: :bravo},
                 aikido_sender: %{id: root.id, resource: Coordinator}
               }
             )

    assert own(state(root.pid).team.members.bravo).messages_received == 0
  end

  test "type allowlists and native application payload restrictions are conjunctive", ctx do
    root = start_team(ctx)

    for {type, payload} <- [
          {"test.member.unlisted", %{text: "unlisted", grant: "allowed"}},
          {"test.member.message", %{text: "no-grant", grant: "denied"}},
          {"ai.react.deliver",
           %{text: "foreign-model", request_id: "forged", grant: "allowed", model: "foreign"}},
          {"ai.react.deliver",
           %{
             text: "foreign-options",
             request_id: "forged",
             grant: "allowed",
             options: %{max_iterations: 99}
           }}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Domain.coordinator_send(
                 root,
                 %{
                   member: :bravo,
                   requester: :alpha,
                   type: type,
                   payload: payload
                 },
                 scope: scope(ctx.alpha)
               )
    end

    assert {:error, %Ash.Error.Forbidden{}} =
             send_message(root, :missing, :alpha, ctx.alpha, "missing")

    assert {:ok, _} = send_message(root, :bravo, :alpha, ctx.alpha, "allowed")
    assert_received_message(state(root.pid).team.members.bravo, "allowed", ctx.bravo)
  end

  test "stopped and replaced requester incarnations cannot retain a different principal's send permission",
       ctx do
    root = start_team(ctx)
    original = state(root.pid).team.members.alpha
    Domain.coordinator_stop_member!(root, %{member: :alpha}, scope: scope(ctx.owner))

    assert {:error, %Ash.Error.Forbidden{}} =
             send_message(root, :bravo, :alpha, ctx.alpha, "stopped")

    Domain.coordinator_remove_member!(root, %{member: :alpha}, scope: scope(ctx.owner))
    replacement_actor = actor()

    Domain.coordinator_add_member!(
      root,
      %{
        member: :alpha,
        resource: Worker,
        initial_state: %{actor_id: replacement_actor.id}
      },
      scope: scope(ctx.owner)
    )

    assert state(root.pid).team.members.alpha != original

    assert {:error, %Ash.Error.Forbidden{}} =
             send_message(root, :bravo, :alpha, ctx.alpha, "retired")

    assert {:ok, _} = send_message(root, :bravo, :alpha, replacement_actor, "replacement")
    assert_received_message(state(root.pid).team.members.bravo, "replacement", ctx.bravo)
  end

  test "a legitimate request overwrites caller-supplied sender and requester context with verified facts",
       ctx do
    root = start_team(ctx)
    members = state(root.pid).team.members

    assert {:ok, _} =
             Domain.coordinator_send(
               root,
               %{
                 member: :bravo,
                 requester: :alpha,
                 type: "test.member.message",
                 payload: %{text: "verified-context", grant: "allowed"}
               },
               scope: scope(ctx.alpha),
               context: %{
                 aikido_sender: %{id: "forged-sender", resource: AiReceiver},
                 aikido_requester: %{
                   member: :bravo,
                   reference: "forged-reference",
                   incarnation: "forged"
                 }
               }
             )

    assert_received_message(members.bravo, "verified-context", ctx.bravo)
    assert_receive {:message_observed, recipient, "test.member.message", context}, 5_000
    assert recipient == members.bravo
    assert context.context.aikido_sender.id == root.id
    assert context.context.aikido_sender.resource == Coordinator
    assert_requester(context, :alpha, members.alpha, root)
  end

  test "stale transport recipient addresses and target PIDs cannot select a different-resource replacement",
       ctx do
    root = start_team(ctx)
    members = state(root.pid).team.members
    old_pid = members.bravo

    assert {:ok, old_reference} =
             Aikido.AgentServer.state(old_pid, &{:ok, Aikido.Agent.Reference.from_runtime(&1)})

    assert {:ok, requester_reference} =
             Aikido.AgentServer.state(
               members.alpha,
               &{:ok, Aikido.Agent.Reference.from_runtime(&1)}
             )

    Domain.coordinator_stop_member!(root, %{member: :bravo}, scope: scope(ctx.owner))
    Domain.coordinator_remove_member!(root, %{member: :bravo}, scope: scope(ctx.owner))
    replacement_actor = actor()

    Domain.coordinator_add_member!(
      root,
      %{
        member: :bravo,
        resource: Coordinator,
        initial_state: %{actor_id: replacement_actor.id}
      },
      scope: scope(ctx.owner)
    )

    new_pid = state(root.pid).team.members.bravo
    assert new_pid != old_pid

    assert {:ok, new_reference} =
             Aikido.AgentServer.state(new_pid, &{:ok, Aikido.Agent.Reference.from_runtime(&1)})

    assert old_reference.resource == Worker
    assert new_reference.resource == Coordinator
    assert old_reference.id == new_reference.id

    assert {:ok, sender} =
             Aikido.AgentServer.state(root.pid, fn runtime ->
               {:ok,
                %{
                  id: runtime.id,
                  pid: root.pid,
                  resource: runtime.agent_module,
                  aikido: runtime.aikido,
                  partition: runtime.partition,
                  parent: Aikido.Ownership.parent(runtime)
                }}
             end)

    requester =
      Aikido.Team.Types.MessageRequester.new!(
        member: :alpha,
        reference: requester_reference,
        incarnation: state(root.pid).team.incarnations.alpha
      )

    signal =
      Aikido.TeamMemberMessagingTest.Message.new!(%{text: "boundary-only", grant: "allowed"})

    delivery = %{
      kind: :message,
      signal_type: signal.type,
      target: new_pid,
      recipient: new_reference,
      requester: requester
    }

    # Protocol-boundary unit negatives use actual runtime snapshots; no runtime state is changed.
    assert {:ok, {valid, stale_reference, stale_pid}} =
             Aikido.AgentServer.state(new_pid, fn runtime ->
               {:ok,
                {
                  Aikido.Signal.Delivery.receive_signal(
                    runtime,
                    Aikido.Team.Delivery,
                    sender,
                    signal,
                    delivery
                  ),
                  Aikido.Signal.Delivery.receive_signal(
                    runtime,
                    Aikido.Team.Delivery,
                    sender,
                    signal,
                    Map.put(delivery, :recipient, old_reference)
                  ),
                  Aikido.Signal.Delivery.receive_signal(
                    runtime,
                    Aikido.Team.Delivery,
                    sender,
                    signal,
                    Map.put(delivery, :target, old_pid)
                  )
                }}
             end)

    assert {:ok, _bound_signal} = valid
    assert stale_reference == :ignore
    assert stale_pid == :ignore

    # Deliberately malformed typed input is constructed only for rejection at this protocol boundary.
    for malformed_reference <- [
          nil,
          %{},
          "not-a-reference",
          Map.put(requester_reference, :id, nil),
          Map.put(requester_reference, :resource, nil)
        ] do
      malformed_requester = Map.put(requester, :reference, malformed_reference)

      assert {:ok, :ignore} =
               Aikido.AgentServer.state(new_pid, fn runtime ->
                 {:ok,
                  Aikido.Signal.Delivery.receive_signal(
                    runtime,
                    Aikido.Team.Delivery,
                    sender,
                    signal,
                    Map.put(delivery, :requester, malformed_requester)
                  )}
               end)
    end

    assert own(new_pid).messages_received == 0
    assert {:ok, _} = send_message(root, :bravo, :alpha, ctx.alpha, "current-recipient")
    assert_received_message(new_pid, "current-recipient", replacement_actor)
  end

  test "an authorized requester receives the native not-running error for a stopped target",
       ctx do
    root = start_team(ctx)
    Domain.coordinator_stop_member!(root, %{member: :bravo}, scope: scope(ctx.owner))
    assert {:error, error} = send_message(root, :bravo, :alpha, ctx.alpha, "stopped-target")
    assert invalid_argument?(error), inspect(error)
  end

  test "a bound coordinator never lends its authority to an intentionally anonymous receiver",
       ctx do
    root = start_team(ctx)

    Domain.coordinator_add_member!(
      root,
      %{
        member: :anonymous,
        resource: Aikido.TeamMemberMessagingTest.AnonymousWorker
      },
      scope: scope(ctx.owner)
    )

    anonymous = state(root.pid).team.members.anonymous
    assert {:ok, binding} = Aikido.AgentServer.state(anonymous, &{:ok, &1.bound_execution_scope})
    assert binding[:actor] == nil
    assert binding[:tenant] == nil
    assert {:ok, _} = send_message(root, :anonymous, nil, ctx.owner, "anonymous-message")

    received =
      await_state_value(anonymous, fn runtime ->
        own = Aikido.Agent.resource_attributes(runtime.agent)
        if own.text == "anonymous-message", do: own
      end)

    assert received.seen_actor == nil
    assert received.seen_tenant == nil
    assert_receive {:message_observed, ^anonymous, "test.member.message", context}, 5_000
    assert context[:actor] == nil
    assert context[:tenant] == nil
    assert context.context.aikido_sender.id == root.id
    assert context.context.aikido_requester.member == :self
    assert context.context.aikido_requester.reference.id == root.id
  end

  test "Team delivery reaches a real active AI run under its receiver identity while foreign direct delivery is rejected",
       ctx do
    root = start_team(ctx, ai?: true)
    members = state(root.pid).team.members
    ai = members.ai
    request_id = Ash.UUIDv7.generate()

    Domain.ai_receiver_ask!(ai, %{query: "initial", request_id: request_id},
      scope: scope(ctx.ai_actor)
    )

    assert_receive {:messaging_provider_called, _provider, "offline:messaging", _, _}, 5_000

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.ai_receiver_deliver(
               ai,
               %{
                 text: "foreign-direct",
                 request_id: Ash.UUIDv7.generate()
               },
               scope: scope(ctx.alpha)
             )

    delivery_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Domain.coordinator_send(
               root,
               %{
                 member: :ai,
                 requester: :alpha,
                 type: "ai.react.deliver",
                 payload: %{text: "team-message", request_id: delivery_id, grant: "allowed"}
               },
               scope: scope(ctx.alpha)
             )

    ai_state =
      await_state_value(ai, fn runtime ->
        ai_state = runtime.agent.state.ai
        if delivery_id in ai_state.accepted_delivery_ids, do: ai_state
      end)

    assert "team-message" in ai_state.queued_messages
    refute "foreign-direct" in ai_state.queued_messages
    assert ai_state.run_scope.actor == ctx.ai_actor
    assert ai_state.run_scope.tenant == "member-messaging"
    assert_receive {:message_observed, ^ai, "ai.react.deliver", context}, 5_000

    # A rejected direct request may be observed before native owning admission; select the verified delivery.
    context = verified_delivery_context(ai, context)
    assert context.actor == ctx.ai_actor
    assert context.context.aikido_sender.id == root.id
    assert_requester(context, :alpha, members.alpha, root)
    Domain.ai_receiver_cancel!(ai, %{request_id: request_id}, scope: scope(ctx.ai_actor))

    await_state_value(ai, fn runtime ->
      ai_state = runtime.agent.state.ai
      if ai_state.status == :failed && ai_state.error == :cancelled, do: :cancelled
    end)
  end

  defp start_team(ctx, options \\ []) do
    bravo = %{resource: Worker, initial_state: %{actor_id: ctx.bravo.id}}
    bravo = if options[:logical_owner?], do: Map.put(bravo, :owner, :alpha), else: bravo

    topology = %{
      alpha: %{resource: Worker, initial_state: %{actor_id: ctx.alpha.id}},
      bravo: bravo
    }

    topology =
      if options[:ai?],
        do:
          Map.put(topology, :ai, %{
            resource: AiReceiver,
            initial_state: %{actor_id: ctx.ai_actor.id}
          }),
        else: topology

    Domain.coordinator_start!(
      %{id: Ash.UUIDv7.generate(), actor_id: ctx.owner.id, topology: topology},
      scope: scope(ctx.owner)
    )
  end

  defp actor(coordinator? \\ false),
    do: %{id: Ash.UUIDv7.generate(), allowed: true, coordinator?: coordinator?}

  defp scope(actor), do: %{actor: actor, tenant: "member-messaging"}

  defp send_message(root, member, requester, actor, text) do
    Domain.coordinator_send(
      root,
      %{
        member: member,
        requester: requester,
        type: "test.member.message",
        payload: %{text: text, grant: "allowed"}
      },
      scope: scope(actor)
    )
  end

  defp assert_received_message(pid, text, actor) do
    received =
      await_state_value(pid, fn runtime ->
        own = Aikido.Agent.resource_attributes(runtime.agent)
        if own.text == text, do: own
      end)

    assert received.seen_actor == actor.id
    received
  end

  defp state(pid) do
    assert {:ok, attributes} =
             Aikido.AgentServer.state(pid, &{:ok, Aikido.Agent.resource_attributes(&1.agent)})

    attributes
  end

  defp own(pid), do: state(pid)
  defp invalid_argument?(%Ash.Error.Action.InvalidArgument{}), do: true
  defp invalid_argument?(%{errors: errors}), do: Enum.any?(errors, &invalid_argument?/1)
  defp invalid_argument?(_error), do: false

  defp assert_requester(context, member, pid, root) do
    requester = context.context.aikido_requester
    assert requester.member == member

    assert {:ok, reference} =
             Aikido.AgentServer.state(pid, &{:ok, Aikido.Agent.Reference.from_runtime(&1)})

    assert requester.reference == reference
    assert requester.incarnation == state(root.pid).team.incarnations[member]
  end

  defp verified_delivery_context(ai, context) do
    if get_in(context, [:context, :aikido_requester]) do
      context
    else
      assert_receive {:message_observed, ^ai, "ai.react.deliver", verified}, 5_000
      verified
    end
  end
end
