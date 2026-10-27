import assert from "node:assert/strict";
import { test } from "node:test";
import { signingInput, verify } from "../src/relay.js";

// Signed by the app's RelayProtocol (app/helpandeyeCore RelayVectorTests).
const vector = {"body":"{\"sealed\":\"AAEC\"}","key":"TRAgti\/0OS4bCrpTWS8dqNdzBvciwckp2dV+4c92gS0=","path":"\/g\/ABCDEFGHIJKLMNOP\/messages","signature":"8ub9QJKuYvOjBu9pGwze\/IAO5MvmqE7dW0zWpS0cJiwjcGiKbc0FlODAWBkkb9vXkunX2\/DD6uLTw3BOdGeKDA==","timestamp":"1793105186783"};

test("the relay verifies a request signed by the app", async () => {
  const input = await signingInput("POST", vector.path, vector.timestamp, vector.body);
  assert.equal(await verify(vector.key, vector.signature, input), true);
  assert.equal(await verify(vector.key, vector.signature, await signingInput("POST", vector.path, vector.timestamp, vector.body + " ")), false);
});
