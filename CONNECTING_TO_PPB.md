# How VRTouchEvents connects to the Precision Physic Bodies touch API

This is the part most people come here for, so it gets its own document. It is written for
somebody building a **different** mod on top of PPB, not just for reading this one.

Everything here is as-built and running — not a design sketch. The relevant files:

| file | what it is |
|---|---|
| `plugin/src/PpbTouchAPI.h` | **PPB's consumer contract.** Copied verbatim from PPB; not ours. Self-contained (FormIDs only, no CommonLib types) so any SKSE library can drop it in. |
| `plugin/src/PpbBridge.cpp` | Our whole integration: acquire, callback, coalescer, mod-event emit. ~700 lines, and the only file that talks to PPB. |
| `plugin/src/main.cpp` | Where it is installed, plus the scene-pause native. |
| `scripts/VRTouch_MainScript.psc` | The Papyrus side — `OnVRTEContact` / `V3Dispatch`. |

---

## 1. Acquiring the interface

The HIGGS/PLANCK request-reply pattern. Any time at or after `kPostLoad`; we do it at
`kDataLoaded`:

```cpp
PPBAPI::PpbMessage msg{};
SKSE::GetMessagingInterface()->Dispatch(
    PPBAPI::PpbMessage::kGetTouchInterface, &msg, sizeof(msg), "PPB");
if (msg.GetApiFunction)
    g_ppb = static_cast<PPBAPI::IPpbTouchInterface1*>(msg.GetApiFunction(1));
```

`GetApiFunction` null means PPB is not installed. `GetApiFunction(1)` null means it does not speak
revision 1. **Both are normal** — handle them and stay inert rather than crashing.

> ⚠ **Ordering bug worth avoiding:** set your global pointer *before* registering the callback, not
> after. We do it in the wrong order and a contact delivered during registration would be dropped by
> our own `if (!g_ppb) return` guard. Harmless in practice, trivial to get right from the start.

## 2. Digest vs raw — pick deliberately, they answer different questions

PPB ships two streams and this choice shapes everything downstream.

| | **digest** | **raw** |
|---|---|---|
| identity | (actor, wand, **region**) | (actor, wand, source class) |
| reports | the **longest-dwelt** capsule of the visit | the **current** capsule |
| access | callbacks + `GetContacts()` | `GetRawContacts()` — poll only |

**Use the digest unless you have a specific reason not to.** It is what you want ~95% of the time.

We use **raw**, because our headline rule is *"the more specific part wins the moment it is
touched"*: a hand resting on the chest for two seconds that slides onto a breast must report the
breast immediately. The digest structurally cannot do that — after two seconds of chest it still
says chest, and would need another two-plus seconds of breast before breast became the
longest-dwelt part. **That information is simply not in the digest stream**, so no amount of
consumer-side work recovers it.

The cost of raw is that you now own aggregation: windowing, priority, and deciding when a touch is
over. That is most of `PpbBridge.cpp`.

## 3. The hybrid that actually works: digest for *lifecycle*, raw for *content*

This is the single most useful thing in this repo.

```
digest callback  ->  kPhaseStart / kPhaseEnd  ->  "is this hand still on her?"   (authoritative)
GetRawContacts() ->  current capsule + depth  ->  "what exactly is it touching?" (one frame stale)
```

The raw snapshot is published *after* PPB emits, so it lags a frame. **Never let it decide that a
touch has ended** — it will lie at exactly the wrong moment. Let the digest's balanced
`Start`/`End` counter own the lifecycle, and use raw purely as data.

```cpp
if (phase == PPBAPI::kPhaseStart)      ++session.liveDigest[wand];
else if (phase == PPBAPI::kPhaseEnd)   --session.liveDigest[wand];
```

### ⚠ And then the trap: the digest is per-REGION

A wandering touch legitimately produces `End(regionA)` → ~0.26 s gap → `Start(regionB)` with the
hand never leaving the body. A hand resting on the belly flickers between `belly / navel` (region
Belly) and `lower abdomen` (region Waist).

We treated every `End` as "the hand left" and it **shredded one continuous 2.8-second touch into
0.25 s and 0.51 s fragments**, none of which reached our 1-second window, so nothing was ever
emitted. Detection looked completely broken while working perfectly.

The fix needs **both** conditions:

```cpp
const bool digestDone = (session.liveDigest[w] <= 0);
const bool rawStale   = (now - session.wand[w].lastSeen > 0.6);
if (digestDone && rawStale) session.wand[w].live = false;   // AND, never OR
```

The 0.6 s raw-recency window bridges the region handover. Related: emit **your session's**
accumulated duration, not PPB's per-contact `durationS` — a region handover restarts PPB's clock,
but the interaction has been going the whole time.

## 4. ★★ NEVER call `AddTask` from the touch callback

**This one hard-freezes the game**, and it cost two debugging sessions.

The callback runs here:

```
HIGGS AddPostVrikPostHiggsCallback -> PPB PerfSys -> PpbApi::OnFrame() -> Emit() -> your callback
```

— i.e. deep inside the game's frame update. `SKSE::GetTaskInterface()->AddTask()` from that context
takes the task-queue lock and **deadlocks the main thread**. No crash log, no exception, just a
frozen game.

`SendModEvent` from the same place is completely fine. PPB raises its own mod events from that exact
line and calls `AddTask` nowhere. **Do the work synchronously in the callback, exactly as PPB does.**

The diagnostic that pinned it, for anyone chasing something similar: the contact that *ended* during
its sweep emitted fine and the game ran on; the one that stayed *active* froze. Same function, same
`SendEvent` — the only divergence was downstream of the last log line. **Read the control flow after
the last thing logged, not the line itself.**

## 5. Loads and cell changes: guard them yourself

PPB drops live contacts on load without emitting `End` (deliberately — "no End events across a
load"). Mirror that rule, and note that **walking through a door fires neither `kPreLoadGame` nor
`kNewGame`**, so message-based resets are not enough:

```cpp
if (RE::UI::GetSingleton()->IsMenuOpen("Loading Menu")) { ClearSessionsSilently(); return; }
if (playerCellId != s_lastCellId) { ClearSessionsSilently(); s_lastCellId = playerCellId; }
```

Without the cell check we emitted a `ContactEnd` into a mid-load VM and got an infinite loading
screen in Whiterun. An `End` for an interaction that stopped because the worldspace changed carries
no information, so dropping it silently costs nothing.

## 6. Coverage — read this before you ship

**PPB drives female NPCs of mapped races only** (the human catch-all, which covers elves, orcs and
most custom races, plus Argonian, Khajiit, Draenei, plus user-added races). Males, children and
creatures answer `IsDriven() == false` and never appear in the stream.

**Never read absence of an event as absence of a touch.** Several host-side conditions produce total
silence with no error at all:

| cause | symptom |
|---|---|
| no HIGGS | PPB's `OnFrame` has exactly ONE call site — a HIGGS frame callback. No HIGGS, no tick, no events, **no error** |
| `apiTouch 0` | the snapshot *freezes* rather than emptying — stale contacts forever |
| hand colliders disabled | the API goes silent while PPB's **mouth gate keeps firing normally** — they use different probes |
| actor not driven | male/child/creature/unmapped race |

That third row is a genuinely useful discriminator: `MOUTHTOUCH` lines in `PPB.log` with zero API
contacts means the probes are off, not that your consumer is broken.

**Debugging:** set `contactLog = 1` in `SKSE/Plugins/PPB_Skeletons_Added_Race.ini` and PPB logs every
contact it detects to `My Games/Skyrim VR/SKSE/PPB.log`. That one line separates "PPB never saw it"
from "my handler is wrong" — which is otherwise very hard to tell apart.

## 7. Dwell is yours, not PPB's

PPB emits as soon as it knows (all `apiDwell*` gates ship at 0.25 s = one tick) and deliberately
leaves "what counts as a meaningful touch" to the consumer. Hover counts as contact at ~1 unit, so
**walking past someone in a corridor produces short contacts**.

Filter on `durationS` or your own per-part delay. Do **not** use a long per-NPC cooldown as the
filter — a doorway brush would then mute a deliberate touch two seconds later.

We layer a 1-second coalescer window on top, and only then a per-body-part delay table. Our Papyrus
side does not use a timer for that delay at all: an unmet delay parks the actor in a pending ring and
the next `ContactUpdate` re-tests it with a freshly *measured* duration. That is strictly better than
a deadline, and it costs zero `OnUpdate` wakeups when nobody is being touched.

---

## What we send to Papyrus

One mod event with 16 pipe-separated fields — both hands merged into a single interaction, since two
hands on one NPC should be one reaction and not two:

```
VRTE_Contact / VRTE_ContactUpdate / VRTE_ContactEnd
  sender = the touched NPC        numArg = duration in seconds
  strArg = W1|SRC1|NAME1|PART1|SUB1|DEP1|DIST1|W2|SRC2|NAME2|PART2|SUB2|DEP2|DIST2|SKEL|ESC
```

`'|'` inside a weapon or object name is replaced with `'/'` before packing, so no field can ever
contain the delimiter. Papyrus splits it with base-SKSE `StringUtil` only — no PapyrusUtil link.

Priority lives in a table keyed on PPB's `SubRegion` enum (uterus 100 … hair 6), and a strictly
higher priority re-emits **immediately** with `ESC=1` rather than waiting for the window. That is
what makes "breast overrides chest the instant it is touched" work.

---

*PPB's own modder guide is `INTEGRATION.md` in the Precision Physic Bodies repo, and it is worth
reading first — this document only covers what we learned building against it.*
