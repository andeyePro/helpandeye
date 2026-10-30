// Who is asking: signed session cookies, the salted address hash, Turnstile, the emailed sign-in
// link and GitHub. Tokens are signed with SESSION_SECRET and carry their own expiry, so nothing
// about a session is stored.

const enc = new TextEncoder();

function b64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function unb64url(s) {
  const t = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(t + "=".repeat((4 - (t.length % 4)) % 4)), (c) => c.charCodeAt(0));
}

async function hmac(secret, text) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(text)));
}

/// A token carrying `payload` until `expiresAt` (milliseconds), signed so it cannot be altered.
/// `use` names what it is for (a session, a sign-in link, a GitHub state), so a token made for
/// one thing is never taken for another.
export async function sign(secret, use, payload, expiresAt) {
  const body = b64url(enc.encode(JSON.stringify({ ...payload, use, exp: expiresAt })));
  return `${body}.${b64url(await hmac(secret, body))}`;
}

/// The payload of a token made for `use`, or null if it was altered, signed with another secret,
/// made for something else, or has expired.
export async function verify(secret, use, token, now = Date.now()) {
  if (typeof token !== "string") return null;
  const dot = token.indexOf(".");
  if (dot < 0) return null;
  const body = token.slice(0, dot);
  const expected = await hmac(secret, body);
  const given = unb64url(token.slice(dot + 1));
  if (given.length !== expected.length) return null;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= given[i] ^ expected[i];
  if (diff !== 0) return null;
  try {
    const payload = JSON.parse(new TextDecoder().decode(unb64url(body)));
    return payload.use === use && typeof payload.exp === "number" && payload.exp > now ? payload : null;
  } catch {
    return null;
  }
}

/// The address, salted with the secret and the UTC date and hashed. The salt changes every day,
/// so a hash cannot be matched to an address once its day's record has gone.
export async function addressHash(secret, address, now = Date.now()) {
  const day = new Date(now).toISOString().slice(0, 10);
  const bytes = await hmac(secret, `address\n${day}\n${address}`);
  return [...bytes.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function cookies(request) {
  const out = {};
  for (const part of (request.headers.get("Cookie") ?? "").split(";")) {
    const eq = part.indexOf("=");
    if (eq > 0) out[part.slice(0, eq).trim()] = part.slice(eq + 1).trim();
  }
  return out;
}

export function setCookie(name, value, maxAgeSeconds) {
  return `${name}=${value}; Max-Age=${maxAgeSeconds}; Path=/; Secure; HttpOnly; SameSite=Lax`;
}

/// Asks Cloudflare whether a Turnstile token is good.
export async function turnstileOk(secretKey, token, address) {
  if (typeof token !== "string" || !token) return false;
  try {
    const r = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ secret: secretKey, response: token, remoteip: address }),
    });
    return (await r.json()).success === true;
  } catch {
    return false;
  }
}

export function githubAuthUrl(clientId, redirectUri, state) {
  const q = new URLSearchParams({ client_id: clientId, redirect_uri: redirectUri, state });
  return `https://github.com/login/oauth/authorize?${q}`;
}

/// Trades GitHub's code for the user's numeric id, or null.
export async function githubUserId(env, code, redirectUri) {
  try {
    const t = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID, client_secret: env.GITHUB_CLIENT_SECRET, code, redirect_uri: redirectUri }),
    });
    const token = (await t.json()).access_token;
    if (!token) return null;
    const u = await fetch("https://api.github.com/user", {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "User-Agent": "site-bot" },
    });
    const id = (await u.json()).id;
    return Number.isInteger(id) ? String(id) : null;
  } catch {
    return null;
  }
}
