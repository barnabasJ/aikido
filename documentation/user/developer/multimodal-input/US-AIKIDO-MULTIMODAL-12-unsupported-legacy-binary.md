# US-AIKIDO-MULTIMODAL-12: Unsupported legacy binary

Given the old string type could store an arbitrary binary beginning with byte
131, followed by bytes that do not form an external term.

When that stored value loads through either current queue type.

Then native decoding rejects it; the UTF-8 compatibility branch does not claim
that this unsupported binary is retained user text. A valid external term cannot
be distinguished from an arbitrary old binary with the same bytes.

Owning test: `legacy binary text beginning with byte 131 is not accepted as retained UTF-8 text`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-12`.
