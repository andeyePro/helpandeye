# Help&I relay

The internet route for Help&I. A Cloudflare Worker with one Durable Object per group stores and
forwards messages that the phones have already sealed with the group key. The relay never has
that key: it holds ciphertext and the members' public signing keys, nothing else.

## Protocol

Every request is signed by the phone's Ed25519 key. The headers are:

- `X-HelpA-Key`: the phone's public signing key, base64
- `X-HelpA-Time`: milliseconds since 1970; refused if more than 5 minutes out
- `X-HelpA-Signature`: Ed25519 over `HELPA-RELAY-1\n<method>\n<path and query>\n<time>\n<base64 SHA-256 of the body>`

The Worker checks the time and signature before the request reaches its group, and refuses a bad
one with 401. The group then checks the key is one of its members.

| Request | Who | Body |
|---|---|---|
| `PUT /g/<group>/members` | a coordinator | `{"generation": n, "members": [{"key": "...", "role": "coordinator" or "member"}], "removed": ["key", ...], "primary": "key"}` |
| `POST /g/<group>/messages` | a member | `{"sealed": "<base64 ChaCha20-Poly1305 box>"}` |
| `GET /g/<group>/messages?after=<seq>` | a member | none; the reply is `{"latest": n, "next": n, "epoch": "...", "messages": [...]}`. A negative `after` asks for the last that many messages. Read on from `next`, which moves past expired messages. `epoch` names the group's log and changes only if the relay's storage is reset, when a phone's place in the old log means nothing. |
| `PUT /g/<group>/push` | a member | `{"token": "<hex APNs device token>", "sandbox": true or false, "device": "watch"}`; `device` is left out, or anything else, for a phone. A member has one phone token and one watch token. |

A member list's body may be up to 128 KiB: the largest the app can send, 256 members and 1,024
removed keys with every `/` escaped as `\/`, is under 122 KB, and a typical full one is about
67 KB. Every other body may be up to 16 KiB. Larger ones are refused with 413, by their
`Content-Length` before they are read, or as soon as they pass the limit.

A posted message may add `"wake": "call"`, which sends every other member a visible push ("A call
for help in your group. Open Help&I to see who."), or `"wake": "quiet"`, which only wakes their
app. The app asks for `call` on a call's first send and `quiet` on an acknowledgement; resends do
not push. The relay cannot read who called, so the push cannot say; the app works out the rest
once awake. Because the push goes to everyone at once, a responder whose turn would come later is
told early over the internet route: the escalation order still decides the repeated alerts.

The reply to a post is `{"seq": n}`. If a wake was asked for and no push got through (APNs
answered none of them with success, for whatever reason, including a token it reports as dead or
a refused provider token), or the sender has asked for more pushes this minute than it may, it is
`{"seq": n, "woke": false, "reason": "..."}`; a post with the same `wake` then pushes again. The
reason is for people reading logs, and a client may ignore it. Push tokens APNs reports as dead are
deleted. A Worker may make only 50 subrequests a request on the free plan, so a post pushes to at
most 49 phones and watches itself, phones first, and the group's alarm sends the rest straight
after, 50 at a time; `woke` reports on the first 49. The APNs provider token is signed once and
kept for 40 minutes.

The group's first coordinator owns the group on the relay. The group's ID is made from their key
(8 random bytes, then the first 8 bytes of SHA-256 over `HELPA-GROUP-1`, those bytes and the
key), so the group can be registered only by them, with a list naming them as `primary`. Until
they have, another coordinator's list is refused with 425 (too early), and taken once they have.
After that, any coordinator's list adds people, as members; only the owner sets roles, from their
newest list, and removes people, by naming them in `removed`; nobody removed is ever listed
again. When the owner removes a coordinator, people only that coordinator added, and the owner
does not list, go too, and only the owner can list them again. A list holds at most 256 members,
and every key must be a 32-byte key. Each message is its own storage key, its sealed text at most
4,096 characters, kept for seven days, 2,000 at most. The group's alarm deletes expired messages
whether or not anyone posts.

A phone's first read asks for the last 200 messages and acts only on the last quarter of an hour
of them, so a call still open is heard at once and a week of old ones is not.

Each phone may post 20 messages a minute and ask for 2 pushes a minute; past that, posts are
refused with 429 and pushes are not sent. Leaving someone out of a list does not take them off;
only `removed` does. When someone is taken off, their push tokens and rate record are deleted.

Cloudflare's rate limiting (`ratelimits` in `wrangler.jsonc`) also refuses, with 429:

- more than 120 requests a minute from one address, before the signature is checked. Phones on
  one Wi-Fi, such as a care home's, share an address.
- more than 600 requests a minute from a group's members, enough for 256 phones polling every 30
  seconds. Only members count, so someone outside the group cannot use up its limit.
- more than 3 new groups a minute registered from one address.

These limits are counted at each Cloudflare location separately, so they hold back floods, not
every request. A limit that is not configured, or that fails, refuses nothing.

Every response carries `X-HelpA-Allowance-Low: 1` once 40,000 relay requests have been made in
the day, so coordinators hear before the free tier runs out. Only requests that pass the
signature check are counted. Each relay request uses two Durable Object requests (the group's and
the meter's), so the free 100,000 Durable Object requests a day are reached at 50,000 relay
requests, before the Worker limit. The meter is asked after the reply has gone, so a slow or
failing meter never holds one up, and the header comes from its last answer. A phone polls every 30 seconds while
a call is open on it and every two minutes otherwise, while Help&I is open.

## Run the tests

```
npm test
```

`test/interop.test.js` checks a request signed by the app's Swift code
(`app/helpandeyeCore`, `RelayVectorTests`). `test/model.test.js` replays member-list publishes
recorded from the app's fuzz test, checking the app's copy of these rules gives the same results.

## Deploy

```
npx wrangler deploy
```

Push notifications stay off until these secrets are set (`npx wrangler secret put <name>`):
`APNS_KEY` (the contents of the `.p8` key from Apple Developer, Certificates, Keys), `APNS_KEY_ID`,
`APNS_TEAM_ID` and `APNS_TOPIC` (`com.andeye.help`).

Then, in the app, open Group, Internet route, and enter the Worker's `https://` address.
