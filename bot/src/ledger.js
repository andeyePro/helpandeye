// The counts the bot keeps: free answers a day by salted address hash, questions in flight for
// each visitor, rate limits, and what each user and everyone together have cost in the last six
// hours. Storage is Durable Object storage (or anything with the same get, put, delete and
// list); `now` is a clock, so tests can set it.

export const DAY_MS = 24 * 60 * 60 * 1000;
export const WINDOW_MS = 6 * 60 * 60 * 1000;
// Spend is kept in ten-minute buckets, so a window of six hours is at most 36 keys to sum.
export const BUCKET_MS = 10 * 60 * 1000;
export const EVERYONE = "*";
// Questions one visitor may have unanswered at once, and how long one counts as unanswered if
// the Worker that asked it never reports back.
export const IN_FLIGHT = 2;
export const IN_FLIGHT_MS = 60 * 1000;

export class Ledger {
  constructor(storage, now = Date.now) {
    this.storage = storage;
    this.now = now;
  }

  /// Takes one of `limit` free answers for `hash` today. The record starts when the first is
  /// taken and is forgotten a day later.
  async take(hash, limit) {
    const key = `free:${hash}`;
    const now = this.now();
    let r = await this.storage.get(key);
    if (!r || now - r.at >= DAY_MS) r = { count: 0, at: now };
    if (r.count >= limit) return { allowed: false, remaining: 0 };
    r.count += 1;
    await this.storage.put(key, r);
    return { allowed: true, remaining: limit - r.count };
  }

  /// Gives back an answer that was taken but never given.
  async giveBack(hash) {
    const key = `free:${hash}`;
    const r = await this.storage.get(key);
    if (r && r.count > 0) await this.storage.put(key, { ...r, count: r.count - 1 });
  }

  async remaining(hash, limit) {
    const r = await this.storage.get(`free:${hash}`);
    if (!r || this.now() - r.at >= DAY_MS) return limit;
    return Math.max(0, limit - r.count);
  }

  /// `who` is about to ask a question. Refused while `who` already has IN_FLIGHT unanswered, or
  /// (with a `hash`) when today's free answers are gone. Returns the question's start time,
  /// which `finish` takes.
  async start(who, hash, limit) {
    const now = this.now();
    const key = `inflight:${who}`;
    const open = ((await this.storage.get(key)) ?? []).filter((t) => now - t < IN_FLIGHT_MS);
    if (open.length >= IN_FLIGHT) return { allowed: false, busy: true, remaining: null };
    const taken = hash === null ? { allowed: true, remaining: null } : await this.take(hash, limit);
    if (!taken.allowed) return { allowed: false, busy: false, remaining: 0 };
    await this.storage.put(key, [...open, now]);
    return { allowed: true, remaining: taken.remaining, startedAt: now };
  }

  /// The question started at `startedAt` is over; an answer that never came is given back.
  async finish(who, hash, startedAt, answered) {
    const key = `inflight:${who}`;
    const open = ((await this.storage.get(key)) ?? []).filter((t) => t !== startedAt);
    if (open.length) await this.storage.put(key, open); else await this.storage.delete(key);
    if (!answered && hash !== null) await this.giveBack(hash);
  }

  /// Counts one more `what` against `max` in a window of `windowMs`, and says whether it fits.
  async allow(what, max, windowMs) {
    const now = this.now();
    const key = `rate:${what}`;
    let r = await this.storage.get(key);
    if (!r || now >= r.until) r = { count: 0, until: now + windowMs };
    if (r.count >= max) return false;
    r.count += 1;
    await this.storage.put(key, r);
    return true;
  }

  /// Records that `who` cost `usd`, and says which alerts to send: everyone together past
  /// `thresholds.everyone` in the window, or this user past `thresholds.user`. Each is sent at
  /// most once a window.
  async spend(who, usd, thresholds) {
    const now = this.now();
    const bucket = Math.floor(now / BUCKET_MS) * BUCKET_MS;
    const alerts = [];
    for (const [id, threshold] of [[EVERYONE, thresholds.everyone], [who, thresholds.user]]) {
      const key = `spend:${id}:${bucket}`;
      await this.storage.put(key, ((await this.storage.get(key)) ?? 0) + usd);
      const total = await this.total(id);
      if (total < threshold) continue;
      const last = await this.storage.get(`alerted:${id}`);
      if (typeof last === "number" && now - last < WINDOW_MS) continue;
      await this.storage.put(`alerted:${id}`, now);
      alerts.push({ who: id, usd: total, threshold });
    }
    return alerts;
  }

  /// What `who` has cost in the last window: every bucket that overlaps it, so the figure can
  /// be up to ten minutes generous, never short.
  async total(who) {
    const since = this.now() - WINDOW_MS;
    let sum = 0;
    for (const [key, usd] of await this.storage.list({ prefix: `spend:${who}:` })) {
      if (Number(key.slice(key.lastIndexOf(":") + 1)) > since - BUCKET_MS) sum += usd;
    }
    return sum;
  }

  /// Forgets address hashes a day old, spend and alerts a window old, and stale in-flight and
  /// rate records. Returns when to sweep next, or null when there is nothing left.
  async sweep() {
    const now = this.now();
    let next = null;
    const due = (t) => { if (next === null || t < next) next = t; };
    const gone = [];
    for (const [key, r] of await this.storage.list({ prefix: "free:" })) {
      if (now - r.at >= DAY_MS) gone.push(key); else due(r.at + DAY_MS);
    }
    for (const [key] of await this.storage.list({ prefix: "spend:" })) {
      const at = Number(key.slice(key.lastIndexOf(":") + 1));
      if (now - at >= WINDOW_MS + BUCKET_MS) gone.push(key); else due(at + WINDOW_MS + BUCKET_MS);
    }
    for (const [key, at] of await this.storage.list({ prefix: "alerted:" })) {
      if (now - at >= WINDOW_MS) gone.push(key); else due(at + WINDOW_MS);
    }
    for (const [key, open] of await this.storage.list({ prefix: "inflight:" })) {
      const latest = Math.max(...open);
      if (now - latest >= IN_FLIGHT_MS) gone.push(key); else due(latest + IN_FLIGHT_MS);
    }
    for (const [key, r] of await this.storage.list({ prefix: "rate:" })) {
      if (now >= r.until) gone.push(key); else due(r.until);
    }
    for (let i = 0; i < gone.length; i += 128) await this.storage.delete(gone.slice(i, i + 128));
    return next;
  }
}
