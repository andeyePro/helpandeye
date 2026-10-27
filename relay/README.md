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
| `GET /g/<group>/messages?after=<seq>` | a member | none; the reply is `{"latest": n, "next": n, "messages": [...]}`. A negative `after` asks for the last that many messages. Read on from `next`, which moves past expired messages. |
| `PUT /g/<group>/push` | a member | `{"token": "<hex APNs device token>", "sandbox": true or false}` |

A posted message may add `"wake": "call"`, which sends every other member a visible push ("A call
for help in your group. Open Help&I to see who."), or `"wake": "quiet"`, which only wakes their
app. The app asks for `call` on a call's first send and `quiet` on an acknowledgement; resends do
not push. The relay cannot read who called, so the push cannot say; the app works out the rest
once awake. Because the push goes to everyone at once, a responder whose turn would come later is
told early over the internet route: the escalation order still decides the repeated alerts.

The first coordinator to send a member list owns the group. After that only a coordinator in the
current list can change it, only to a newer version (sending the same list again is accepted),
and a phone left out of it is refused at once. Each message is its own storage key, at most 512
characters, kept for seven days, 2,000 at most.

A phone's first read asks for the last 200 messages and acts only on the last quarter of an hour
of them, so a call still open is heard at once and a week of old ones is not.

Each phone may post 20 messages a minute and ask for 2 pushes a minute; past that, posts are
refused with 429 and pushes are not sent. Push tokens of anyone left out of a new member list are
deleted.

Every response carries `X-HelpAndI-Allowance-Low: 1` once 40,000 relay requests have been made in
the day, so coordinators hear before the free tier runs out. Each relay request uses two Durable
Object requests (the group's and the meter's), so the free 100,000 Durable Object requests a day
are reached at 50,000 relay requests, before the Worker limit. A phone polls every 30 seconds while
a call is open on it and every two minutes otherwise, while Help&I is open.

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

Push notifications stay off until these secrets are set (`npx wrangler secret put <name>`):
`APNS_KEY` (the contents of the `.p8` key from Apple Developer, Certificates, Keys), `APNS_KEY_ID`,
`APNS_TEAM_ID` and `APNS_TOPIC` (`org.andeye.helpandi`).

Then, in the app, open Group, Internet route, and enter the Worker's `https://` address.
