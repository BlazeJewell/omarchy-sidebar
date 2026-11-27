# Audio meter

Live microphone and speaker levels as a split meter for Omarchy: **mic in** on one
side, **sound out** on the other.

- The filled part is the sound level right now (−60 dB empty, 0 dB full; the top
  segments turn red near clipping). The marker is the volume setting.
- **Scroll** a side to change its volume, **click** it to mute (muted sides are
  striped).
- Level in dB, volume in %, and the device name beside each bar (each can be
  turned off).

Options (`omarchy bar set`, or *Edit sidebar* › the section › Widget options in
jake.sidebar):

| Option | Values |
| --- | --- |
| `orientation` | `vertical` (two columns, mic left) · `horizontal` (two rows, mic on top) · `line` (one bar split in the middle: out fills left, in fills right; no device names) |
| `style` | `segments` · `solid` |
| `showNumbers` | level and volume numbers |
| `showDevice` | device names |
| `length` | vertical bar height, 40–240 px |

Levels come from PipeWire through Quickshell's peak monitor, only while the meter
is showing. A virtual microphone (no typed audio in Quickshell) gets volume and
mute through wpctl but no live level.

In jake.sidebar it's added as a section (*Edit sidebar* › + Add section › Audio
meter) and fits tightly, without the popup's padding (`tightInSidebar`).
