
# VRTouchEvents

SkyrimNet plugin for SkyrimVR touch and grab detection, pushed to the LLM so NPCs are aware of and react to being touched.

---

## ★ NEW IN V3.2

**Males are covered, end to end.** Chest contact never interrupts, whatever the dress state. Genital
contact is reported with erection state and position — *"brushing against his soft penis at the
middle"* — and never interrupts either. Male orifices are matched by capsule **name**, so they are
never read through the female map.

**The choke is a throat hold again.** It arms only on the **front** of the neck. A grab on the nape
is a neck hold and starts nothing — previously someone could be strangled from behind.

**A fourth delivery tier: persistent events.** Quiet contact is now *remembered* rather than
announced — the NPC can raise it later in conversation without the moment itself interrupting anyone.
Armoured and casual contact moved here, and many old interrupts became plain speech, so only
genuinely intrusive contact still cuts the room off.

**Scene suppression rebuilt.** It now listens for the scene **start and end events** that OStim and
SexLab broadcast, instead of only asking whether an actor is in an animating faction. A faction is
set partway through a scene's own startup — precisely when a touch is most likely to be narrated over
the top of it — and an interrupted teardown can leave it set afterwards. The old per-actor checks are
kept and OR-ed with the new signal, and the events reach the **base install**, so scene suppression
now works even if you install neither optional patch.

**A silent bug that predates V3.0 is fixed.** A race between PPB's two data streams was destroying
**short touches** outright — a quick grab on an arm or a foot often produced nothing at all, on
anyone. Long contact survived by luck. If touches have ever felt unreliable rather than *absent*,
this was why. (`CONNECTING_TO_PPB.md` section 3 has the mechanism.)

**Your own genitals are a touch source**, gated by PPB's own exposure check.

---

## ⚠ V3.0 IS A COMPLETE REWRITE — READ THIS FIRST

**V3.0 no longer uses CBPC for touch detection.** All sensing now comes from **Precision Physic Bodies (PPB)**, which reads the actual Havok collision bodies instead of CBPC collision spheres. CBPC and "More Haptics VR CBPC config" are **no longer requirements**, and V3.0 ships **no CBPC config files at all**.

What this buys you:
- **107 named body capsules** instead of ~17 nodes — "left cheekbone", "right forearm, wrist end", "upper glute", not just "face" and "arm".  
- **Both hands at once**, merged into ONE reaction instead of two.  
- **Real penetration depth**, so hovering, resting, pressing and going inside are all different things.
- **Weapons and held objects natively** — the weapon's actual name reaches the LLM.
- **Tails that actually work on equipped HDT-SMP tails**, which the V2 CBPC config silently could not do.
- No more CBPC config editing during install.

**What it costs you — this is important:**

> **PPB drives mapped races** — the human catch-all (which covers elves, orcs and most custom races), plus Argonian, Khajiit and Draenei, plus anything you add to PPB's `PPB_Skeletons_Added_Race.ini`.
>
> **Males are covered as of V3.2** (with PPB 2.0.0 or later) — this was the headline gap in V3.0/V3.1 and it is closed. **Children and creatures still produce no touch reactions**; they return as PPB's own coverage grows, with no update to this mod needed when it does.

Coverage is PPB's, not ours: this mod has no per-race or per-sex logic of its own, which is exactly why males needed no rewrite here — only decisions about what the new contacts should *mean*.

---

## V3.0 Requirements

**SkyrimNet** (and all of its own requirements)  
**VRIK** (https://www.nexusmods.com/skyrimspecialedition/mods/23416)  
**HIGGS** (https://www.nexusmods.com/skyrimspecialedition/mods/43930)  
**PLANCK** (https://www.nexusmods.com/skyrimspecialedition/mods/66025)  
**Precision Physic Bodies** (https://www.nexusmods.com/skyrimspecialedition/mods/186100) 


Optional, for the arousal + facial expression module:
**OSL Aroused Reborn** (https://www.nexusmods.com/skyrimspecialedition/mods/65454)  
**OR**  
**SLA Aroused NG** (https://www.nexusmods.com/skyrimspecialedition/mods/151502)  
**MFG Fix NG** (https://www.nexusmods.com/skyrimspecialedition/mods/133568?tab=files)  
Tested with OSL Aroused Reborn.  

⚠ **HIGGS is not optional even if you never grab anything.** PPB's whole detection loop is driven from a HIGGS frame callback, so no HIGGS means no touch detection — and it fails *silently*, with no error message. Same for VRIK, which PPB uses to tell a pointing finger from a fist from an open palm.

**Not required any more in V3.0:** CBPC, CBBE 3BA, More Haptics VR CBPC config. (PPB has its own requirements — check its page.)

### V2.0 Requirements (legacy)
**CBPC** — Physics and Collisions for SSE (https://www.nexusmods.com/skyrimspecialedition/mods/21224)  
**CBBE 3BA** (optional, I think) (https://www.nexusmods.com/skyrimspecialedition/mods/30174)  
**More Haptics CBPC VR config** (https://www.nexusmods.com/skyrimspecialedition/mods/40749)  
&nbsp;&nbsp;- This was the main mod V2 was built on. It is not a drop-in mod, it needs specific CBPC files edited.  
&nbsp;&nbsp;- I highly recommend removing the NPCEyeBone if you use MfgFix — it prevents NPC eye movement other mods want to use.  

---

## Installation

Install like any other mod. No settings needed, no config editing. Put it **below** all requirements in MO2, **above** them in Vortex.

Two optional patches are included — one for SexLab, one for OStim. They stop touch and grab events from firing during those scenes.

**As of V3.2 they are belt-and-braces rather than the only line of defence:** the base install now listens for the scene start/end events both frameworks broadcast, so suppression works without either patch. Keep them anyway — they add a per-actor check that also catches a scene whose *end* event never arrived.

---

## What it does

This is a VR-focused mod that turns physical contact between the player and an NPC into something the LLM knows about. It detects **which exact part of the body** was touched, **what the NPC is wearing at that spot**, **what touched them** (fingertip, palm, fist, grip, a weapon, a held object), **how hard**, and **for how long** — then tells SkyrimNet, and lets the NPC react in character.

Delays scale with what she is wearing and where you touched. A chest touch through heavy armor takes about 4 seconds of sustained contact before it registers as anything. The same touch on bare skin is reported immediately. No accidental boob touch without consequence in real life, same in VR.

### The narration is deliberately neutral

The mod tells the LLM **what happened, and nothing else**:

> *"Telord is pressing firmly into Carmella's chest (right breast) with their left palm, and brushing against Carmella's belly (navel) with their right fingertip, held for 4 seconds."*

It never says whether the touch was welcome, intimate, affectionate or violating. **That judgement belongs to the NPC**, and it is made by the LLM from her own personality, her history with you, and how she currently feels about you. A lover and someone who despises you get the exact same sentence from this mod and react completely differently — which is the entire point.

---

## How it works

PPB maintains real Havok collision capsules on driven NPCs and names all 107 of them. VRTouchEvents' SKSE plugin reads that stream every frame, decides which contact actually matters, merges both hands into a single interaction, and hands the result to Papyrus, which applies the delays, cooldowns and armor rules and composes the sentence.

**More specific always beats longer.** If your hand has been resting on her chest for two seconds and then slides onto her breast, the breast wins immediately — you do not wait out a new delay. The same applies going deeper: opening → inside → deepest each override the last, and only one reaction fires, at the deepest point reached.

**Both hands are one interaction.** Two hands on the same NPC produce a single reaction naming both, not two competing ones.

### Body parts

Around 28 reaction categories drawn from the 107 named capsules:

head, face, ear, lips, mouth, throat wall, neck, shoulder, chest, left breast, right breast, belly, waist, hips, backside, groin, clitoris, vaginal, cervix, uterus, anal, rectum, arms, hands, legs, feet, tail base, tail tip.

The LLM also receives the exact capsule underneath, so "her face" arrives as "her face (left cheekbone)". That extra precision is deliberate — it gives the LLM real context to react to.

### Armor

Detected states are **bare, clothes, light armor, heavy armor**. Bare and clothed touches state the garment; armor states the name of the piece being touched.

Slots probed: head (30), mask (44), hands (33), arms (34), feet (37), body (32), pelvis (49 and 52).

Two V3 corrections worth knowing:
- **Face gear now reads slot 44 then falls back to slot 30.** Vanilla Skyrim never uses slot 44, so in V2 every face touch read as bare even through a full helmet.
- **Interior contacts read the pelvis slots only, never the body slot.** In V2 a robe on slot 32 made the mod decide a real penetration was a detection error and throw it away.

### Cooldown

There is a 15-second global cooldown per NPC, so touching several places at once does not spam events. The first one to fire blocks the rest for that NPC.

**Interrupting contacts bypass it**: breasts and butt (bare or clothed), anything on the intimate ladder at any dress state, and choking. Those are considered important enough to stop whatever the NPC is doing.

### Tails

Khajiit and Argonian tails are touchable, split into **base / mid / tip** thirds. PPB detects the tail rig at runtime, so this works on **equipped HDT-SMP tails** — which V2 could not do, because its config was locked to specific race FormIDs and SMP renames armor-carried bones when they are equipped.


---

## CHOKING

Grab an NPC by the throat and it starts a choke. In V3 this arms from PPB's own neck capsule the moment it sees a grip on it, which is considerably more reliable than V2's method.

**Timeline while you keep holding:**

| time | what happens |
|---|---|
| 1s | pain sounds start |
| 2s | choking sound plays |
| 3s | fear builds in her head (unvoiced — she cannot speak) |
| **5s** | **she fights back.** Relationship ≤ 1 draws weapons; above that it is a fists-only brawl |
| **7s** | panic sets in, and bystanders who can see it react |
| **15s** | passes out, ragdolls, choking sound stops |
| **25s** | **dies**, if not protected or essential and you never let go |

Re-choking an NPC who is already unconscious kills her in **10 more seconds**.

**On release, depending on how long you held:**
- **under 1s** — nothing, no consequence
- **1 to 3s** — she is told you grabbed her throat and squeezed briefly
- **3 to 7s** — squeezed hard enough to hurt and stop her breathing
- **7 to 15s** — squeezed nearly to the point of blacking out

**Assault alarm:** from **7 seconds**, if her relationship with you is **1 or below** and someone actually witnessed it, guards and her faction are alerted. At relationship 2 or higher no alarm is raised — it reads as a serious fight between friends. **Choking while sneaking raises no alarm if you are never detected during it**, and the victim herself does not count as a witness. Let me know if that needs work, I have not tested it heavily.

A choked-out NPC stays down for **2 to 4 in-game hours**, at 50% health with no regeneration. A healing spell or potion wakes her early. **10 unconscious NPCs are tracked at once.**

She cannot talk while being choked — but she still notices. If your other hand grabs her while the first is on her throat, she registers that too.

---

## Weapons and held objects

Weapons and anything you are holding create contact events with the item's real name, so "he rested his Iron Rapier against her cheek" reaches the LLM as exactly that.

**Actual combat hits are filtered out.** If you have damaged her in the last 1.5 seconds, blade contact is treated as fighting, not touching, and no social reaction fires. A gentle blade rest deals no damage, so deliberate weapon-touch still works.

---

## Arousal and facial reaction

Touching intimate areas can affect arousal. Each one sends a query to the LLM asking how much arousal should change **and in which direction** — a touch from someone she dislikes goes negative — plus which expression fits. The expression is applied through MFG Fix NG, so if she is angry, surprised or happy, you can see it on her face.

This module is optional and off unless you install it and have an arousal backend.

---

## Warnings

**DO NOT remove the mod while NPCs are unconscious from choking.** Their state is tracked by a quest. Removing it mid-passout can leave them stuck unconscious, or without their health regeneration.

**No PPB, no mod.** If PPB is missing, broken, or its hand colliders are disabled, VRTouchEvents goes completely silent with no error. If nothing seems to be happening, check PPB first.

---

## DISCLAIMER

This is vibe coded with Claude Code. For real, Claude Code is fucking magical. I understand how the mod works and its mechanics, but I did not write the code — Claude did — so I am not certain how safe this is. I play with it on a very heavy load order: 2000 mods with physics, AI, fur shaders, the full CS suite, and I have had no issues. If you find a bug, let me know and I will see what I can do. If a real dev tells me this mod is dangerous, I will pull it down.

Anyway, hope you all enjoy it. I certainly enjoy petting M'rissi's tail.





---

## Source layout (this repository)

| path | what |
|---|---|
| `plugin/src/PpbBridge.cpp` | the SKSE plugin's PPB touch-API bridge — sessions, priority, both-hands merge, mod-event emit |
| `plugin/src/PpbTouchAPI.h` | **PPB's** consumer contract, copied verbatim (not ours) |
| `plugin/src/main.cpp` | plugin entry, install points, Papyrus natives |
| `scripts/*.psc` | Papyrus: the dispatcher, the reaction tables and narration builder |
| `scripts/gates/stub/` | the no-op gates the Base install ships |
| `scripts/gates/patches/` | the real gate implementations the FOMOD options install over them |
| `SkyrimNet/prompts/` | the arousal evaluation prompt |

As of V3.1 the mod ships **no trigger YAMLs** — every reaction is a direct SkyrimNet API call. See [CHANGELOG.md](CHANGELOG.md).

**[CONNECTING_TO_PPB.md](CONNECTING_TO_PPB.md) — how the PPB integration works**, written for anyone
building their own mod on the same API. Includes the mistakes that cost the most: the `AddTask`
deadlock, digest-vs-raw, the per-region handover that shreds a continuous touch, and the several
ways PPB can go silent with no error.

### Installing

**Download the packed FOMOD from [Releases](https://github.com/Telord72612/VRTouchEvents/releases)**
— that is the installer, and this repository is the only place it is published. Install it like any
other mod (MO2 or Vortex will read the FOMOD).

Compiled artifacts (`.dll`, `.pex`) are deliberately not tracked in git — they live on the Releases
page. To build from source: `plugin/build.bat` for the SKSE plugin, and Caprica or the CK compiler
for the Papyrus, against SkyrimNet, HIGGS, OSL Aroused and Mfg Fix.

## License

[MIT](LICENSE) — use it, fork it, copy pieces of it into your own mod. No attribution required,
though it is always appreciated.

The one file to be aware of is `plugin/src/PpbTouchAPI.h`: that is **Precision Physic Bodies'**
consumer contract, copied verbatim, and PPB's own documentation explicitly invites consumers to do
exactly that. Both mods share an author, so it ships under the same terms — but if you reuse it,
take it from PPB's repo so you get the current revision rather than this snapshot.
