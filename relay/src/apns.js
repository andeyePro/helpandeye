// Apple push notifications, so the relay can wake a responder's phone when a call comes in over
// the internet. Off until the Worker has the APNs secrets: APNS_KEY (the .p8 file's contents),
// APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC (the app's bundle ID).

const enc = new TextEncoder();

function b64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function configured(env) {
  return Boolean(env && env.APNS_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC);
}

async function importKey(pem) {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/// The provider token APNs wants: an ES256 JWT, good for up to an hour.
export async function providerToken(env, nowSeconds) {
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: nowSeconds })));
  const input = `${header}.${claims}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await importKey(env.APNS_KEY), enc.encode(input));
  return `${input}.${b64url(sig)}`;
}

/// What a push says. The relay cannot read the message, so it cannot say who called; the app
/// works out who and when to alert once it is awake. `call` is visible; `quiet` only wakes the app.
export function payload(kind, sealed) {
  if (kind === "call") {
    return {
      // Still sealed: only a phone in the group can open it, to name the caller.
      ...(typeof sealed === "string" && sealed.length <= 512 ? { sealed } : {}),
      aps: {
        alert: { title: "Help&I", body: "A call for help in your group. Open Help&I to see who." },
        sound: "default",
        "interruption-level": "time-sensitive",
        "content-available": 1,
        "mutable-content": 1,
      },
    };
  }
  return { aps: { "content-available": 1 } };
}

/// Sends one push. Returns the HTTP status, or 0 if it could not be sent.
export async function push(env, token, kind, { fetchImpl = fetch, now = Date.now(), sealed } = {}) {
  if (!configured(env) || !/^[0-9a-f]{64,200}$/i.test(token.token)) return 0;
  const host = token.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  // A watch is only ever woken quietly: it alerts its wearer itself, and only when their phone is
  // out of reach, so one call never shows twice.
  const watch = token.device === "watch";
  const quiet = kind !== "call" || watch;
  try {
    const res = await fetchImpl(`https://${host}/3/device/${token.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await providerToken(env, Math.floor(now / 1000))}`,
        "apns-topic": watch ? env.APNS_TOPIC + ".watchkitapp" : env.APNS_TOPIC,
        "apns-push-type": quiet ? "background" : "alert",
        "apns-priority": quiet ? "5" : "10",
        "apns-expiration": String(Math.floor(now / 1000) + 3600),
      },
      body: JSON.stringify(payload(watch ? "quiet" : kind, sealed)),
    });
    return res.status;
  } catch {
    return 0;
  }
}
