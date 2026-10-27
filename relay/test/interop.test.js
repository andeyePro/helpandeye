import assert from "node:assert/strict";
import { test } from "node:test";
import { signingInput, verify } from "../src/relay.js";

// Signed by the app's RelayProtocol (app/helpandeyeCore RelayVectorTests).
const vector = {"body":"{\"sealed\":\"AAEC\"}","key":"Tuo9IbVjC7jhUXPQTWqdfCb9UoQ1ix+AqSQn03WOt0Y=","path":"\/g\/ABCDEFGHIJKLMNOP\/messages","signature":"kFxph\/gD7m7S1wcmX+NeMCTx9elGZf+7J5IFz86vyT48xwlJgX\/a15A9qxYbkLqMIHspjQUtsy7WHKQzA6+2AQ==","timestamp":"1793067444921"};

test("the relay verifies a request signed by the app", async () => {
  const input = await signingInput("POST", vector.path, vector.timestamp, vector.body);
  assert.equal(await verify(vector.key, vector.signature, input), true);
  assert.equal(await verify(vector.key, vector.signature, await signingInput("POST", vector.path, vector.timestamp, vector.body + " ")), false);
});
