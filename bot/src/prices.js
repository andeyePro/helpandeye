// Anthropic's list prices, US dollars per million tokens, from
// https://platform.claude.com/docs/en/about-claude/pricing (read 2026-10-30). Haiku's prices
// are for prompts of 100K tokens or fewer, which the history cap keeps every prompt well under.
// A cache write costs 1.25 times the input price.
export const PRICES = {
  "claude-haiku-5-5": { input: 0.1, output: 0.5, cacheRead: 0.01 },
  "claude-sonnet-5-5": { input: 2, output: 10, cacheRead: 0.2 },
  "claude-opus-5-5": { input: 4, output: 20, cacheRead: 0.2 },
};

/// The estimated cost in dollars of one reply, from its token counts. A model not in the table
/// is costed as the dearest one here; the Worker refuses to run one, since a dearer model would
/// be under-counted.
export function cost(model, usage) {
  const p = PRICES[model] ?? PRICES["claude-opus-5-5"];
  const n = (v) => (typeof v === "number" ? v : 0);
  return (
    (n(usage.input_tokens) * p.input +
      n(usage.output_tokens) * p.output +
      n(usage.cache_read_input_tokens) * p.cacheRead +
      n(usage.cache_creation_input_tokens) * p.input * 1.25) /
    1_000_000
  );
}
