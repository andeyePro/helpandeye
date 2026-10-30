// Email through Cloudflare Email Sending (the `send_email` binding, EMAIL). Off until the
// binding and EMAIL_FROM are set: then sign-in links and alerts cannot go, and `send` says so.

export function configured(env) {
  return Boolean(env && env.EMAIL && env.EMAIL_FROM);
}

/// Sends one plain-text email. Returns true if the binding took it.
export async function send(env, to, subject, text) {
  if (!configured(env)) return false;
  try {
    await env.EMAIL.send({ from: { email: env.EMAIL_FROM, name: env.EMAIL_FROM_NAME || "Site bot" }, to, subject, text });
    return true;
  } catch (e) {
    console.error("email not sent", e?.message ?? e);
    return false;
  }
}
