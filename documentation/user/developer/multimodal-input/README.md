# Multimodal user turns

These stories cover native text-plus-content input on real agents. The test
module uses an ExUnit-owned Aikido runtime and the normal durable backend.
Only the external model response is controlled by a generation client fixture.
No Aikido runtime or Ash command is mocked.

| Story | Contract |
| --- | --- |
| [US-AIKIDO-MULTIMODAL-01](US-AIKIDO-MULTIMODAL-01-user-turn.md) | Generated Ask submits one ordered user turn. |
| [US-AIKIDO-MULTIMODAL-02](US-AIKIDO-MULTIMODAL-02-queued-input.md) | Busy input preserves ordering and delivery deduplication. |
| [US-AIKIDO-MULTIMODAL-03](US-AIKIDO-MULTIMODAL-03-caller-scope.md) | Attachments do not replace caller authority. |
| [US-AIKIDO-MULTIMODAL-04](US-AIKIDO-MULTIMODAL-04-durable-input.md) | Actual durable restart retains history and pending input. |
| [US-AIKIDO-MULTIMODAL-05](US-AIKIDO-MULTIMODAL-05-synchronous-input.md) | Synchronous Ask forwards complete content. |
| [US-AIKIDO-MULTIMODAL-06](US-AIKIDO-MULTIMODAL-06-waiting-message.md) | A message resumes a waiting run with complete content. |
| [US-AIKIDO-MULTIMODAL-07](US-AIKIDO-MULTIMODAL-07-waiting-delivery.md) | A delivery resumes a waiting run with complete content. |
| [US-AIKIDO-MULTIMODAL-08](US-AIKIDO-MULTIMODAL-08-input-rejection.md) | Untyped content maps are rejected before model work. |
| [US-AIKIDO-MULTIMODAL-09](US-AIKIDO-MULTIMODAL-09-retained-text.md) | Older pending UTF-8 text remains readable. |
| [US-AIKIDO-MULTIMODAL-10](US-AIKIDO-MULTIMODAL-10-mixed-storage.md) | Mixed pending input survives native storage. |
| [US-AIKIDO-MULTIMODAL-11](US-AIKIDO-MULTIMODAL-11-corrupt-storage.md) | Corrupt term data fails instead of becoming text. |
| [US-AIKIDO-MULTIMODAL-12](US-AIKIDO-MULTIMODAL-12-unsupported-legacy-binary.md) | Unsupported byte-131 legacy input is rejected. |
| [US-AIKIDO-MULTIMODAL-13](US-AIKIDO-MULTIMODAL-13-authorized-inspection.md) | Authorized reads retain data while diagnostics hide it. |
| [US-AIKIDO-MULTIMODAL-14](US-AIKIDO-MULTIMODAL-14-queue-diagnostics.md) | Both populated queues are hidden in resource-aware diagnostics. |
| [US-AIKIDO-MULTIMODAL-15](US-AIKIDO-MULTIMODAL-15-blank-input.md) | Preserving whitespace does not admit blank authored input. |

Each story has exactly one owning case in
`test/aikido/ai_react/multimodal_user_turn_test.exs`; the waiting variants carry
separate IDs. The earlier scoped receipt predates this tag-only reconciliation.
No test execution of the revised tags is claimed. These scenarios do not
establish live provider compatibility.
