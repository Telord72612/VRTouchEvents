# How VRTouchEvents connects to the Precision Physic Bodies touch API

This is the part most people come here for, so it gets its own document. It is written for
somebody building a **different** mod on top of PPB, not just for reading this one.

Everything here is as-built and running — not a design sketch. **Updated for PPB 2.0.0
(build 20000) and VRTouchEvents V3.2** — if you integrated against 1.4.x, sections 2b, 6, 8 and 9
all changed.

The relevant files:

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

### ⚠⚠ The same rule, violated one branch away — and it cost the most of anything here

We wrote "never let raw decide that a touch has ended" above, implemented it in the wand-clearing
path, **and then wrote a second teardown fifteen lines below that did exactly what the rule
forbids.**

A session is created by a digest `Start`. The raw snapshot lags a frame, so immediately after
creation there is legitimately no raw entry — and our sweep read that as "nothing here" and destroyed
the session on its very first tick:

```
End with NO raw contact ever merged | liveDigest=[1,0] sweeps-since-open=1 age=0.00s
```

Ten of those in one session, while the digest was still saying a hand was on her. **Short touches
died outright; long ones survived only by luck**, when a later digest `Start` happened to arrive
after raw had caught up. It presented as flaky detection in PPB and was ours for months.

★ **If any branch of your code refuses to trust the lagging signal, EVERY branch that ends the same
object must refuse it too.** Otherwise the teardown wins and the check above it is decoration. Give
raw a grace period — two seconds is generous and costs nothing — before concluding anything from its
absence.

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

### ⚠ The rule is wider than `AddTask`: do not re-enter the frame owner either

`AddTask` is the sharp edge, but the general shape is **anything that calls back into whatever owns
the frame you are running inside.** Our contact handling lives inside HIGGS's frame update, and we
later hung the game a second way: unequipping an item and immediately asking HIGGS to grab it, at the
exact moment HIGGS was tearing down a grab on that same hand.

No crash log, no exception — the log simply stops mid-gesture, one line after the last thing that
worked.

**Defer engine calls that mutate inventory or equipment by one frame**, into your own pending-work
struct that a later tick drains. It costs a frame and removes an entire class of hang. (Deferring
via `AddTask` is exactly the thing that freezes, so this must be your own struct, not the task
queue.)

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

> ⚠ **THIS SECTION CHANGED IN PPB 2.0.0.** If you read an older copy of this document: males are
> now driven. Do not ship the old assumption.

**PPB drives mapped races** — the human catch-all (which covers elves, orcs and most custom races),
plus Argonian, Khajiit, Draenei, plus user-added races. **Males are covered as of 2.0.0**; children
and creatures answer `IsDriven() == false` and never appear in the stream.

★ **Feature-detect on `GetBuildNumber()`, not on behaviour.** `>= 20000` is 2.0.0. And design so that
a coverage expansion upstream is a *content* decision for you rather than a code change:
VRTouchEvents has no per-race or per-sex logic of its own, so when PPB started driving males the only
work on our side was deciding what the new contacts should mean.

⚠ **A contact does not carry a sex field.** Resolve it yourself if you need it, once per dispatch.
And be aware that some stamped fields were derived from the female map on male bodies in early 2.0.0
builds — we defend by matching capsule **names** on males rather than trusting the classification
fields. Check the current behaviour before relying on those fields for a male.

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

## 8. ★ Priority and arbitration are YOURS

PPB answers exactly one question: *a contact happened, here, with this, this deep, for this long.*
Everything after that — which contact matters when two arrive at once, how long one must last to be
worth acting on, whether it outranks another — is the consumer's judgement. Write it in your own
code, where you can change it without waiting on anyone.

The user this mod was built for put it better than we did:

> *"Priority is our business. PPB reports touch, we decide which one is priority. If PPB reports
> clitoris .25 sec 20 times because the finger is shaking, it's a touch and we make it the
> priority."*

That second sentence is also a design brief: **fragmentation must not be able to demote a contact.**
Twenty quarter-second fragments of one touch are one touch. Our session only retires after a real gap
of silence and keeps the highest priority seen inside the window, so a shaking finger cannot downgrade
itself.

## 9. ⚠ An upstream verdict answers its own question, not yours

PPB's orifice sensor tells you whether something is *inside an opening*, and it is right about that.
We consumed it as though it answered *"what is this object being placed on"*, which it does not.

A large held object overlaps interior sensors as well as the surface capsule it is really touching —
so the moment PPB called one of those an orifice, our contact collapsed to `mouth`-only or
`vaginal`-only, and anything wanting a different site was refused. A blindfold brought to the face
became a mouth contact. An armbinder held at the wrist became an anal one.

**Take a specific verdict only when its question is the one you are asking.**

⚠ And when you fix something like this, **check whether a second path reaches the same wrong
answer.** We fixed the orifice verdict and left an equivalent child-index map untouched a few lines
below, so the bug survived its own fix and returned the next day wearing a chastity belt.

## 10. ⚠ Fields that are meaningless for your source

`wand` is the player's hand — `0` right, `1` left. **It is meaningless for any source that is not a
hand**, and it reads `0`. We published every player-genital contact as coming from the right hand for
a full session because `wand` was read unconditionally. **Switch on `sourceKind`, never on `wand`**,
and give non-hand sources their own identity downstream rather than letting them inherit a lie.

Related: a source reporting `wand = 0` **occupies the same slot as the right hand** in any
two-slot-per-actor model. If both are live on one actor, one loses. That arbitration is yours to
design (see section 8), not a PPB bug.

**And zero often means "no longer known", not "unchanged".** The erection level in `_reserved[0]` is
written on *every* contact including the zero — a `0` mid-stream means PPB no longer knows. We only
harvested it when non-zero, so once cached it stuck, and we would have narrated a stale state
indefinitely. Assume the same shape for any future field arriving in a reserved byte: **write what
you are told, including the absence.**

## 11. When you think it is PPB

Twice we were certain. Once we were right.

**Right:** the male genital chain was genuinely unreachable — a loop bound made one branch
unreachable unless you also enabled hair targeting, which the header separately warns against. Filed
with the file, the line, the one-line fix, and evidence our side was already wired and waiting.
**Fixed the same day.**

**Wrong:** the short-touch failures were our own raw-lag race (section 3), and a confident three-session
theory that "the shaft loses the nearest-capsule race" was a wrong inference from two true
observations — PPB's bend-level logging climbed while the touch API stayed silent, because one uses a
radius test on the rig and the other uses a scan that did not include the rig. **A signal from one
subsystem does not prove another saw the same thing.**

What settled both was the same discipline: **instrument the silent path first.** Our `p < 0`
early-return was commented *"shouldn't happen"* and returned without a word. One log line there
separated *"PPB never sent it"* from *"we never looked"* — and answered both questions on the next
run, one of them against us.

★ **A silent early-return marked "shouldn't happen" is a bug you cannot diagnose.** Log every path
that discards data, at your default level.

**What made our PPB reports cheap to act on:** the file and line rather than the symptom; evidence the
consumer side was already correct; the proposed one-line change and why the surrounding code already
supported it; and an explicit statement of what we were **not** asking for — in that case, that we
were not asking PPB to re-rank anything, only to scan a chain at all.

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
