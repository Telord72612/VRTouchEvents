# Changelog

## V3.2 — 2026-08-24

### Males are covered

Chest contact never interrupts, whatever the dress state. Genital contact is reported with erection
state and position — *"brushing against his soft penis at the middle"* — and never interrupts either.
Male orifices are matched by capsule **name** rather than by the classification fields, so they are
never read through the female map.

This needed no per-sex logic here. PPB 2.0.0 started driving male bodies and the existing routing
handled them; the only work was deciding what the new contacts should mean. Requires PPB 2.0.0
(build 20000) or later.

### The choke is a throat hold again

It arms only on the **front** of the neck. A grab on the nape narrates as a neck hold and starts
nothing. Previously someone could be strangled from behind by a hand on the back of their neck.

### A fourth delivery tier: persistent events

Quiet contact is now *remembered* rather than announced — the NPC can raise it later without the
moment itself interrupting anyone.

| tier | V3.1 | V3.2 |
|---|---|---|
| Speak (Interrupt) | 30 | ~16 |
| Speak | 38 | ~52 |
| Though | 34 | ~9 |
| **Persistent** | — | **~26** |

Armoured and casual contact moved to the new tier and many old interrupts became plain speech, so
only genuinely intrusive contact still cuts the room off.

### Scene suppression rebuilt

It now listens for the scene **start and end events** that OStim and SexLab broadcast, instead of
only asking whether an actor is in an animating faction.

A faction is set by a script partway through a scene's own startup — so there was a window where the
scene was running and the flag was not set yet, which is exactly when a touch was most likely to be
narrated over the top of it. An interrupted teardown could also leave it set afterwards.

The old per-actor checks are kept and OR-ed with the new signal, because the failure being fixed was
scenes **not** being suppressed; removing a signal could only make that worse. A 20-minute expiry
covers an `end` event that never arrives.

**The events reach the base install, so scene suppression now works without either optional patch.**
The patches remain worth installing — they add a per-actor check that catches a scene whose end event
was missed.

### ⛔ Short touches were being destroyed — a bug that predates V3.0

A race between PPB's two data streams. A session is created by the digest, but populated from the raw
snapshot, which lags a frame — so immediately after creation there is legitimately no raw entry, and
the sweep read that as "the contact is over" and destroyed the session on its first tick, while the
digest still said a hand was on the actor.

**Short touches died outright; long ones survived only by luck.** Ten kills in a single measured
session. If touch has ever felt unreliable rather than *absent*, this was why.

`CONNECTING_TO_PPB.md` section 3 has the mechanism and the rule that prevents it, for anyone building
their own PPB consumer.

### Also

- The player's own genitals are a valid touch source, gated by PPB's exposure check.
- Under-jaw contact no longer scores high enough to bypass both cooldown clocks (it maps to *face*).
- A genital-source contact carries a priority floor so it cannot be silently evicted by an idle hand
  elsewhere on the same actor.
- `CONNECTING_TO_PPB.md` substantially expanded: priority and arbitration, upstream verdicts that
  answer their own question, fields that are meaningless for your source, and the frame-callback
  re-entrancy rule that goes wider than `AddTask`.


## V3.1 — 2026-08-08

### ⚠ If you are on V3.0, most spoken reactions are silent. This release fixes that.

**SkyrimNet's TriggerManager stopped evaluating events.** Not a VRTouchEvents bug and nothing in
V3.0 could work around it: 30 triggers loaded from several mods, the event-type index built, the
processing loop started, and then **zero events evaluated in 45 minutes**. Our events were accepted
and filed into scene context — they just never reached a trigger.

Because the mod delivered spoken reactions *through* trigger YAMLs, that killed **68 of the 105
rows** in the trigger schema at once. Unvoiced thoughts kept working, and so did the choke, because
both use direct API calls. That asymmetry is what gave the cause away.

**Fix: every reaction is now a direct API call. No trigger, no YAML, no event matching.**

| tier | before | now |
|---|---|---|
| Though | `GenerateNPCThought` | unchanged |
| Speak | event → trigger YAML → `direct_narration` | **`DirectNarration`** |
| Speak (Interrupt) | as above + YAML `interrupt: true` | **`TriggerInterruptDialogue` + `DirectNarration`** |

Audience control is native to the API (`targetActor`), so the pass-through YAMLs are gone. The mod
now ships **no trigger YAMLs at all** and is immune to whatever broke the trigger system.

### Two-tier per-NPC cooldown

Interrupt contacts used to bypass the cooldown entirely, so holding a hand on an intimate area could
queue a request per second — the LLM never finished an answer and the net result was *no* reaction.

Now there are two clocks:

- **Speak** consults the normal clock.
- **Speak (Interrupt)** consults its **own** clock only — it cuts through an ordinary reaction but
  can never spam itself.
- **Escalations bypass both.** Going opening → cervix → uterus is new information, not a repeat.
  This is not a spam hole: the plugin only flags an escalation when sub-region priority *strictly
  increases* within a session, and priority is capped, so a session can escalate a few times, only
  upward, and never twice at the same depth.
- **Thoughts are exempt in both directions** — not gated, and they don't gate anything else.
  Brushing an arm no longer silences a grope three seconds later.

### Choke

- **Passout is narrated again.** It was the last event still routed through the dead trigger path,
  so it had gone completely silent.
- **Release forces its reaction and ignores the 15 s cooldown**, so a 9-second choke always gets its
  gasping reply.
- **The 3 s fear-thought is removed.** SkyrimNet allows one thought per NPC per 60 seconds
  (`NpcThoughts.yaml`), so the 3 s thought always spent the budget and **the 7 s panic-thought had
  never once reached the LLM.** The single slot now goes to the later, more desperate line. Nothing
  is lost under 7 s — a short choke still gets its full release narration.
- Removed a duplicate in the release path that burned the same thought budget on text the narration
  was already speaking.

### Cleanup

`FireTrigger` and everything only it used are gone: the V2 cooldown ring, `IsOnNpcCooldown`,
`RecordCdFire`, `FindCdSlot`, `WeaponStateStr`, and the `vrtouch_event` / `vrtouch_weapon` /
`vrtouch_weapon_alert` schemas. All three trigger YAMLs deleted. Compiled script is ~11% smaller.

### Known limitations

- `TriggerInterruptDialogue` and `PurgeDialogue` are **global** in SkyrimNet — there is no per-actor
  speech stop, so an interrupt also cuts a bystander mid-line. Only the 30 interrupt rows use it.
- The 25 s lethal choke is still unverified in play.

---

## V3.0 — 2026-08-02

Complete rewrite of the sensor. Touch detection moved from CBPC to
**[Precision Physic Bodies](https://www.nexusmods.com/skyrimspecialedition/mods/186100)**, which
reads the actual Havok collision bodies.

- **107 named capsules** instead of ~17 nodes — the LLM is told "left cheekbone" or "right forearm,
  wrist end", not just "face" and "arm".
- **Both hands merged into one reaction** instead of two competing ones.
- **Real penetration depth** — hover, rest, press and inside are different things.
- **Weapons and held objects** reported natively with the item's real name, and actual combat hits
  filtered out so fighting an NPC doesn't narrate as touching her.
- **Tails work on equipped HDT-SMP tails**, which the V2 config silently could not do.
- **Narration is purely factual** — it states what was done, where, with what and how hard, and
  never tells the NPC how to feel about it. The same touch from a lover and from someone who
  despises you produces completely different reactions, decided by the LLM.
- Armor fixes: face gear no longer reads as bare through a helmet; intimate contact is no longer
  discarded through a robe.
- **Ships no assets** — no meshes, no skeletons, no physics configs, no CBPC files. Cannot conflict
  with your body/skeleton/physics setup.

**Coverage change:** PPB drives female NPCs of mapped races only. Males, children and creatures
produce no touch reactions in V3. They return as PPB's coverage grows, with no update needed here.
