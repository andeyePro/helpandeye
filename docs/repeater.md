# A rooftop repeater: a self-built Heltec T114

Martin's decision of 2026-11-03: build Help&I's rooftop repeaters ourselves rather than buy a
sealed unit. The board is Claude's proposal, which Martin accepted: the Heltec Mesh Node T114
has the same nRF52840 and SX1262 as the RAK4631 and the SenseCAP Solar Node, so it listens on
the same current, and it is the cheapest. This is the specification and its test
(`tests/MANUAL-TESTS.md`, section 63). Nothing here has been built yet; section 8 lists what
was confirmed from a source and what was not.

A repeater runs MeshCore's stock repeater firmware, not Help&I's. It holds no group key: it
repeats sealed packets it cannot read. Nothing on it is personal, and nothing of Help&I's depends
on it being there: a box whose repeater is down still reaches any box in its own range.

## 1. The board

Heltec Mesh Node T114, 863 to 870 MHz version, without the display. Heltec gives its transmit
power as 21 ± 1 dBm and its radio as the SX1262 with no amplifier after it, so MeshCore's
power setting is the power at the antenna socket, within a decibel. The board takes a 3.7 V
lithium cell on its battery connector and has a solar input of 5 to 6.5 V with its own charger.
That charger is not used here (section 6): nothing in Heltec's documents says it stops charging
in the cold.

Build without GPS. MeshCore issue 1628 found a build with GPS compiled in drew about 8 mA more
than one without, even with the GPS turned off; the repeater needs no position.

## 2. Firmware and settings

MeshCore repeater firmware 1.14.1 or later, the `Heltec_t114` build with no display and no GPS,
flashed with the MeshCore web flasher. 1.14.1 is the first release with both the `powersaving`
command for nRF52 repeaters (in `CommonCLI.cpp` at the tag `repeater-v1.14.1`) and duty-cycle
enforcement (token bucket, PR 1297). 1.15.0 added `set dutycycle` (PR 1961); before it the
airtime factor `set af` does the same job less exactly.

Set it up over the USB serial console, or the companion app's repeater administration, before
the roof antenna is fitted, with a dummy load or the short antenna supplied with the board on
the socket, never an open socket: the build ships at `set tx 22`, which on the Taoglas antenna
of section 3 is above the Ofcom limit, so the transmit power and duty cycle go in first and the
antenna after. Every Help&I box in the area must be on the same radio preset, the EU/UK narrow
one, which `tests/MANUAL-TESTS.md` already requires of the boxes.

```
password <a new one>        the default is "password"; anyone in range can otherwise administer it
set name <plain name>       adverts carry the name in clear: nothing that says whose roof it is
set radio 869.618,62.5,8,8  869.618 MHz, 62.5 kHz, spreading factor 8, coding rate 8 (EU/UK narrow)
set tx 21                   from section 3's table; never above the figure for the antenna fitted
set dutycycle 10            10% (1.15.0 and later); on 1.14.1 use "set af 9", which gives about 10%
set repeat on
powersaving on              the board sleeps between packets
reboot                      the radio settings take effect at the next start
```

Leave `lat` and `lon` at 0: a repeater's advert would otherwise put its position on air, and
MeshCore's routing does not need it. Leave `flood.max`, `txdelay` and `rxdelay` at their
defaults. The repeater needs no Help&I channel: a group's packets are relayed sealed, as any
other MeshCore traffic is.

MeshCore does not do the listen-before-talk and frequency agility that IR 2030 allows in place
of a duty cycle, so the 10% limit applies and the setting above enforces it. A repeater's airtime
is shared by everything it relays, Help&I's and anyone else's.

## 3. Antenna, cable and transmit power

### The limit

Ofcom's UK Interface Requirement 2030, published 7 April 2026, row IR2030/1/19: 869.40 to
869.65 MHz, non-specific short range devices, 500 mW e.r.p., 10% duty cycle (or the techniques
of EN 300 220). The same figures are in the licence-exempt regulations' schedule (500 mW erp,
duty cycle 10%). 500 mW is 27 dBm.

The limit is ERP: power compared with a half-wave dipole. EIRP compares with an isotropic
radiator, which a dipole beats by 2.15 dB, so 27 dBm ERP is 29.15 dBm EIRP. Antenna gain in dBd
is against a dipole and adds to the transmitter's power straight; gain in dBi is against an
isotropic radiator and has 2.15 dB taken off first. Most antenna datasheets quote dBi.

```
ERP (dBm) = radio setting (dBm) − cable and connector loss (dB) − filter loss (dB) + antenna gain (dBd)
highest setting = 27 − gain (dBd) + losses, rounded down to a whole dBm
```

The setting is treated as the output. Heltec's figure of 21 ± 1 dBm at the top setting means
the board may put out up to 22 dBm when set to 22, so the arithmetic uses the setting itself
and the top setting is used only where the table allows it. Measure the output if a power meter
is to hand: section 55 of `MANUAL-TESTS.md`, run with the repeater in place of box A.

### The antenna

An outdoor collinear of about 5 to 6 dBd (7 to 8 dBi), N female, mounted as high as the roof
allows and clear of metal. Candidates, with the figures their makers give:

| Antenna | Gain | Length | Notes |
|---|---|---|---|
| Taoglas OMB.868.B08F21 | 8 dBi (5.85 dBd) | 1,474 mm | fibreglass, N female, IP65, VSWR 1.5, bracket mount |
| Sirio SCO-868-6 | 4.1 dBd (6.2 dBi), Sirio's own dBd figure | 770 mm | 868 to 870 MHz, N female, 330 g; under the 5 dBd asked for, but short and light |
| RAK ARG18 | 5.8 dBi (3.65 dBd) | | fibreglass, 863 to 870 MHz, N female |

A collinear's gain is in the horizontal plane: a higher gain is a flatter beam, which is right
for a roof above the boxes it serves and wrong for a roof far above a valley. The Taoglas is
the one to build with; the Sirio if its height or weight rules the Taoglas out.

### The cable

Short and low loss, from the box to the antenna with no join. Loss at 900 MHz from the makers'
tables, which is close enough for 869.6 MHz:

| Cable | Loss | For 3 m |
|---|---|---|
| LMR-400 | 3.9 dB per 100 ft, 12.8 dB per 100 m | 0.4 dB |
| LMR-240 | 7.6 dB per 100 ft, 25 dB per 100 m | 0.75 dB |
| RG58 | 11 to 14 dB per 100 ft, 36 to 46 dB per 100 m | 1.1 to 1.4 dB |

Add about 0.1 dB for each N connector, 0.2 dB for the short SMA to N lead inside the box, and
the surge arrestor's insertion loss (section 5), taken here as 0.1 dB: no figure for the Westell
was found, so it is unconfirmed. LMR-400 is the choice; LMR-240 where it must bend tightly;
RG58 for nothing longer than the lead inside the box. 3 m of LMR-400 (0.4 dB) with two N
connectors (0.2 dB) and the lead (0.2 dB) is 0.8 dB, and 0.9 dB with the arrestor.

### The setting

With 3 m of LMR-400, its connectors, the lead and the arrestor (0.9 dB in all) and no filter:

| Antenna | Highest setting | ERP at that setting |
|---|---|---|
| Taoglas, 5.85 dBd | 27 − 5.85 + 0.9 = 22.05, so `set tx 21` (see below) | 21 − 0.9 + 5.85 = 25.95 dBm (390 mW) |
| Sirio, 4.1 dBd | 23.8, so `set tx 22` (the board's top) | 22 − 0.9 + 4.1 = 25.2 dBm (330 mW) |
| RAK, 3.65 dBd | 24.25, so `set tx 22` | 22 − 0.9 + 3.65 = 24.75 dBm (300 mW) |

The Taoglas reaches 22.05 only on the arrestor's unconfirmed 0.1 dB; without it the figure is
21.95, so it stays at `set tx 21` until the arrestor's loss is measured. With a SAW filter in
the line (section 4, about 2 dB) the Taoglas allows `set tx 22`: 22 − 2.9 + 5.85 = 24.95 dBm.
Redo the arithmetic for any other antenna, cable length or filter, and write the figures on a
label inside the box. A longer cable loses more than a higher setting gains: put the box at the
antenna, not the antenna's cable at the box.

No range figure is given here. None was measured, and none found in a source applies to this
antenna, this preset and a given roof.

## 4. A band filter

The 900 MHz mobile uplink starts at 880 MHz, 10 MHz above the preset, and a roof near a mast,
a broadcast site or a lot of other 868 MHz traffic can overload the SX1262's front end: the
noise floor rises and packets a box hears at street level go unheard on the roof. The fix is a
band-pass filter between the board and the antenna.

How to tell: the noise floor MeshCore reports. In the OARC group's test of 868 MHz filters on a
noisy UK site (wiki.oarc.uk, March 2026), a cheap SAW filter took the reported noise floor from
about −96 dBm to about −105 dBm and improved the signal-to-noise ratio of what the node heard by
about 10 dB, for 2.4 dB of insertion loss. A helical cavity filter measured 1.3 dB of loss but
needed a long retune before it was any use. A quiet site needs no filter and should not have
one: its loss is paid on every packet, both ways.

Fit: an 868 MHz SAW band-pass filter with SMA or N connectors (the F4NLV type sold to the
mesh community claims 1.5 to 1.8 dB of loss and 30 to 40 dB out of band; the OARC figure for
a cheap SAW filter is 2.4 dB), inside the box, between the board's lead and the surge arrestor.
Take its loss off the transmit arithmetic in section 3; it allows a higher setting.

## 5. The box

Everything stays on the roof. No wire of any kind runs into the house, so there is nothing to
earth indoors and nothing a strike can follow in.

- **Enclosure:** IP66 or IP67 (IP66 is rated for powerful water jets, IP67 for brief immersion),
  polycarbonate or ABS, UV stable, with a hinged or screwed lid on a gasket. Hammond's listings
  give its 1554 and 1555 series as IP66 and IP67 (not read here, section 8); Fibox and Spelsberg
  make the same kind. Large enough for the board, the cells, the charger and the filter with
  room to work.
- **Connectors:** an N female bulkhead for the antenna and IP68 cable glands (M12 or M16) for
  the panel lead, all on the bottom face, never the top. A short SMA to N lead from the board
  to the bulkhead.
- **Drip loop:** every cable dips below its gland before it rises to it, so water runs off the
  loop and not into the box.
- **Condensation:** a membrane vent (Gore type) in the bottom face lets the box breathe without
  taking in water; a sachet of desiccant for the first season.
- **Lightning and earthing:** a coaxial surge arrestor with a gas discharge tube and N
  connectors, rated to 3 GHz or more (Westell's CS60-024-002, 0 to 3,000 MHz, 20 kA at 8/20 µs,
  is one), at the antenna side of the box, bonded by a short thick conductor to the mast, and
  the mast to an earth. It protects the board from induced surges, not from a direct strike.
  Whether a roof needs a lightning protection system is a BS EN 62305 question for a competent
  electrician, and that decision is theirs, not this document's.
- **A label inside** with the antenna, cable, filter, the transmit setting and the arithmetic
  behind it, the firmware version and the date.

## 6. Power

### What it draws

Figures from other people's measurements of MeshCore on nRF52 boards, none of them this build:

- nRF52 repeater with the power-saving sleep, at 3.6 V: 6 to 7 mA, falling to 5 mA after the
  first advert (the author of MeshCore PR 1562, which added the sleep).
- Heltec T114 companion firmware, idle: 12 mA falling to 8 mA with the sleep added (a tester
  on PR 1682, with a Nordic Power Profiler Kit); 14 to 15 mA falling to 8.2 mA (another tester,
  method not given).
- Transmitting at the top setting: about 120 mA for the SX1262 at 22 dBm, the datasheet's
  order of figure, not checked here. At the full 10% duty cycle that is 12 mA averaged.

The budget below uses 8 mA listening and 12 mA for transmitting at the whole duty cycle, 20 mA
in all, at 3.7 V: 74 mW, 1.8 Wh a day. A repeater seldom uses its whole duty cycle, so the
usual draw is nearer 10 mA, 0.9 Wh a day. Section 63 of `MANUAL-TESTS.md` measures the real
figure, which replaces these.

### The battery, and charging in the cold

Lithium cells must not be charged below 0 °C: lithium plates onto the anode, which takes
capacity away for good and can grow into a short. Discharging in the cold is fine. So the
charger, not the cell, must know the cell's temperature and stop.

Chemistry: lithium-ion (3.7 V nominal, 3.0 to 4.2 V), because that is the cell the T114 is
made for. A LiFePO4 cell is safer and lasts longer but sits at 3.2 V, and whether the board runs
the radio at full power from 3.2 V is not confirmed. Two protected 18650 cells of about
3,400 mAh in parallel give 6.8 Ah, 25 Wh: 14 days at the budget's 20 mA and 28 days at 10 mA,
before the cold takes some of that (how much is not quantified here). Protected cells or a pack
with its own protection, and a fuse in the lead.

Charger: a single-cell solar charger with a thermistor on the cell.

| Part | Relevant figures | Not confirmed |
|---|---|---|
| Adafruit bq24074 breakout (TI bq24074) | charges one Li-ion cell at up to 1.5 A, set by a resistor; optional 10 kΩ NTC (103AT) on the THERM pad, enabled by cutting a jumper, for "outdoor projects where the battery may get hot (50 °C) or cold (0 °C)"; TI's family datasheets say charging is suspended outside the thermistor window; input regulation at 4.4 V suits a 6 V panel without a maximum-power tracker | the exact cold and hot thresholds in the bq24074 datasheet itself (a TI forum answer gives 50 °C for the hot end, and the window can be widened but not narrowed); the input voltage the breakout tolerates against a cold 6 V panel's open-circuit voltage |
| Adafruit bq25185 breakout (TI bq25185) | one cell, 500 mA default; a TH pad for a 10 kΩ thermistor after cutting a trace; TI lists JEITA thermistor monitoring for the chip; a jumper selects LiFePO4 (3.65 V) | whether Adafruit's board stops charging at 0 °C, as against slowing it when hot; Adafruit's text says the thermistor "adjusts the charge rate" |

The bq24074 is the one to build with, with the thermistor taped to a cell. The T114's own
solar input stays empty: the cell goes to the board's battery connector and to the charger's
battery terminals, and the board's charger, with no input, charges nothing.

Why not a 12 V LiFePO4 battery and a Victron SmartSolar 75/10, the usual off-grid build: the
controller has a low-temperature cut-off for lithium (users give its default as 5 °C, and it
needs a Smart Battery Sense on a VE.Smart network to read the cell's temperature; the manual
was not read here), but its own draw is 10 to 25 mA at 12 V depending on which datasheet
edition is read, 3 to 7 Wh a day: more than the repeater. Small packs with a cut-off in their
own protection board exist (the datasheets found give 0 °C, with a return at 5 to 10 °C), but
none at 6 to 10 Ah was found with the cut-off stated.

### The solar panel, sized for December

What December gives, in the plane of a south-facing panel tilted steeply (60° or more):

- London, horizontal, December: 0.52 kWh/m² a day (Wikipedia, "Solar power in the United
  Kingdom"); July 4.74.
- A PVGIS-5 report for a site in Cumbria at a fixed tilt: 20.3 kWh/m² for December in the
  plane of the panel, 0.65 kWh/m² a day.
- No PVGIS run for a specific site was possible from here. Run PVGIS for the roof's position
  and tilt before buying, and read the December `H(i)_m` figure.

The budget takes 0.6 kWh/m² a day, that is 0.6 peak-sun hours. A run of a week or more at a
fifth of that is normal in December, which the battery covers.

```
load                 20 mA × 24 h × 3.7 V          = 1.8 Wh a day (worst case)
charger              linear: about 3.7 V / 6 V     = 60% from a 6 V panel
from the panel       1.8 / 0.6                      = 3.0 Wh a day
panel derating       dirt, angle, cold             = 0.8
panel needed         3.0 / (0.6 h × 0.8)           = 6.2 W
```

Fit a 10 W, 6 V nominal panel (open-circuit about 7 V): it covers the worst-case December
average with margin, and on a typical day at 10 mA it refills a week's shortfall in two bright
days. Mount it at 60° or steeper, facing south, where snow slides off and nothing shades it
at midday in December, when the sun is 15° above the horizon at best. A 12 V panel is not for
this charger. Check the charger's input limit against the panel's open-circuit voltage on a
cold bright day before connecting them.

## 7. What the repeater changes in Help&I's rules

Nothing. The repeater is not a member of any group and carries no Help&I rule. A Help&I box
within its range reaches more boxes; a box out of its range is as it was. The rules in
`AGENTS.md` apply unchanged: the repeater must not raise any box's transmit power or duty cycle,
and it does not.

## 8. Confirmed, and not

Confirmed from a source read or quoted here:

- The limit: IR 2030, published 7 April 2026, row IR2030/1/19, 500 mW e.r.p., 10% duty cycle,
  869.40 to 869.65 MHz (search extracts of Ofcom's PDF; the PDF itself could not be opened
  from here, so the row's notes column should be read once by someone who can).
- MeshCore: `powersaving` in the repeater CLI at `repeater-v1.14.1`; token-bucket duty cycle in
  1.14.1 (PR 1297, merged 2026-03-08); `set dutycycle` in 1.15.0 (PR 1961, merged
  2026-03-26); `set af` 0 to 9 giving about 1/(1 + af); `set tx` 1 to 22; the T114 build's
  default `LORA_TX_POWER=22` (`variants/heltec_t114/platformio.ini`).
- The EU/UK narrow preset, 869.618 MHz, 62.5 kHz, SF8, CR8, from several UK mesh groups'
  guides, not from MeshCore's own documents.
- Heltec T114: 21 ± 1 dBm, solar input 5 to 6.5 V, 3.7 V cell (Heltec's and resellers' pages).
- Cable losses (Times Microwave's tables as resellers quote them); the antennas' figures
  (DigiKey's and Sirio's listings); the OARC filter test; the bq24074 and bq25185 features
  (Adafruit's guides); lithium plating below 0 °C (REDARC's and others' pages).

Not confirmed, and to be checked before the build:

- The current the T114 draws as a repeater with `powersaving on`: every figure above is for
  another board, another firmware or another method. Section 63 of `MANUAL-TESTS.md` replaces
  them.
- The SX1262's transmit current at 22 dBm (about 120 mA is assumed).
- The bq24074's exact thermistor thresholds, and its input tolerance against a 6 V panel's
  open-circuit voltage in the cold.
- Whether the bq25185 breakout stops charging at 0 °C.
- The Victron 75/10's cut-off default and its own draw (datasheet editions differ).
- December irradiation for any given roof: two figures from other sites are used; PVGIS must
  be run for the roof.
- Whether the T114 runs the radio at full power from a LiFePO4 cell.
- How much of the battery's capacity the cold takes.
- The board's real output against its setting, until measured (section 55, with the repeater
  in place of box A).
- The surge arrestor's insertion loss: 0.1 dB is assumed.
- The Hammond enclosures' ratings (Hammond's figures, not read here).
- Any range figure. None is given.

## Sources

- Ofcom, UK Interface Requirement 2030, published 7 April 2026:
  ofcom.org.uk/siteassets/resources/documents/spectrum/interface-requirements/ir-2030.pdf
- MeshCore CLI reference: docs.meshcore.io/cli_commands; MeshCore source at the tags
  `repeater-v1.14.1` and `repeater-v1.18.0`; PRs 1297, 1562, 1682 and 1961; issue 1628.
- MeshCore release notes 1.14.1 (blog.meshcore.io, 2026-03-20) and 1.15.0 (2026-04-19).
- Heltec, Mesh Node T114: wiki.heltec.org and resource.heltec.cn.
- Taoglas OMB.868.B08F21 (DigiKey listing); Sirio SCO-868-6 manual; RAK ARG18 datasheet.
- Times Microwave LMR-400 and LMR-240 attenuation tables, as quoted by resellers.
- OARC, "868 MHz filters", wiki.oarc.uk/lora:868filters, March 2026.
- Adafruit, bq24074 and bq25185 charger guides, learn.adafruit.com.
- REDARC, "Why you should not charge a lithium battery below 0 °C".
- Wikipedia, "Solar power in the United Kingdom"; a PVGIS-5 report for a Cumbrian site
  (cafs.org.uk, 2023).
- ERP and EIRP: Wikipedia, "Effective radiated power".
