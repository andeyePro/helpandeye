# Help&I relay

The internet route for Help&I. A Cloudflare Worker with one Durable Object per group stores and
forwards messages that the phones have already sealed with the group key. The relay never has
that key: it holds ciphertext and the members' public signing keys, nothing else.

## Protocol

Every request is signed by the phone's Ed25519 key. The headers are:

- `X-HelpAndI-Key`: the phone's public signing key, base64
- `X-HelpAndI-Time`: milliseconds since 1970; refused if more than 5 minutes out
- `X-HelpAndI-Signature`: Ed25519 over `HELPANDI-RELAY-1\n<method>\n<path and query>\n<time>\n<base64 SHA-256 of the body>`

| Request | Who | Body |
|---|---|---|
| `PUT /g/<group>/members` | a coordinator | `{"generation": n, "members": [{"key": "...", "role": "coordinator" or "member"}]}` |
| `POST /g/<group>/messages` | a member | `{"sealed": "<base64 ChaCha20-Poly1305 box>"}` |
| `GET /g/<group>/messages?after=<seq>` | a member | none |

The first coordinator to send a member list owns the group. After that only a coordinator in the
current list can change it, never to an older generation, and a phone left out of it is refused
at once. Messages are kept for seven days, 2,000 at most.

Every response carries `X-HelpAndI-Allowance-Low: 1` once 80% of Cloudflare's free daily
allowance (100,000 requests) has been used, so coordinators hear before it runs out.

## Run the tests

```
npm test
```

`test/interop.test.js` checks a request signed by the app's Swift code
(`app/HelpAndICore`, `RelayVectorTests`).

## Deploy

```
npx wrangler deploy
```

Then, in the app, open Group, Internet route, and enter the Worker's `https://` address.
