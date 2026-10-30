#!/usr/bin/env node
// Issues relay passes (src/pass.js). Run on a machine you trust, never on the relay:
//
//   node pass.mjs keygen               makes the issuer key pair once and prints the public key
//   node pass.mjs public               prints the public key, for the Worker's ISSUER_KEY var
//   node pass.mjs issue <group ID> <days>   prints a pass for the group, good for that many days
//   node pass.mjs show <pass>          prints the group and expiry a pass names
//
// The key pair lives in one file outside any repository, ~/.helpandeye/relay-issuer.json unless
// HELPA_ISSUER_KEY names another, readable by its owner only. Whoever holds it can issue passes,
// so keep it as you would a password. The group ID is shown in the app under Group, Internet
// route.

import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { fromB64url, issue, parse, toB64url } from "./src/pass.js";

export const DEFAULT_KEY_FILE = join(homedir(), ".helpandeye", "relay-issuer.json");

/// Makes the issuer key pair and saves it to `file`, which must not exist. Returns the public key.
export async function keygen(file) {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const record = {
    comment: "Help&I relay issuer key. Whoever holds this file can issue relay passes.",
    public: toB64url(await crypto.subtle.exportKey("raw", pair.publicKey)),
    private: toB64url(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
  };
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  await writeFile(file, JSON.stringify(record, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  await chmod(file, 0o600);
  return record.public;
}

export async function publicKey(file) {
  return (await load(file)).public;
}

/// A pass for `groupId` that expires `days` from `now`.
export async function issuePass(file, groupId, days, now = Date.now()) {
  if (!Number.isInteger(days) || days < 1 || days > 3660) throw new Error("days must be a whole number from 1 to 3660");
  const record = await load(file);
  const key = await crypto.subtle.importKey("pkcs8", fromB64url(record.private), { name: "Ed25519" }, false, ["sign"]);
  return issue(groupId, Math.floor(now / 1000) + days * 86400, key);
}

async function load(file) {
  const record = JSON.parse(await readFile(file, "utf8"));
  if (typeof record.public !== "string" || typeof record.private !== "string") throw new Error(`${file} is not an issuer key file`);
  return record;
}

async function main(argv) {
  const file = process.env.HELPA_ISSUER_KEY || DEFAULT_KEY_FILE;
  const [command, ...args] = argv;
  switch (command) {
    case "keygen":
      console.log(`Issuer key saved to ${file}. Public key, for the Worker's ISSUER_KEY var:\n${await keygen(file)}`);
      return;
    case "public":
      console.log(await publicKey(file));
      return;
    case "issue": {
      if (args.length !== 2) throw new Error("usage: node pass.mjs issue <group ID> <days>");
      const pass = await issuePass(file, args[0], Number(args[1]));
      console.log(`Pass for group ${args[0]}, until ${new Date(parse(pass).expiry).toISOString()}:\n${pass}`);
      return;
    }
    case "show": {
      const p = parse(args[0]);
      if (!p) throw new Error("not a pass");
      console.log(`Group ${p.groupId}, until ${new Date(p.expiry).toISOString()}`);
      return;
    }
    default:
      throw new Error("usage: node pass.mjs keygen | public | issue <group ID> <days> | show <pass>");
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((e) => { console.error(e.message); process.exit(1); });
}
