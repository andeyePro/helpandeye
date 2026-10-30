import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { issuePass, keygen, publicKey } from "../pass.mjs";
import { checkPass, fromB64url, issue, parse, toB64url } from "../src/pass.js";

const GROUP = "AbCdEfGhIjKlMnOpQrStUv";

async function issuer() {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  return { pair, pub: toB64url(await crypto.subtle.exportKey("raw", pair.publicKey)) };
}

test("a pass names its group and expiry and checks with the issuer's key", async () => {
  const { pair, pub } = await issuer();
  const expiry = Math.floor(Date.now() / 1000) + 86400;
  const pass = await issue(GROUP, expiry, pair.privateKey);
  assert.match(pass, /^1\.[A-Za-z0-9_-]+\.\d+\.[A-Za-z0-9_-]{86}$/);
  assert.deepEqual([parse(pass).groupId, parse(pass).expiry], [GROUP, expiry * 1000]);
  await checkPass(pass, GROUP, pub);
  await checkPass(pass, GROUP, pub, expiry * 1000 - 1);
});

test("an expired pass, another group's, a tampered one, another issuer's and none are refused with 402", async () => {
  const { pair, pub } = await issuer();
  const other = await issuer();
  const expiry = Math.floor(Date.now() / 1000) + 86400;
  const pass = await issue(GROUP, expiry, pair.privateKey);
  const refused = async (p, groupId, key, now, message) => {
    await assert.rejects(checkPass(p, groupId, key, now), (e) => e.status === 402 && e.message === message);
  };
  await refused(pass, GROUP, pub, expiry * 1000, "pass expired");
  await refused(pass, GROUP.replace("A", "B"), pub, undefined, "pass is for another group");
  const tampered = pass.slice(0, -40) + (pass[pass.length - 40] === "A" ? "B" : "A") + pass.slice(-39);
  await refused(tampered, GROUP, pub, undefined, "bad pass");
  await refused(pass.replace(`.${expiry}.`, `.${expiry + 1}.`), GROUP, pub, undefined, "bad pass");
  await refused(pass, GROUP, other.pub, undefined, "bad pass");
  await refused(await issue(GROUP, expiry, other.pair.privateKey), GROUP, pub, undefined, "bad pass");
  await refused(null, GROUP, pub, undefined, "pass required");
  await refused("", GROUP, pub, undefined, "pass required");
  await refused("not a pass", GROUP, pub, undefined, "bad pass");
  await refused(`2.${pass.slice(2)}`, GROUP, pub, undefined, "bad pass");
});

test("a pass checked once is still checked against the clock, the group and a changed issuer key", async () => {
  const { pair, pub } = await issuer();
  const expiry = Math.floor(Date.now() / 1000) + 60;
  const pass = await issue(GROUP, expiry, pair.privateKey);
  await checkPass(pass, GROUP, pub);
  await assert.rejects(checkPass(pass, GROUP, pub, expiry * 1000 + 1), (e) => e.message === "pass expired");
  await assert.rejects(checkPass(pass, GROUP.replace("A", "B"), pub), (e) => e.message === "pass is for another group");
  await assert.rejects(checkPass(pass, GROUP, (await issuer()).pub), (e) => e.message === "bad pass");
  await checkPass(pass, GROUP, pub);
});

test("the issuer tool makes a key pair once and its passes check with the public key it prints", async () => {
  const file = join(await mkdtemp(join(tmpdir(), "helpa-pass-")), "issuer.json");
  const pub = await keygen(file);
  assert.equal(await publicKey(file), pub);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  await assert.rejects(keygen(file), "the key pair is made once");
  assert.equal(await publicKey(file), pub, "a second keygen changed nothing");
  assert.equal(JSON.parse(await readFile(file, "utf8")).public, pub);
  const now = Date.UTC(2026, 10, 1);
  const pass = await issuePass(file, GROUP, 30, now);
  assert.equal(parse(pass).expiry, now + 30 * 86400 * 1000);
  await checkPass(pass, GROUP, pub, now + 29 * 86400 * 1000);
  await assert.rejects(checkPass(pass, GROUP, pub, now + 30 * 86400 * 1000), (e) => e.message === "pass expired");
  await assert.rejects(issuePass(file, GROUP, 0), /days/);
  await assert.rejects(issuePass(file, "not a group id!", 30), /group ID/);
  assert.deepEqual(fromB64url(toB64url(new Uint8Array([251, 255, 254]))), new Uint8Array([251, 255, 254]));
});
