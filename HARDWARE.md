# Booth Hardware Reference

Wiring topology for the photobooth Pi (Raspberry Pi 4B). Scope is
currently limited to button wiring; the rest of the booth electronics
(LEDs, neopixel data, ATX rails, printer) will be added as those
designs are validated.

---

## Button wiring (v0.4.1 design — rollout in progress)

The photobooth runtime (`photobooth-run`) expects **active-low**
buttons: idle HIGH (pulled to 3.3V), pressed LOW (shorted to GND).
The code in `photobooth/rpi.py` registers `GPIO.FALLING` edge
interrupts with `bouncetime=500` ms.

### Per-button schematic (Pi end)

```
                       PI END                              BUTTON END
                  ───────────────                       ────────────────

  Pi pin 1 ───────────[3.3V rail]
  (3.3V)                  │
                          │
                       [10 kΩ]
                          │
                          ▼
                   ╔══════════╗
                   ║  SIG     ║
                   ║  node    ╠════ white-brown wire ═══ ●  button
                   ║          ║                          │  contact A
                   ╚════╤═════╝                          │
                        │                                ○  (open switch)
                        ├──[1 kΩ]── Pi pin <BTN>         │
                        │           (GPIO <BCM>)         │
                        │                                ●  button
                        │                                │  contact B
                       [100 nF]                          │
                        │                                │
                        ▼                                │
                   ╔══════════╗                          │
                   ║  GND     ║                          │
                   ║          ╠════ brown wire ═════════ ●
                   ╚════╤═════╝
                        │
  Pi pin 6 (GND) ───────┘
```

| Part | Value | Purpose |
|---|---|---|
| Pull-up | 10 kΩ ¼ W | SIG idles at 3.3V; defines logic-high state when switch is open |
| Series protection | 1 kΩ ¼ W | Limits current into GPIO if SIG is ever driven outside 0–3.3V; doesn't affect normal signaling |
| Low-pass | 100 nF (0.1 µF) ceramic or film | Forms a ~1 ms RC low-pass with the pull-up; filters sub-millisecond EMI transients of either polarity. Real presses (≥ 50 ms) pass cleanly. |

Three parts per button. All standard hobbyist values.

### GPIO pin assignment

| Button | GPIO (BCM) | Physical pin |
|---|---|---|
| Shutter (blue) | 25 | 22 |
| Green | 23 | 16 |
| Red | 24 | 18 |

3.3V supply taken from Pi pin 1. GND can be any of pins 6, 9, 14, 20,
25, 30, 34, 39. The PSU's 12V LED supply (separate circuit) is
documented separately when those wiring decisions are finalized.

### Cat5e pair assignment

Each button is connected to its Pi-end cookie board via a single cat5e
cable. Pair assignment matters for noise rejection — both wires of a
single twisted pair must carry a related signal pair (signal + its
return), not signal + an unrelated supply:

| Cat5e pair | Wires | Carries |
|---|---|---|
| 4, 5 | blue + white-blue | 12V LED supply + 12V return (LED + LED-GND) |
| 7, 8 | brown + white-brown | signal-GND + SIG |

Pairs 1, 2 (orange) and 3, 6 (green) are unused. Either can be left
floating or grounded at one end as an additional guard if EMI proves
persistent after the rewire.

### Why active-low (and not the older idle-LOW circuit)

The previous wiring (v0.2.0 design — still in service on red and
green buttons) sent 3.3V down the cable to the button and pulled SIG
to GND through 10 kΩ at the Pi end. That topology was vulnerable to
EMI from adjacent switching loads: positive-going noise spikes
coupled onto the signal line briefly pulled it HIGH, and the
spike's dissipation back to LOW produced a falling edge that fired
the ISR without a real press. The fix is documented in
`photobooth/BACKLOG.md` → "Spurious capture — EMI on GPIO signal line".

### Known characteristic: release-bounce on long-hold

The active-low circuit has one cosmetic quirk: if a button is held
longer than 500 ms and then released, mechanical contact bounce as
the contacts separate produces an extra falling edge that registers
as a second `Button event` in the log. The original v0.2.0 wiring
did not exhibit this because the ISR fired on the natural release
transition (the only falling edge it could see).

Fix is software-side (queue flush after `_take_one_shot`) and lives
in `photobooth/BACKLOG.md` → "Release-bounce on long-hold-release".
Not a hardware concern.

---

## Status

| Button | Wiring | Validated |
|---|---|---|
| Shutter (blue) — GPIO 25 | v0.4.1 active-low | 2026-05-25 — 3.5 h idle, zero phantom triggers |
| Green — GPIO 23 | v0.2.0 idle-LOW (defective) | TODO — rewire pending |
| Red — GPIO 24 | v0.2.0 idle-LOW (defective) | TODO — rewire pending |

Promote this section from "rollout in progress" to "current" once
all three buttons are on the v0.4.1 design.

---

## ATX dummy load (in progress — value TBD)

The repurposed microATX PSU exhibits flutter on the 12V LED rail and
on the 5V neopixel rail during AC-removal shutdown, caused by the
PSU losing regulation as the rails collapse. Adding a fixed minimum
load to the 5V rail typically stabilizes ATX behavior during shutdown.

Attempts so far:

| Attempt | Resistor | Current @ 5V | Power dissipated | Flutter result |
|---|---|---|---|---|
| 1 | 220 Ω ¼ W (single) | 22.7 mA | 114 mW | Insufficient — flutter persists |

Next attempts (in order):
- Parallel 220 Ω ¼ W resistors to scale current safely: 2× → 45 mA,
  4× → 91 mA, 8× → 182 mA, each resistor still at 114 mW.
- If still insufficient: replace with a proper 10 Ω 5 W ceramic
  wirewound (500 mA continuous). Standard ATX dummy-load value.

Wired between 24-pin ATX connector pin 4 (+5V, red) and pin 5
(GND, black) — convenient because they're physically adjacent.
Resistor must NOT short the rail directly; it sits in series
between the two pins.

For a permanent installation: crimp the resistor leads into a small
female-header housing or solder onto a JST plug; do not leave bare
leads stuffed into the connector. Mount where airflow can dissipate
the heat (the resistor runs noticeably warm even within its rating).
