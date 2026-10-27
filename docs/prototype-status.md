# Prototype status

Where the first Help&I prototype stands. For the detail behind any line, see `CHANGELOG.md`; for
open work and decisions, `TODO.md`.

## What works, as far as a machine can check

- **The app's rules** (`app/HelpAndICore`), with 161 tests including a fuzz test that runs groups of
  phones through random presses, acknowledgements, removals, lost packets, links going down and
  clock jumps, checking the safety rules after every step:
  - a red press goes out at once on every route and is sent again until a person acknowledges it;
  - only a current responder's own signed acknowledgement shows the caller "seen", and one from
    someone later removed is taken back;
  - nothing closes, times out or stops alerting without a person;
  - nothing personal (typed messages, location, check-in times) goes on the shared radio channel;
  - radio use stays inside the Ofcom duty-cycle limit.
- **The iPhone app, watch app and notification extension** build, unsigned, with no warnings.
- **The Bluetooth command queue** that puts a call on the radio, the choice of the box's channel
  slots, reading the relay, and what the caller is told, are in the core package and tested.
- **The internet relay** (`relay/`), with 20 tests, including checks that it verifies what the app
  signs and follows the same membership rules the app's tests assume.

## What has not been checked

- **Nothing has run on a phone, a watch or a radio.** The build Mac's simulator is out of date, and
  signing needs your Apple team. So no screen has been seen, and no Bluetooth or radio behaviour has
  been tried. `tests/MANUAL-TESTS.md` has 32 checks for that, with how to set up first.
- **The relay is not deployed**, and push notifications are off until it has an APNs key.

## What you need to do, in order

1. Read the decisions at the top of `TODO.md`. The one that most changes the design is the box's
   buttons: standard MeshCore firmware gives a plain Heltec no help buttons of its own, so today
   calls start from the phone or watch.
2. Sign in to Xcode on the build Mac with the Apple developer account (`TODO.md`, Signing), and
   install Xcode's components there so the simulator runs.
3. Deploy the relay and add the APNs key (`relay/README.md`, Deploy).
4. Run `tests/MANUAL-TESTS.md`, starting with Before you start and sections 1, 2, 3, 4 and 12.
   Note the commit you ran.
