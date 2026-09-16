# VRTouchEvents

SkyrimNet plugin for SkyrimVR touch and grab detection, pushed to the LLM so NPCs are aware of and
react to being touched.

---

## ★ NEW IN V3.3

**Kissing.** Lips contact is its own reaction, and a kiss that slides from the lips down to the neck
is narrated as it travels.

**Push, shove, stumble and leg sweep.** Shove an NPC and she reacts to it — one line per fall, not
three, and the hand that did it is named.

**Equip / unequip awareness.** Put gear on an NPC by hand or pull it off and she knows:
*"Telord gently put Hide Boots on the feet of Carmella."* Stripping her main body slot is treated as
a significant moment and can end *"...leaving Carmella naked."* A piece that will not go on, or a
locked piece that will not come off, reaches her as awareness instead of silence. Ordinary armour,
ZaZ, Diary of Mine and Devious Devices all work the same way.

**Interrupts only cut the NPC who is actually talking.** Previously an interrupt cleared everyone's
speech queue, so reacting to a touch could cut off somebody else mid-sentence. Now the mod checks
whether *that* NPC is the one speaking, and if she is not, nothing is cut.

**An installer with real choices** — see below.

Older releases are in [CHANGELOG.md](CHANGELOG.md).

---

## The installer: two builds

The FOMOD's first page picks your touch system, and they are genuinely different mods.

**PPB (V3.3)** — the current mod, and what everything above describes. Touch is sensed by
[Precision Physic Bodies](https://www.nexusmods.com/skyrimspecialedition/mods/186100), which puts
real Havok collision capsules on the body and reports exactly where you touched, with what
(fingertip, palm, fist, grab, weapon, held object), how deep and for how long. Does not use CBPC at
all.

**CBPC (V2.1)** — the older build, for players who cannot run PPB. Coarser detection, and it has no
kissing, no pushes, no gear awareness and no Devious Devices handling. Tail and back contact were
removed in this release — CBPC could not support either reliably.

On the PPB build you then choose:

| option | default | what the other choice does |
|---|---|---|
| **How talkative is contact** | every held touch can earn a spoken reply | *Subtle contact* — a touch that passes quietly stays quiet, however long you hold it |
| **Push reactions** | narrated | silent (PPB still pushes her — only the narration stops) |
| **Gear awareness** | narrated | silent. **Pick this if you use Gift by Hand VR**, which can absorb gear you hold out to an NPC before the equip finishes |

Shared options: arousal + facial reactions (opt-in, costs LLM tokens), SexLab and OStim
scene-suppression patches, and "No Follower Grab".

---

## Requirements

**SkyrimNet** (and all of its own requirements)
**Precision Physic Bodies** — https://www.nexusmods.com/skyrimspecialedition/mods/186100
**HIGGS** — https://www.nexusmods.com/skyrimspecialedition/mods/43930
**VRIK** — https://www.nexusmods.com/skyrimspecialedition/mods/23416
**PLANCK** — https://www.nexusmods.com/skyrimspecialedition/mods/66025

⚠ **PLANCK is required, not recommended.** VRTouchEvents is built on top of it.

⚠ **HIGGS is not optional even if you never grab anything.** PPB's whole detection loop runs off a
HIGGS frame callback, so no HIGGS means no touch detection — and it fails *silently*, with no error.
Same for VRIK, which PPB uses to tell a pointing finger from a fist from an open palm.

Optional, for the arousal + facial expression module: **OSL Aroused Reborn** or **SLA Aroused NG**,
plus **MFG Fix NG**. Tested with OSL Aroused Reborn.

**The CBPC (V2.1) build instead needs** CBPC, a collision-enabled body (CBBE 3BA or equivalent), and
**More Haptics CBPC VR config** — that last one is required, because its CBPCollisionConfig additions
are what give you full-body collision. Without them CBPC only reports breast/belly/butt.

**Coverage is PPB's, not ours.** Mapped races — the human catch-all (which covers elves, orcs and
most custom races), plus Argonian, Khajiit and Draenei — and both sexes. Children and creatures
produce no touch reactions, and will return as PPB's coverage grows with no update needed here.

---

## What it does

It turns physical contact between the player and an NPC into something the LLM knows about: **which
part of the body**, **what she is wearing there**, **what touched her**, **how hard**, and **for how
long** — then tells SkyrimNet and lets her react in character.

Delays scale with what she is wearing and where you touched. A chest touch through heavy armour
takes about 4 seconds of sustained contact before it registers. The same touch on bare skin is
reported immediately. No accidental boob touch without consequence in real life, same in VR.

### The narration is deliberately neutral

The mod tells the LLM **what happened, and nothing else**:

> *"Telord is pressing firmly into Carmella's chest (right breast) with their left palm, and brushing
> against Carmella's belly (navel) with their right fingertip, held for 4 seconds."*

It never says whether the touch was welcome, intimate, affectionate or violating. **That judgement
belongs to the NPC**, and the LLM makes it from her personality, her history with you, and how she
currently feels about you. A lover and someone who despises you get the exact same sentence from this
mod and react completely differently — which is the entire point.

**More specific always beats longer.** A hand resting on her chest that slides onto her breast
reports the breast immediately; you do not wait out a new delay. The same going deeper — opening,
inside, deepest each override the last, and only one reaction fires, at the deepest point reached.

**Both hands are one interaction**, merged into a single reaction naming both.

There is a 10-second cooldown per NPC so several contacts at once cannot spam events. Intimate
contact and choking bypass it.

---

## Choking

Grab an NPC by the **front** of the throat and it starts a choke. A grab on the nape is an ordinary
neck hold and starts nothing.

| time | what happens |
|---|---|
| 1s | pain sounds start |
| 2s | choking sound plays |
| 3s | fear builds in her head (unvoiced — she cannot speak) |
| **5s** | **she fights back.** Relationship ≤ 1 draws weapons; above that it is a fists-only brawl |
| **7s** | panic sets in, and bystanders who can see it react |
| **15s** | passes out, ragdolls, choking sound stops |
| **25s** | **dies**, if not protected or essential and you never let go |

Re-choking an NPC who is already unconscious kills her in **10 more seconds**. On release she is told
what happened, graded by how long you held. From **7 seconds**, if her relationship with you is 1 or
below and someone actually witnessed it, guards are alerted — choking while sneaking raises no alarm
if you are never detected, and the victim does not count as a witness.

A choked-out NPC stays down for **2 to 4 in-game hours** at 50% health with no regeneration; a
healing spell or potion wakes her early. **10 unconscious NPCs are tracked at once.**

---

## Weapons and held objects

Weapons and anything you hold create contact events with the item's real name. **Actual combat hits
are filtered out** — if you have damaged her in the last 1.5 seconds, blade contact is fighting, not
touching. A gentle blade rest deals no damage, so deliberate weapon-touch still works.

---

## Warnings

**DO NOT remove the mod while NPCs are unconscious from choking.** Their state is tracked by a quest;
removing it mid-passout can leave them stuck unconscious or without health regeneration.

**No PPB, no mod.** If PPB is missing, broken, or its hand colliders are disabled, VRTouchEvents goes
completely silent with no error. If nothing seems to be happening, check PPB first.

---

## DISCLAIMER

This is vibe coded with Claude Code. For real, Claude Code is fucking magical. I understand how the mod works and its mechanics, but I did not write the code — Claude did — so I am not certain how safe this is. I play with it on a very heavy load order: 2000 mods with physics, AI, fur shaders, the full CS suite, and I have had no issues. If you find a bug, let me know and I will see what I can do. If a real dev tells me this mod is dangerous, I will pull it down.

Anyway, hope you all enjoy it. I certainly enjoy petting M'rissi's tail.

---

## Installing and building

**Download the packed FOMOD from [Releases](https://github.com/Telord72612/VRTouchEvents/releases)**
— that is the installer, and this repository is the only place it is published. Compiled artifacts
(`.dll`, `.pex`) are deliberately not tracked in git. To build: `plugin/build.bat` for the SKSE
plugin, and Caprica for the Papyrus, against SkyrimNet, HIGGS, OSL Aroused and Mfg Fix.

| path | what |
|---|---|
| `plugin/src/` | the SKSE plugin — PPB bridge, speech tracking, prompt state, reply counting |
| `plugin/src/PpbTouchAPI.h` | **PPB's** consumer contract, copied verbatim (not ours) |
| `scripts/*.psc` | Papyrus: the dispatcher, the reaction tables and the narration builder |
| `scripts/gates/stub/` | the gate version the **Base** install ships |
| `scripts/gates/patches/` | the version a **FOMOD option installs over it** |
| `SkyrimNet/prompts/` | the arousal prompt and the choke / recovery / wake blocks |
| `fomod/` | the installer definition |
| `legacy-cbpc/scripts/` | the Papyrus for the CBPC (V2.1) build |

⚠ The two gate folders are about *which install writes the file*, not about polarity. For arousal and
the scene patches the Base ships a no-op and the option installs the working version. For the three
V3.3 options it is the other way round — the Base ships the feature **on**, and the option installs
an off switch over it, so a manual install with no FOMOD keeps every feature.

**[CONNECTING_TO_PPB.md](CONNECTING_TO_PPB.md) — how the PPB integration works**, written for anyone
building on the same API. Includes the mistakes that cost the most: the `AddTask` deadlock,
digest-vs-raw, the per-region handover that shreds a continuous touch, and the several ways PPB can
go silent with no error.

## License

[MIT](LICENSE) — use it, fork it, copy pieces of it into your own mod. No attribution required,
though it is always appreciated.

The one file to be aware of is `plugin/src/PpbTouchAPI.h`: that is **Precision Physic Bodies'**
consumer contract, copied verbatim, and PPB's own documentation explicitly invites consumers to do
exactly that. Both mods share an author, so it ships under the same terms — but if you reuse it, take
it from PPB's repo so you get the current revision rather than this snapshot.
