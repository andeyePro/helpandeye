// Logic for one group's relay, kept free of Cloudflare APIs so it can be tested with node --test.
//
// Every request is signed by a member's phone with its Ed25519 key. The relay holds only public
// keys and ciphertext: messages are sealed on the phones with the group key, which the relay never
// has. A coordinator registers the group and sends the member list; a removed phone is refused at
// once.

export const MAX_SKEW_MS = 5 * 60 * 1000;
export const KEEP_MS = 7 * 24 * 3600 * 1000;
export const MAX_KEPT = 2000;
// Most sealed frames are under 300 characters; the largest, a group's settings with several
// profiles, is under 3,000. Anything far bigger is not from the app.
export const MAX_BODY = 4096;
// Cloudflare's free plan allows 100,000 Worker requests and 100,000 Durable Object requests a
// day. Each relay request uses two Durable Object requests (its group and the meter), so the
// Durable Object allowance runs out first, at 50,000 relay requests. Coordinators are warned well
// before that.
export const FREE_DAILY_REQUESTS = 50_000;
export const WARN_FRACTION = 0.8;
// A phone posts a call, its follow-ups and acknowledgements; nothing real needs more than this.
export const MAX_POSTS_PER_MINUTE = 20;
export const MAX_WAKES_PER_MINUTE = 2;
export const MAX_MEMBERS = 256;
export const MAX_REMOVED = 1024;

/// An Ed25519 public key: 32 bytes of base64.
export function isKey(k) {
  // Re-encoding rejects aliases whose unused final bits differ, which decode to the same bytes.
  return typeof k === "string" && /^[A-Za-z0-9+/]{43}=$/.test(k) && b64(unb64(k)) === k;
}

/// A group's ID is 8 random bytes and the first 8 bytes of SHA-256 over a label, those bytes and
/// the first coordinator's key, so the relay can tell who may register it.
export async function ownsGroup(groupId, primary) {
  if (!(groupId instanceof Uint8Array) || groupId.length !== 16 || !isKey(primary)) return false;
  const label = enc.encode("HELPA-GROUP-1");
  const input = new Uint8Array([...label, ...groupId.slice(0, 8), ...unb64(primary)]);
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  return hash.slice(0, 8).every((b, i) => b === groupId[8 + i]);
}

const enc = new TextEncoder();

export function b64(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

export function unb64(s) {
  if (typeof s !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) throw new RelayError(400, "bad base64");
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  } catch {
    throw new RelayError(400, "bad base64");
  }
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
  return enc.encode(`HELPA-RELAY-1\n${method}\n${pathAndQuery}\n${timestamp}\n${hash}`);
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

  /// Membership on the relay. The group's first coordinator owns it: the group's ID is made from
  /// their key (see `ownsGroup`), so only a list naming them as `primary` can register the group,
  /// and only the owner can send it. After that a list from any coordinator adds people, as members;
  /// only the owner sets roles and removes people, and nobody removed is ever listed again. When the
  /// owner removes a coordinator, people only that coordinator added, and the owner does not list,
  /// go too, and only the owner listing them again brings them back.
  async setMembers(signer, list, groupId = null) {
    if (!list || typeof list !== "object" || !Array.isArray(list.members) || !Number.isInteger(list.generation) || list.generation < 0) throw new RelayError(400, "bad member list");
    const named = list.removed ?? [];
    if (!Array.isArray(named)) throw new RelayError(400, "bad removed list");
    for (const k of named) if (!isKey(k)) throw new RelayError(400, "bad removed key");
    for (const m of list.members) {
      if (!m || typeof m !== "object" || !isKey(m.key) || !["coordinator", "member"].includes(m.role)) throw new RelayError(400, "bad member");
    }
    if (list.members.length > MAX_MEMBERS || named.length > MAX_REMOVED) throw new RelayError(413, "too many members");
    if (new Set(list.members.map((m) => m.key)).size !== list.members.length) throw new RelayError(400, "a key listed twice");
    const current = await this.members();
    let owner = await this.storage.get("owner");
    if (!current) {
      if (!list.members.some((m) => m.key === list.primary && m.role === "coordinator")) throw new RelayError(400, "the list must name its first coordinator");
      if (groupId && !(await ownsGroup(groupId, list.primary))) throw new RelayError(403, "not this group's first coordinator");
      if (signer !== list.primary) throw new RelayError(425, "the group's first coordinator registers it first");
      owner = list.primary;
    } else {
      if (!current.members.some((m) => m.key === signer && m.role === "coordinator")) throw new RelayError(403, "only a coordinator can change members");
      if (list.primary !== undefined && list.primary !== owner) throw new RelayError(409, "this group has another first coordinator");
    }
    const removed = new Set((await this.storage.get("removed")) ?? []);
    if (signer !== owner && named.some((k) => !removed.has(k))) throw new RelayError(403, "only the first coordinator removes people");
    if (named.includes(owner)) throw new RelayError(409, "the first coordinator cannot be removed");
    // Roles from the owner's newest list only, so a delayed older one cannot undo a change.
    const ownerGeneration = (await this.storage.get("ownerGeneration")) ?? -1;
    const ownerFresh = signer === owner && list.generation >= ownerGeneration;
    const roles = new Map((current?.members ?? []).map((m) => [m.key, m.role]));
    const addedBy = new Map((await this.storage.get("addedBy")) ?? []);
    const dropped = new Set((await this.storage.get("dropped")) ?? []);
    if (ownerFresh) for (const m of list.members) dropped.delete(m.key);
    for (const m of list.members) {
      if (removed.has(m.key) || dropped.has(m.key)) continue;
      if (!roles.has(m.key)) {
        const asListed = ownerFresh || (!current && m.key === owner);
        roles.set(m.key, asListed ? m.role : "member");
        addedBy.set(m.key, signer);
      } else if (ownerFresh) {
        roles.set(m.key, m.role);
      }
    }
    if (signer === owner) {
      const listed = new Set(list.members.map((m) => m.key));
      for (const k of named) {
        if (removed.has(k)) continue;
        removed.add(k);
        if (current?.members.some((m) => m.key === k && m.role === "coordinator")) {
          for (const [key, by] of addedBy) if (by === k && !listed.has(key) && roles.delete(key)) dropped.add(key);
        }
      }
    }
    for (const k of removed) { roles.delete(k); addedBy.delete(k); dropped.delete(k); }
    if (roles.size > MAX_MEMBERS || removed.size > MAX_REMOVED || dropped.size > MAX_REMOVED) throw new RelayError(413, "too many members");
    const members = [...roles].map(([key, role]) => ({ key, role }));
    await this.storage.put("owner", owner);
    await this.storage.put("removed", [...removed]);
    await this.storage.put("dropped", [...dropped]);
    await this.storage.put("addedBy", [...addedBy].filter(([k]) => roles.has(k)));
    if (ownerFresh) await this.storage.put("ownerGeneration", list.generation);
    await this.storage.put("members", { generation: Math.max(current?.generation ?? 0, list.generation), members });
    // Push tokens of anyone no longer listed are deleted, not just ignored.
    const tokenKeys = [...(await this.storage.list({ prefix: "p:" })).keys(), ...(await this.storage.list({ prefix: "w:" })).keys()];
    const gone = tokenKeys.filter((k) => !roles.has(k.slice(2)));
    if (gone.length) await this.storage.delete(gone);
  }

  async requireMember(key) {
    const current = await this.members();
    if (!current || !current.members.some((m) => m.key === key)) throw new RelayError(403, "not a member of this group");
  }

  /// A member's phone, or their watch acting for it, tells the relay where to push to wake it.
  /// One of each per member key, dropped with the member.
  async setPushToken(member, body) {
    await this.requireMember(member);
    if (!body || typeof body.token !== "string" || !/^[0-9a-f]{64,200}$/i.test(body.token)) throw new RelayError(400, "bad push token");
    const watch = body.device === "watch";
    const token = { token: body.token.toLowerCase(), sandbox: Boolean(body.sandbox) };
    await this.storage.put((watch ? "w:" : "p:") + member, watch ? { ...token, device: "watch" } : token);
  }

  /// Forgets push tokens APNs says are dead, so they are not tried on every call.
  async dropPushTokens(dead) {
    const all = [...(await this.storage.list({ prefix: "p:" })).entries(), ...(await this.storage.list({ prefix: "w:" })).entries()];
    const keys = all.filter(([, t]) => dead.includes(t.token)).map(([k]) => k);
    if (keys.length) await this.storage.delete(keys);
  }

  /// Push tokens of every current member except the sender, phones and watches.
  async pushTargets(sender) {
    const current = await this.members();
    if (!current) return [];
    const members = new Set(current.members.map((m) => m.key));
    const tokens = [...(await this.storage.list({ prefix: "p:" })).entries(), ...(await this.storage.list({ prefix: "w:" })).entries()];
    return tokens.filter(([k]) => k.slice(2) !== sender && members.has(k.slice(2))).map(([, t]) => t);
  }

  /// Each message is its own storage key, so no single value grows with the log.
  static key(seq) {
    return "m:" + String(seq).padStart(12, "0");
  }

  /// Counts a member's posts (and pushes asked for) in the current minute, refusing past the limit,
  /// so one phone cannot use up the group's free allowance or flood everyone with pushes.
  async limit(sender, wake) {
    await this.requireMember(sender);
    const minute = Math.floor(this.now() / 60000);
    const key = "r:" + sender;
    const cur = (await this.storage.get(key)) ?? { minute, posts: 0, wakes: 0 };
    const c = cur.minute === minute ? cur : { minute, posts: 0, wakes: 0 };
    c.posts += 1;
    if (wake) c.wakes += 1;
    await this.storage.put(key, c);
    if (c.posts > MAX_POSTS_PER_MINUTE) throw new RelayError(429, "too many messages");
    return !wake || c.wakes <= MAX_WAKES_PER_MINUTE;
  }

  /// A random name for this group's message log, made once. If the relay's storage is ever reset,
  /// the name changes, so a phone knows its place in the old log means nothing.
  async epoch() {
    let e = await this.storage.get("epoch");
    if (!e) { e = b64(crypto.getRandomValues(new Uint8Array(9))); await this.storage.put("epoch", e); }
    return e;
  }

  async post(sender, sealed) {
    await this.requireMember(sender);
    if (typeof sealed !== "string" || sealed.length === 0 || sealed.length > MAX_BODY) throw new RelayError(400, "bad message");
    unb64(sealed);
    const seq = ((await this.storage.get("seq")) ?? 0) + 1;
    await this.storage.put(GroupRelay.key(seq), { seq, at: this.now(), sealed });
    await this.storage.put("seq", seq);
    await this.prune(seq);
    return seq;
  }

  /// Messages after `after`, and the latest sequence number, so a phone can tell when its place
  /// is ahead of the relay (a new group, or a reset relay) and start again from the latest.
  async since(reader, after) {
    await this.requireMember(reader);
    const latest = (await this.storage.get("seq")) ?? 0;
    const epoch = await this.epoch();
    // A negative `after` asks for the last that many messages, for a phone's first read.
    const asked = Number(after) || 0;
    const from = asked < 0 ? Math.max(latest + asked, 0) : asked;
    const cutoff = this.now() - KEEP_MS;
    const page = [...(await this.storage.list({ prefix: "m:", start: GroupRelay.key(from + 1), limit: 200 })).values()];
    // `next` is the last sequence scanned, kept or expired, so a reader never stalls on old ones.
    const next = page.length ? page[page.length - 1].seq : Math.max(from, latest);
    return { latest, next, epoch, messages: page.filter((m) => m.at >= cutoff) };
  }

  async prune(latest) {
    const cutoff = this.now() - KEEP_MS;
    const old = await this.storage.list({ prefix: "m:", limit: 50 });
    const doomed = [...old.entries()].filter(([, m]) => m.at < cutoff || m.seq <= latest - MAX_KEPT).map(([k]) => k);
    if (doomed.length) await this.storage.delete(doomed);
  }
}

/// Counts requests across all groups for the day, so coordinators hear before the free allowance
/// runs out (app spec, "The relay's daily allowance").
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
