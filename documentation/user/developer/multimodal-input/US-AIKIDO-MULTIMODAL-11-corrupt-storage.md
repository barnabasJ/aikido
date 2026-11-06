# US-AIKIDO-MULTIMODAL-11: Reject corrupt queue storage

Given a saved input element begins with the external-term version byte but its
encoded list is incomplete.

When native Ash loads that element through either queue type.

Then the native decoder rejects it instead of treating corrupt persisted data
as a new user message through a text fallback.

Owning test: `corrupt external-term queue storage fails instead of becoming user text`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-11`.
