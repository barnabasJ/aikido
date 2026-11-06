# US-AIKIDO-MULTIMODAL-04: Durable input

As an application developer, I want retained history and pending user input to
survive an actual durable stop and restart.

Given an agent has completed a multipart conversation and accepted pending
text-only and multipart messages.

When it is stopped and restarted through its real public domain actions with
the same identity.

Then a different live process restores the retained conversation and consumes
pending messages in order before the next authored prompt. Native restart does
not replay a model request that was already interrupted.

Covered by `a real durable stop and restart retains multipart history and pending mixed input`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-04`.
