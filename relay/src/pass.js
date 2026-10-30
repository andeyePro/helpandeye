// A relay pass: Help&I's say-so that a group may use its relay until a date. Issued by
// relay/pass.mjs with Help&I's issuer key, pasted into the group's settings by a coordinator and
// sent by every member's phone with each request (X-HelpA-Pass). The relay checks it with the
// issuer's public key alone, so a group without one is turned away before its Durable Object is
// called, as a badly signed request is. How a group came by its pass is no concern of the relay.
//
// Form: 1.<group ID>.<expiry>.<signature>: the group ID as it appears in the path, the expiry in
// seconds since 1970, and an Ed25519 signature in URL-safe base64 over
// "HELPA-PASS-1\n<group ID>\n<expiry>".

import { RelayError } from "./relay.js";

export const PASS_HEADER = "X-HelpA-Pass";
const FORM = /^1\.([A-Za-z0-9_-]{16,64})\.(\d{1,12})\.([A-Za-z0-9_-]{86})$/;
// Passes already checked, so a group's members polling do not cost a signature check each. A
// cached pass is still checked against the clock and the group.
const checked = new Set();
const CHECKED_MAX = 1000;
let issuer = { b64: null, key: null };

export function signingInput(groupId, expiry) {
  return new TextEncoder().encode(`HELPA-PASS-1\n${groupId}\n${expiry}`);
}

/// The group and expiry (milliseconds since 1970) a pass names, or null if it is not one.
export function parse(pass) {
  const m = typeof pass === "string" ? pass.match(FORM) : null;
  return m ? { groupId: m[1], expiry: Number(m[2]) * 1000, signature: m[3] } : null;
}

export function requiresPass(env) {
  return ["1", "true", "on", "yes"].includes(String(env.REQUIRE_PASS ?? "").toLowerCase());
}

/// Refuses, with 402, a request for `groupId` that does not carry a pass for it, signed by the
/// issuer whose public key is `issuerKeyB64`, and not yet expired at `now`.
export async function checkPass(pass, groupId, issuerKeyB64, now = Date.now()) {
  if (!pass) throw new RelayError(402, "pass required");
  const p = parse(pass);
  if (!p) throw new RelayError(402, "bad pass");
  if (p.groupId !== groupId) throw new RelayError(402, "pass is for another group");
  if (p.expiry <= now) throw new RelayError(402, "pass expired");
  if (!checked.has(pass)) {
    if (!(await verify(issuerKeyB64, p))) throw new RelayError(402, "bad pass");
    if (checked.size >= CHECKED_MAX) checked.clear();
    checked.add(pass);
  }
}

async function verify(issuerKeyB64, p) {
  try {
    if (issuer.b64 !== issuerKeyB64) {
      issuer = { b64: issuerKeyB64, key: await crypto.subtle.importKey("raw", fromB64url(issuerKeyB64), { name: "Ed25519" }, false, ["verify"]) };
    }
    return await crypto.subtle.verify({ name: "Ed25519" }, issuer.key, fromB64url(p.signature), signingInput(p.groupId, p.expiry / 1000));
  } catch {
    return false;
  }
}

/// A pass for `groupId` until `expiry` (seconds since 1970), signed with the issuer's private key.
export async function issue(groupId, expiry, privateKey) {
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(groupId)) throw new Error("not a group ID");
  if (!Number.isInteger(expiry) || expiry <= 0) throw new Error("not an expiry");
  const sig = await crypto.subtle.sign({ name: "Ed25519" }, privateKey, signingInput(groupId, expiry));
  return `1.${groupId}.${expiry}.${toB64url(sig)}`;
}

export function toB64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64url(s) {
  const std = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(std + "=".repeat((4 - (std.length % 4)) % 4)), (c) => c.charCodeAt(0));
}
