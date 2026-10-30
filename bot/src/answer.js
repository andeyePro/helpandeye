import Anthropic from "@anthropic-ai/sdk";
import { cost } from "./prices.js";

// Haiku 5.5 answers from a short, fixed text at a fraction of the price of the larger models,
// and this is a FAQ, not a reasoning task. MODEL changes it.
export const DEFAULT_MODEL = "claude-haiku-5-5";
// A question of 2,000 characters and a history of 20 turns keep a prompt far under Haiku's
// 100K-token price step, whatever a visitor sends.
export const MAX_TURNS = 20;
export const MAX_CHARS = 2000;

export class BotError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/// The conversation as the API takes it: user and assistant turns in order, ending with the
/// visitor's question. Anything else is refused with 400.
export function conversation(messages) {
  if (!Array.isArray(messages) || messages.length % 2 === 0 || messages.length > MAX_TURNS) throw new BotError(400, "bad messages");
  return messages.map((m, i) => {
    const role = i % 2 === 0 ? "user" : "assistant";
    if (!m || m.role !== role || typeof m.content !== "string" || !m.content.trim() || m.content.length > MAX_CHARS) throw new BotError(400, "bad messages");
    return { role, content: m.content };
  });
}

/// Asks the model. Returns the answer's text, the token counts and the estimated cost.
export async function answer({ apiKey, model = DEFAULT_MODEL, system, messages, refusal }) {
  const client = new Anthropic({ apiKey, maxRetries: 1 });
  let response;
  try {
    response = await client.messages.create({
      model,
      // Two short paragraphs; the prompt asks for no more.
      max_tokens: 1024,
      // Cached, so the site content is paid for once every five minutes, not with every question.
      system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
      messages,
      output_config: { effort: "low" },
    });
  } catch (e) {
    if (e instanceof Anthropic.RateLimitError) throw new BotError(503, "busy, try again in a moment");
    if (e instanceof Anthropic.APIError) throw new BotError(502, "could not get an answer");
    throw e;
  }
  const usage = response.usage ?? {};
  const text = response.stop_reason === "refusal"
    ? refusal
    : response.content.filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();
  return { text: text || refusal, usage, usd: cost(model, usage) };
}
