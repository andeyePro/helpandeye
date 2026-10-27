// Logic for one group's relay, kept free of Cloudflare APIs so it can be tested with node --test.
//
// Every request is signed by a member's phone with its Ed25519 key. The relay holds only public
// keys and ciphertext: messages are sealed on the phones with the group key, which the relay never
// has. A coordinator registers the group and sends the member list; a removed phone is refused at
// once.

export const MAX_SKEW_MS = 5 * 60 * 1000;
export const KEEP_MS = 7 * 24 * 3600 * 1000;
export const MAX_KEPT = 2000;
export const MAX_BODY = 4096;
// Cloudflare's free plan allows 100,000 Worker requests a day. Coordinators are warned well before.
export const FREE_DAILY_REQUESTS = 100_000;
export const WARN_FRACTION = 0.8;

const enc = new TextEncoder();

export function b64(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

export function unb64(s) {
  if (typeof s !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) throw new RelayError(400, "bad base64");
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

export class RelayError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

/// What a phone signs: method, path with query, its timestamp and the body's hash. A captured
/// request cannot be replayed after MAX_SKEW_MS or against another path.
export async function signingInput(method, pathAndQuery, timestamp, body) {
  const hash = b64(await sha256(enc.encode(body)));
  return enc.encode(`HELPANDI-RELAY-1\n${method}\n${pathAndQuery}\n${timestamp}\n${hash}`);
}

export async function verify(publicKeyB64, signatureB64, input) {
  try {
    const key = await crypto.subtle.importKey("raw", unb64(publicKeyB64), { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, unb64(signatureB64), input);
  } catch {
    return false;
  }
}

/// One group's state over a small key-value store with get/put (a Durable Object's storage, or a
/// Map in tests).
export class GroupRelay {
  constructor(storage, now = () => Date.now()) {
    this.storage = storage;
    this.now = now;
  }

  async authenticate({ method, path, key, timestamp, signature, body }) {
    const ts = Number(timestamp);
    if (!Number.isFinite(ts) || Math.abs(this.now() - ts) > MAX_SKEW_MS) throw new RelayError(401, "stale or missing timestamp");
    if (!(await verify(key, signature, await signingInput(method, path, timestamp, body)))) throw new RelayError(401, "bad signature");
    return key;
  }

  async members() {
    return (await this.storage.get("members")) ?? null;
  }

  /// The first coordinator to register a group owns it. Later member lists must come from a key
  /// that is a coordinator in the current list, and must not go back a generation.
  async setMembers(signer, list) {
    if (!list || !Array.isArray(list.members) || !Number.isInteger(list.generation)) throw new RelayError(400, "bad member list");
    for (const m of list.members) {
      if (typeof m.key !== "string" || !["coordinator", "member"].includes(m.role)) throw new RelayError(400, "bad member");
    }
    const current = await this.members();
    if (current) {
      if (!current.members.some((m) => m.key === signer && m.role === "coordinator")) throw new RelayError(403, "only a coordinator can change members");
      if (list.generation < current.generation) throw new RelayError(409, "older member list");
    }
    if (!list.members.some((m) => m.key === signer && m.role === "coordinator")) throw new RelayError(400, "the signer must stay a coordinator");
    await this.storage.put("members", { generation: list.generation, members: list.members.map(({ key, role }) => ({ key, role })) });
  }

  async requireMember(key) {
    const current = await this.members();
    if (!current || !current.members.some((m) => m.key === key)) throw new RelayError(403, "not a member of this group");
  }

  async post(sender, sealed) {
    await this.requireMember(sender);
    if (typeof sealed !== "string" || sealed.length === 0 || sealed.length > MAX_BODY) throw new RelayError(400, "bad message");
    unb64(sealed);
    const log = await this.pruned();
    const seq = ((await this.storage.get("seq")) ?? 0) + 1;
    log.push({ seq, at: this.now(), sealed });
    await this.storage.put("seq", seq);
    await this.storage.put("log", log);
    return seq;
  }

  async since(reader, after) {
    await this.requireMember(reader);
    const from = Number(after) || 0;
    return (await this.pruned()).filter((m) => m.seq > from);
  }

  async pruned() {
    const cutoff = this.now() - KEEP_MS;
    return ((await this.storage.get("log")) ?? []).filter((m) => m.at >= cutoff).slice(-MAX_KEPT);
  }
}

/// Counts requests across all groups for the day, so coordinators hear before the free allowance
/// runs out (app spec, "Tiers and cost").
export class Meter {
  constructor(storage, now = () => Date.now()) {
    this.storage = storage;
    this.now = now;
  }

  day() {
    return new Date(this.now()).toISOString().slice(0, 10);
  }

  async add(n) {
    const day = this.day();
    const cur = (await this.storage.get("count")) ?? { day, n: 0 };
    const next = cur.day === day ? { day, n: cur.n + n } : { day, n };
    await this.storage.put("count", next);
    return next.n;
  }

  async status() {
    const cur = (await this.storage.get("count")) ?? { day: this.day(), n: 0 };
    const used = cur.day === this.day() ? cur.n : 0;
    return { used, limit: FREE_DAILY_REQUESTS, low: used >= FREE_DAILY_REQUESTS * WARN_FRACTION };
  }
}
