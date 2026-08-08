# Changelog

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
