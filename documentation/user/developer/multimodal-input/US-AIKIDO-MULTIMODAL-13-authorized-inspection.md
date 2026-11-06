# US-AIKIDO-MULTIMODAL-13: Authorized inspection

Given a real agent has accepted a pending multipart message.

When its authorized caller inspects the selected AI state and that state is
also passed to native resource Inspect and the existing Inspector projection.

Then the caller can read the actual pending content, diagnostics hide it using
sensitive metadata, and diagnostic projection does not change the live queue.

Owning test: `sensitive queues stay readable to an authorized caller but are hidden by native diagnostics`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-13`.
