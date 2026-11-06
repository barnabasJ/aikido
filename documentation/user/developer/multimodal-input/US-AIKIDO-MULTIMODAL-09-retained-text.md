# US-AIKIDO-MULTIMODAL-09: Retained pending text

Given older typed snapshots stored nonempty pending input through native Ash
string-array encoding, including multibyte text.

When those stored values load through the current opening and queued input types.

Then each pending message retains its original text and order; adding multipart
input support does not discard previously accepted UTF-8 input.

Owning test: `retained native string-array storage loads without discarding pending text`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-09`.
