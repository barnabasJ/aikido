# US-AIKIDO-MULTIMODAL-03: Caller scope

As an application developer, I want multipart input to respect the same actor
and tenant boundaries as text input.

Given a real run is bound to its original caller and tenant.

When another caller or tenant attempts to deliver multipart content.

Then the ordinary receiving action rejects the input before queue adoption or
delivery-ID acceptance. Attachments supply content, not execution authority.

Covered by `content never replaces the active caller or tenant` in
`test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-03`.
