// Behaves like Durable Object storage for the calls the ledger makes, including its 128-key limit.
export class MapStorage {
  constructor() { this.m = new Map(); this.alarm = null; this.puts = 0; }
  async get(k) { return structuredClone(this.m.get(k)); }
  async put(k, v) {
    const entries = typeof k === "string" ? { [k]: v } : k;
    if (Object.keys(entries).length > 128) throw new RangeError("more than 128 keys");
    this.puts += 1;
    for (const [key, value] of Object.entries(entries)) this.m.set(key, structuredClone(value));
  }
  async delete(keys) {
    if ([].concat(keys).length > 128) throw new RangeError("more than 128 keys");
    for (const k of [].concat(keys)) this.m.delete(k);
  }
  async list({ prefix = "", start = "", limit = Infinity } = {}) {
    const keys = [...this.m.keys()].filter((k) => k.startsWith(prefix) && k >= start).sort().slice(0, limit);
    return new Map(keys.map((k) => [k, structuredClone(this.m.get(k))]));
  }
  async deleteAll() { this.m.clear(); }
  async getAlarm() { return this.alarm; }
  async setAlarm(t) { this.alarm = t; }
}
