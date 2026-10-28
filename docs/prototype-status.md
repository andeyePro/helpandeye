# Prototype status

Where the first Help&I prototype stands. For the detail behind any line, see `CHANGELOG.md`; for
open work and decisions, `TODO.md`.

## What works, as far as a machine can check

- **The app's rules** (`app/helpandeyeCore`), with 237 tests including a fuzz test that runs groups of
  phones through random presses, acknowledgements, removals, lost packets, links going down and
  clock jumps, checking the safety rules after every step:
  - a red press goes out at once on every route and is sent again until a person acknowledges it;
  - only a current responder's own signed acknowledgement shows the caller "seen", and one from
    someone later removed is taken back;
  - nothing closes, times out or stops alerting without a person: only the caller (where their
    profile allows) or a coordinator with a reason closes a call, each signed;
  - nothing personal (typed messages, location, check-in times) goes on the shared radio channel;
  - radio use stays inside the Ofcom duty-cycle limit.
- **The iPhone app, watch app and notification extension** build, unsigned, with no warnings.
- **The Bluetooth command queue** that puts a call on the radio, the choice of the box's channel
  slots, reading the relay, and what the caller is told, are in the core package and tested.
- **The internet relay** (`relay/`), with 22 tests, including checks that it verifies what the app
  signs and follows the same membership rules the app's tests assume.
- **Home Wi-Fi** (decision 19): within one Wi-Fi network the group's phones call each other
  directly, with no box, server or internet; only another proven member counts, and only once
  their Help&I confirms it read the call. The core is tested; the app's Bonjour link and the
  locked-phone listener are built but not run.
- **Coordinator settings**: profiles with per-setting locks, closing a call, the log, change
  requests, and the watch's Help complication with its countdown, all in the core and tested;
  the screens are screenshotted and audited on the MacBook's simulators.

## What has not been checked

- **Nothing has run on a phone, a watch or a radio.** Screens have been seen only in the
  simulator, and signing needs your Apple team, so no Bluetooth or radio behaviour, sound or
  vibration has been tried. `tests/MANUAL-TESTS.md` has 42 checks for that, with how to set up
  first.
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
