# US-AIKIDO-MULTIMODAL-02: Complete queued input

As an application developer, I want messages and deliveries sent during work to
retain their attachments until the model can consume them.

Given a real agent has a model request in progress.

When text-only and multipart messages arrive through the public message and
delivery APIs.

Then each is one ordered user message at the next safe model boundary, and a
repeated delivery request ID does not append another message.
Leading whitespace and trailing newlines remain exact in text-only, queued
multipart and delivered input at both the model and native conversation boundary.

Owning test: `active message and delivery retain one ordered queue and delivery deduplication`,
tagged `US-AIKIDO-MULTIMODAL-02` in
`test/aikido/ai_react/multimodal_user_turn_test.exs`.
