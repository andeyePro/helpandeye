# Help&I relay

The internet route for Help&I. A Cloudflare Worker with one Durable Object per group stores and
forwards messages that the phones have already sealed with the group key. The relay never has
that key: it holds ciphertext and the members' public signing keys, nothing else.

## Protocol

Every request is signed by the phone's Ed25519 key. The headers are:

- `X-HelpA-Key`: the phone's public signing key, base64
- `X-HelpA-Time`: milliseconds since 1970; refused if more than 5 minutes out
- `X-HelpA-Signature`: Ed25519 over `HELPA-RELAY-1\n<method>\n<path and query>\n<time>\n<base64 SHA-256 of the body>`
- `X-HelpA-Pass`: the group's relay pass (below), when the relay requires one

The Worker checks the time and signature before the request reaches its group, and refuses a bad
one with 401. The group then checks the key is one of its members.

## Passes

Help&I's own relay is a paid service once Help&I pays for it: with the `REQUIRE_PASS` var set to
`1`, every request for a group must carry a pass for that group in `X-HelpA-Pass`, or it is
refused with 402 before any Durable Object is called (`{"error": "pass required"}`, `"pass
expired"`, `"pass is for another group"` or `"bad pass"`). With the var unset or `0`, as deployed
before passes, every group is taken and a pass sent is ignored.

A pass is `1.<group ID>.<expiry>.<signature>`: the group ID as it appears in the path, the expiry
in seconds since 1970, and an Ed25519 signature in URL-safe base64 over
`HELPA-PASS-1\n<group ID>\n<expiry>` by Help&I's issuer key, whose public key the Worker reads
from the `ISSUER_KEY` var. The relay keeps nothing about passes: it checks the signature once per
pass it sees (cached in memory, still checked against the clock and the group each time), so a
group's phones polling cost it nothing more. A forged pass is counted against its address like a
bad signature; a missing or expired one is not, so a group without a pass always hears why. How a group came by its pass (bought, or given) is no
concern of the relay: the app holds it as a group setting, shared with every member like the
relay address, and sends it with each request.

`pass.mjs` issues them, on a machine you trust, never on the relay:

```
node pass.mjs keygen                  once: makes the issuer key pair, prints the public key
node pass.mjs public                  prints the public key, for ISSUER_KEY
node pass.mjs issue <group ID> <days> prints a pass for the group, good for that many days
node pass.mjs show <pass>             prints the group and expiry a pass names
```

The key pair is saved to `~/.helpandeye/relay-issuer.json` (or the file `HELPA_ISSUER_KEY_FILE`
names), readable by its owner only and never in a repository; whoever holds it can issue passes.
The key itself is never read from the environment or the command line.
A coordinator finds the group's ID in the app under Group, Internet route, and pastes the pass
there; the app shows until when it is good.

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

The reply to a post is `{"seq": n}`. If a wake was asked for, push is set up, and nobody has been
woken, it is `{"seq": n, "woke": false, "reason": "..."}`; a post with the same `wake` then pushes
again. Nobody has been woken when no push got through (APNs answered none with success, for
whatever reason, including a token it reports as dead or a refused provider token), when there
was nobody to push to (no other member has a token, or every token was dead), or when the sender
has asked for more pushes this minute than it may. A `call` has woken someone only when a phone
took its push: a watch is woken quietly. The reason is for people reading logs, and a client may
ignore it. Push tokens APNs reports as dead are deleted.

The relay keeps, for each sender and kind of wake, which members' phones and watches its pushes
reached in the last 15 minutes, counted from the first. A wake asked for again in that time, as on
a call's resend, goes only to those not reached yet, and is not reported as `woke: false` if
someone was reached before. Removing a member deletes this record with their tokens.

A Worker may make only 50 subrequests a request on the free plan, so a post pushes to at most 49
phones and watches itself, phones first. The rest are queued, by member and device rather than
token, and the group's alarm sends them straight after, 49 at a time (one subrequest is kept for
the meter), to the tokens those members have when it runs, skipping anyone removed since or
reached by a resend meanwhile. While pushes that could wake someone (phones, for a call) are still
queued, the post is not reported as `woke: false`, whatever the first 49 did. The APNs provider
token is signed once and kept for 40 minutes.

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
only `removed` does. When someone is taken off, their push tokens, rate and wake records are
deleted.

Cloudflare's rate limiting (`ratelimits` in `wrangler.jsonc`) also refuses, with 429:

- more than 120 requests a minute from one address that fail the time or signature check. A
  request whose signature checks is never limited by address, so phones sharing one (a care
  home's Wi-Fi, or a mobile network's shared address) never hold each other back.
- more than 120 signed requests a minute from one phone's key. A phone and its watch polling twice
  a minute, up to 5 pages each, make 20. A post asking for a `call` wake is never refused by this
  limit: only by the 20 posts a minute above.
- more than 6,000 reads (`GET /messages`) a minute from a group's members. The most a group can
  need is 256 members, each with a phone and a watch, each polling twice a minute while a call is
  open, up to 5 pages a poll: 256 × 2 × 2 × 5 = 5,120. Only members count, so someone outside the
  group cannot use up its limit, and posts are never counted, so one member's reads cannot hold
  back another's call.
- more than 3 new groups a minute registered from one address. Only a registration the relay has
  taken counts; one refused for any reason does not.

These limits are counted at each Cloudflare location separately, so they hold back floods, not
every request. A limit that is not configured, or that fails, refuses nothing.

Every response carries `X-HelpA-Allowance-Low: 1` once 40,000 requests have been counted in the
day, so coordinators hear before the free tier runs out. Only requests that pass the signature
check are counted, and so is each run of a group's alarm. Each counted request uses two Durable
Object requests: a relay request the group's and the meter's, an alarm run the alarm itself and
the meter's. So the free 100,000 Durable Object requests a day are reached at 50,000 counted,
before the 100,000 Worker requests (alarm runs are not Worker requests). A group's alarm runs
once for each post whose pushes did not fit in one request (more for every further 49), and at
most once for each message as it expires, so on a steady day there are at most about as many
alarm runs as posts; for
example 40,000 relay requests and 10,000 alarm runs make 100,000 Durable Object requests. The
meter is asked after the reply has gone, so a slow or failing meter never holds one up, and the
header comes from its last answer. A phone polls every 30 seconds while a call is open on it and
every two minutes otherwise, while Help&I is open.

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

To require passes, set `REQUIRE_PASS` to `"1"` and `ISSUER_KEY` to the issuer's public key in
`wrangler.jsonc` (`vars`) and deploy again. With `REQUIRE_PASS` set and no `ISSUER_KEY`, or one
that is not an Ed25519 public key, every request is refused with 500 rather than let in, and
nobody is told to get a pass for a relay that is broken.

Then, in the app, open Group, Internet route, and enter the Worker's `https://` address.
