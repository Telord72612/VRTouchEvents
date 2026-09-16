#include "PCH.h"
#include "PpbBridge.h"
#include "PpbTouchAPI.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>

namespace logger = SKSE::log;

namespace {
    // ── The V3 mod-event contract (C++ -> Papyrus) ─────────────────────────────
    //   eventName : "VRTE_Contact"       — first emit for a session, or an
    //                                      escalation re-emit (ESC field = "1")
    //               "VRTE_ContactUpdate" — once per ~1 s while the session lives,
    //                                      after the first emit
    //               "VRTE_ContactEnd"    — session over
    //   sender    : the touched NPC (Form)
    //   numArg    : the SESSION's duration in seconds (on End: its total live duration)
    //
    // ★★ 2026-09-13 — FOUR SOURCE LANES, ONE LINE PER NPC (the user's ruling). The old contract was
    // 16 fields and two slots indexed by PPB's `wand` (0 right / 1 left). PPB reports the player's
    // HEAD and GENITAL with wand = 0 too, so they fought the right hand for one slot and the loser was
    // DROPPED every sweep: a kiss on her neck vanished while the right palm rested on her breast. The
    // user: "if both hand, genital and head all touch at the same time ... VRTE simply see all four and
    // publish that information". Each source now has its own lane, and every live lane rides one event.
    //
    //   strArg    : EXACTLY 35 pipe-separated fields; '|' inside a name is replaced with '/':
    //      0 ESC    "0" first emit / update / end · "1" escalation (priority rose) · "2" a lane JOINED
    //      1 SKEL   "human"/"argonian"/"khajiit"/"draenei" (the first clause's)
    //      2 N      number of clauses, 1..4
    //      then FOUR clauses of 8 fields at 3 / 11 / 19 / 27, unused = "". Highest priority first - EXCEPT on
    //      ESC "1" / "2", where clause 0 is the lane that CAUSED the event (the one that escalated or joined):
    //      ESC applies to clause 0 alone.
    //        +0 W     "R" / "L" (a hand lane) · "H" head · "G" genital
    //        +1 SRC   FINGER/PALM/FIST/HAND/GRAB/WEAPON/OBJECT/GENITAL/HEAD
    //        +2 NAME  weapon/object name · "shaft"/"tip" · "face"/"head"/"mouth" · else ""
    //        +3 PART  capsule name as PPB reports it ("BREAST R", "chest ring")
    //        +4 SUB   sub-region NAME from SubRegionName() ("Breast", "In mouth")
    //        +5 DEP   depth 0-3 (SubRegionDepthLevel)
    //        +6 DIST  deepest distU on the CURRENT part, "%.2f"
    //        +7 DUR   this LANE's own hold in seconds, "%.2f" (a hand that joined late has its own clock)
    // ⛔ Papyrus splits this with a FIXED 35-field splitter that keeps empty fields in place
    //   (VRTouch_MainScript.V3Split35). Change the count here and there together, or every field shifts.
    // ★ A lane TAKEN by a push reaction (TakePushContact) is left out of every Contact / Update for kPushTakeS:
    //   the push line already says what the hand did. (The End snapshot still lists it; Papyrus ignores it.)
    constexpr const char* kEvContact = "VRTE_Contact";
    constexpr const char* kEvUpdate  = "VRTE_ContactUpdate";
    constexpr const char* kEvEnd     = "VRTE_ContactEnd";

    // ── Tunables (the user's rules; see the header banner) ─────────────────────
    constexpr double kSweepMinGapS  = 0.2;   // min gap between sweeps (callback tick guard)
    constexpr double kWindowS       = 1.0;   // uniform coalescer window on first contact
    // ★ BREAST FAST PATH (2026-09-03). kWindowS above is the user's 2026-07-31 ruling
    // ("uniform ~1 s window, NO instant-bypass carve-out") and it REMAINS the default for
    // every other part of the body. It is also the single largest contributor to "breast
    // touch is way late": PPB's answer to VRTE_API_Change_Request_BreastTouchReach put it
    // at 1.0 s of a ~1.5 s budget and handed this row to VRTE. The spec sheet gives breast
    // bare/clothes dwell 0.0 s -- "instant" -- which a 1.0 s window makes structurally
    // UNREACHABLE, so the sheet and the architecture disagreed until now.
    // ★ 0.25 and not 0, deliberately: PPB's own apiDwell* is 0.25 s, so a breast contact
    // cannot EXIST any sooner. This window simply stops ADDING to that floor -- it does not
    // defeat PPB's spam filter, which stays the guard against brush events.
    // ⚠ Scope note: this keys on kSubBreast, and a MALE's spine2 C11/C12 are dialled CHEST
    // capsules that share the "BREAST R/L" name (VRTE maps them to `chest`). PPB gated its
    // touch pad to females; the bridge has no sex signal, so a male chest contact also gets
    // the short window. Harmless -- it narrates sooner, same tier -- but know it is wider
    // than PPB's pad.
    constexpr double kWindowBreastS = 0.25;
    constexpr double kUpdatePeriodS = 1.0;   // VRTE_ContactUpdate cadence
    constexpr double kWandStaleS    = 0.6;   // wand entry unseen this long -> cleared
                                             //   (also bridges PPB's region-handover gap:
                                             //    End(regionA) .. ~0.26 s .. Start(regionB))
    // ⛔ THE RAW-LAG GRACE (2026-08-23). A session is created by a digest Start,
    // but Pass A reads the RAW snapshot, which this file already documents as
    // "one frame stale". So for the first sweep (or few) after creation there is
    // legitimately NO raw entry yet — and Pass C's `PickPrimaryLive(s) < 0` used
    // to read that as "the touch is over" and destroy the session on the spot,
    // WHILE liveDigest still said a hand was on her. Measured 2026-08-23: ten
    // kills in one session, every one at `age=0.00s sweeps-since-open=1`,
    // including a 10.03 s palm on a male's chest that never reached Papyrus.
    // Short touches died outright; long ones only survived because a LATER Start
    // happened to arrive once raw had caught up.
    // While the digest says a hand is on her, wait this long for raw to appear.
    constexpr double kRawGraceS     = 2.0;
    // ★ 2026-09-02 — PPB's RAW stream applies its OWN dwell filter before a contact
    // ever reaches GetRawContacts(). Every apiDwell* class ships at 0.25 s and
    // PPB_tuning.txt states the intent outright: "PPB's dwell is a spam filter, not a
    // semantic gate; VRTE (the consumer) owns [the semantic dwell]". So a probe that
    // never lingers 0.25 s on ONE capsule group is legitimately absent from raw, and a
    // brush produces a digest lifecycle with nothing behind it. This mirrors PPB's
    // number so the "no raw merged" log can tell an EXPECTED brush from a real fault.
    // ⚠ If PPB ever retunes apiDwell*, this only affects log wording, never behaviour.
    constexpr double kPpbRawDwellS  = 0.25;
    constexpr double kSessionRetireS = 1.5;  // a lingering dead session older than this is
                                             //   retired when a NEW touch on that actor starts
    constexpr int    kMaxSessions   = 8;     // session cap (LRU-evict oldest, End emitted)
    constexpr int    kRawBufMax     = 32;    // GetRawContacts buffer
    // ★ 2026-09-13 source lanes: 0 right hand · 1 left hand · 2 the player's HEAD · 3 the player's GENITAL.
    constexpr int    kLanes         = 4;
    constexpr int    kLaneHead      = 2;
    constexpr int    kLaneGenital   = 3;
    constexpr int    kClauseFields  = 8;
    constexpr int    kPayloadFields = 3 + kLanes * kClauseFields;   // 35
    // A push reaction may arrive just after the pushing hand left her: a contact seen this recently still
    // counts as the one that did it (TakePushContact).
    constexpr double kPushRecentS   = 1.5;
    constexpr unsigned int kPlayerFormId = 0x14;

    // One-line sweep/update debug (compile-time; keep false for shipping — the
    // Contact/End emits are logged unconditionally, they're low-rate).
    constexpr bool kSweepDebug = false;

    PPBAPI::IPpbTouchInterface1* g_ppb = nullptr;

    double NowS() {
        return std::chrono::duration<double>(
                   std::chrono::steady_clock::now().time_since_epoch()).count();
    }

    // ── THE PRIORITY TABLE — keyed on the SubRegion ENUM from PpbTouchAPI.h ───
    // Priority overrides duration: the more specific part wins the moment it is
    // touched. Values per the confirmed table; unknown/none = 5.
    int PriorityOf(int subRegion) {
        switch (subRegion) {
        case PPBAPI::kSubVaginalDeepest:  return 100;  // uterus
        case PPBAPI::kSubVaginalDeep:     return 90;
        case PPBAPI::kSubAnalDeep:        return 90;
        case PPBAPI::kSubMouthWall:       return 85;
        case PPBAPI::kSubVaginalOpening:  return 80;
        case PPBAPI::kSubAnalOpening:     return 80;
        case PPBAPI::kSubInMouthDeep:     return 35;   // ★ 2026-08-23: was 78. This capsule
                                                       // (under-jaw 3.11) MAPS TO FACE in
                                                       // Papyrus (report 21 A6) — at 78 it
                                                       // could fire esc=1 and bypass both
                                                       // cooldown clocks for a face touch.
                                                       // Now sits with kSubFaceSurface.
        case PPBAPI::kSubInMouth:         return 75;
        case PPBAPI::kSubIntimateExternal:return 70;   // clitoris
        case PPBAPI::kSubOrificeRing:     return 60;
        case PPBAPI::kSubMouthOpening:    return 55;   // lips
        case PPBAPI::kSubBreast:          return 50;
        case PPBAPI::kSubGlute:           return 50;
        case PPBAPI::kSubNeck:            return 45;
        case PPBAPI::kSubHeadEar:         return 40;
        case PPBAPI::kSubFaceSurface:     return 35;
        case PPBAPI::kSubShoulderCap:     return 30;
        case PPBAPI::kSubShoulder:        return 30;
        case PPBAPI::kSubPelvis:          return 25;
        case PPBAPI::kSubBelly:           return 20;
        case PPBAPI::kSubWaist:           return 20;
        case PPBAPI::kSubTailBase:        return 16;
        case PPBAPI::kSubTailMid:         return 16;
        case PPBAPI::kSubTailTip:         return 16;
        case PPBAPI::kSubRibCage:         return 15;
        case PPBAPI::kSubHead:            return 15;
        case PPBAPI::kSubThigh:           return 12;
        case PPBAPI::kSubUpperArm:        return 10;
        case PPBAPI::kSubForearm:         return 10;
        case PPBAPI::kSubPalm:            return 10;
        case PPBAPI::kSubCalf:            return 8;
        case PPBAPI::kSubFoot:            return 8;
        case PPBAPI::kSubHair:            return 6;
        default:                          return 5;    // kSubNone / unknown
        }
    }

    // ★ MALE UPDATE (2026-08-23): contact-level priority. The male genital chain
    // reports through pseudo-slot kSlotGen=102 with subRegion=kSubNone (PPB has
    // no GEN sub-region enum yet), so PriorityOf(subRegion) alone scored a male
    // genital touch 5 — the absolute bottom, below hair. It loses the wand-slot
    // contest to ANY simultaneous body contact. Slot-aware wrapper: GEN sits at
    // the external-intimate tier (70, same as clitoris).
    int PriorityOfContact(const PPBAPI::PpbTouchContact& c) {
        if (c.slot == PPBAPI::kSlotGen) return 70;
        const int p = PriorityOf(c.subRegion);
        // ★ GENITAL-SOURCE PRIORITY FLOOR (user, 2026-08-23).
        //
        //   "Priority is our business. PPB reports touch, we decide which one is
        //    priority. If PPB reports clitoris .25 sec 20 times because the finger
        //    is shaking, it's a touch and we make it the priority."
        //
        // PPB sends `wand = 0` for a genital contact because it is not a hand
        // (INTEGRATION.md: "wand is meaningless and reads 0"). That puts it in the
        // SAME session slot as the player's RIGHT HAND, so without a floor an idle
        // right hand resting on her face (35) silently evicted a genital contact on
        // her hip (25) — the contact hardest to line up in VR losing to the easiest.
        //
        // The floor is a floor, not an override: a genital contact that lands
        // somewhere genuinely deeper keeps that higher number (uterus stays 100).
        // 70 = the external-intimate tier, the same value the GEN chain itself
        // carries — so it outranks ordinary body contact without ever outranking
        // the intimate ladder.
        if (c.sourceKind == PPBAPI::kSourceGenital && p < 70) return 70;
        // ★ PLAYER-MOUTH PRIORITY FLOOR (user, 2026-09-12): "make sure the lips contact are another node
        // that can be sent to the NPC from the player, same rule as the genital". It was first added because
        // PPB reports HEAD with wand = 0 and a right palm on her breast (50) evicted a kiss on her neck (45).
        // ★ 2026-09-13: the head and the genital have their OWN lanes now, so neither can be evicted by a
        // hand any more. Both floors stay for what is left of them: ORDER (a kiss or a genital contact is
        // named first in the combined line) and ESCALATION (joining a hand session below 70 re-sends it as
        // new, clock-bypassing information) - the genital's rule, which the user asked the mouth to share.
        // Only the MOUTH label: "face" / "head" (leaning in, a headbutt) keep their body-part priority.
        if (c.sourceKind == PPBAPI::kSourceHead && p < 70 &&
            std::string(c.sourceName, strnlen(c.sourceName, sizeof(c.sourceName))) == "mouth")
            return 70;
        return p;
    }

    // ★ ERECTION-LEVEL CACHE (2026-08-23). PPB tracks a per-male bend level
    // (GENBEND, 0..genBendMax) but does not expose it through the API yet — the
    // handoff request (Report/VRTouchEvents Module/24, PPB-request section) asks
    // for `_reserved[0] = genLevel + 1` on every contact whose touched actor is
    // male. The reserved tail is contractually ZERO today, so on the current PPB
    // this reads 0 → cache never fills → Papyrus GetErectionLevel returns -1 and
    // the narration simply omits the erection clause. When PPB ships the byte it
    // lights up with no rebuild on either side. Values are sanity-capped at 10.
    struct GenLevelEntry { std::uint32_t fid = 0; int level = -1; };
    GenLevelEntry g_genLevel[16];
    // ⚠ level == -1 means UNKNOWN and must be RECORDED, not ignored — see the
    // caller. It never ALLOCATES on -1 though: an unknown level is the default
    // answer anyway, so letting every female in the scene claim a cache slot
    // would evict the males we actually care about.
    void NoteGenLevel(std::uint32_t fid, int level) {
        int free_ = -1;
        for (int i = 0; i < 16; ++i) {
            if (g_genLevel[i].fid == fid) { g_genLevel[i].level = level; return; }
            if (free_ < 0 && g_genLevel[i].fid == 0) free_ = i;
        }
        if (level < 0) return;                          // unknown + not cached = nothing to say
        if (free_ < 0) free_ = 0;                       // overwrite slot 0 — 16 males in
        g_genLevel[free_] = { fid, level };             // one session is already absurd
    }

    // ── Session state ──────────────────────────────────────────────────────────
    // One live touch interaction per NPC. Each wand slot holds the CURRENT
    // capsule (raw stream resolves one contact per (actor, wand, source class);
    // GRAB wins a contested wand slot, then priority).
    struct WandEntry {
        bool          live        = false;  // seen within kWandStaleS
        bool          everSeen    = false;  // snapshot below is valid (End uses it)
        int           slot        = 0;
        int           child       = 0;
        unsigned char leftTwin    = 0;
        unsigned char sourceKind  = 0;      // PPBAPI::SourceKind
        int           subRegion   = 0;      // PPBAPI::SubRegion
        int           depth       = 0;      // PPBAPI::SubRegionDepthLevel
        int           priority    = 0;      // PriorityOf(subRegion)
        float         distDeepest = 0.0f;   // most negative distU on the CURRENT part
        float         durationS   = 0.0f;   // PPB's per-contact duration (numArg)
        double        lastSeen    = 0.0;
        double        laneStart   = 0.0;    // when this lane's touch began (clause DUR) - its digest Start
        char          bodyPart[48]   = {};
        char          sourceName[48] = {};
        char          skeleton[12]   = {};
    };

    struct Session {
        bool          active          = false;
        std::uint32_t fid             = 0;
        WandEntry     wand[kLanes];          // index = LaneOf(contact): 0 R hand, 1 L hand, 2 head, 3 genital
        WandEntry     windowBest[kLanes];    // best capsule seen PRE-EMIT (rule 2: a transient
                                             //   high-priority part must survive a downgrade)
        int           liveDigest[kLanes] = {0, 0, 0, 0};  // PPB digest Start/End balance per lane — the
                                             //   AUTHORITATIVE "is this source still on her"
        double        startTime       = 0.0;
        double        windowDeadline  = 0.0; // startTime + kWindowS
        int           emittedPriority = -1;  // -1 until the first VRTE_Contact
        unsigned      emittedMask     = 0;   // lanes named in the last VRTE_Contact (a new one = a JOIN)
        int           emittedPri[kLanes]      = {-1, -1, -1, -1};  // per lane: priority when last named
                                             //   (a named lane rising above its OWN value = an escalation)
        double        laneDigestStart[kLanes] = {0.0, 0.0, 0.0, 0.0};  // when each lane's digest went 0 -> 1
        int           lastNamedSub[kLanes]    = {-1, -1, -1, -1};  // subRegion a lane was last named on
        double        lastNamedAt[kLanes]     = {0.0, 0.0, 0.0, 0.0};
        WandEntry     prov[kLanes];          // ★ the DIGEST callback's contact per lane - seen before raw merges it
                                             //   (PPB's push walk engages ~0.4-0.6 s after contact, often before the
                                             //   bridge has any raw: TakePushContact reads this so the push still
                                             //   finds - and takes - its hand)
        double        lastUpdateEmit  = 0.0;
        double        lastSeenAny     = 0.0;
        int           sweepsSeen      = 0;   // sweeps run while this session was open —
                                             // 0 means the sweep never even looked
    };

    Session g_sessions[kMaxSessions];
    int     s_cand[kMaxSessions][kLanes];    // per-sweep winning raw-contact index, -1 = none
    double  s_lastSweepS   = 0.0;
    std::uint32_t s_lastCellId = 0;          // player's cell, for the transition guard
    std::atomic<bool> s_paused{ false };     // scene suppression (SetScenePaused)

    // Sessions that just ended, kept kPushRecentS for TakePushContact (a shove often lands after the hand left).
    struct RecentSession { std::uint32_t fid = 0; double at = 0.0; WandEntry wand[kLanes]; };
    RecentSession g_recent[kMaxSessions];

    // ★ 2026-09-13: TakePushContact is a Papyrus native. Natives registered without the tasklet flag run
    // on the main thread, like the PPB callback - the lock is belt-and-braces so a future flag change
    // cannot race the sweep. Recursive: nothing here re-enters, but a same-thread re-entry must never
    // deadlock inside HIGGS's frame callback.
    std::recursive_mutex g_lock;

    int g_ppbBuild = 0;   // PPB's GetBuildNumber(), read at Install

    // Which lane a contact belongs to, or -1 (a wand index PPB may add later).
    // ⚠ PPB < 20102 folded a HEAD/GENITAL digest contact into the same digest lane as the right hand (its
    // Start and End could carry different source kinds), so on those builds they keep sharing the wand lane -
    // the pre-2026-09-13 behaviour - or a per-lane digest count could stick at 1 forever.
    int LaneOf(const PPBAPI::PpbTouchContact& c) {
        if (c.wand > 1) return -1;
        if (g_ppbBuild >= 20102) {
            if (c.sourceKind == PPBAPI::kSourceHead)    return kLaneHead;
            if (c.sourceKind == PPBAPI::kSourceGenital) return kLaneGenital;
        }
        return c.wand;
    }

    // ★ 2026-09-13 PUSH TAKES. A contact TakePushContact handed to a push line stays out of every event until
    // `until` - across a brief loss and return of the same hand (the push walk moves her away from it), and
    // across a session that ended and reopened. Keyed (actor, lane); the oldest entry is overwritten.
    constexpr double kPushTakeS = 5.0;   // covers the 3 s push hold plus the stagger
    // What a take is for. kTakePush / kTakeGesture restart the lane's clock when they end (whatever the hand did under
    // them was said by that line). ★ kTakeGrip does NOT: it is only a GRACE - the grab goes on being the same grab, and
    // if no undress arms it is narrated at the grace's end with its full hold (the user, 2026-09-13).
    enum TakeKind : int { kTakePush = 0, kTakeGrip = 1, kTakeGesture = 2 };
    struct PushTake { std::uint32_t fid = 0; int lane = -1; double until = 0.0; int sub = -1; int kind = kTakePush; };
    PushTake g_takes[16];

    double TakenUntil(std::uint32_t fid, int lane) {
        for (const auto& t : g_takes) {
            if (t.fid == fid && t.lane == lane) return t.until;
        }
        return 0.0;
    }

    int TakenSub(std::uint32_t fid, int lane) {
        for (const auto& t : g_takes) {
            if (t.fid == fid && t.lane == lane) return t.sub;
        }
        return -1;
    }

    int TakenKind(std::uint32_t fid, int lane) {
        for (const auto& t : g_takes) {
            if (t.fid == fid && t.lane == lane) return t.kind;
        }
        return kTakePush;
    }

    // Overwrites the lane's take (the latest call wins - an End's tail shortens an Arm's take).
    void RecordTake(std::uint32_t fid, int lane, double until, int sub, int kind = kTakePush) {
        int slot = 0;
        for (int i = 0; i < 16; ++i) {
            if (g_takes[i].fid == fid && g_takes[i].lane == lane) { slot = i; break; }
            if (g_takes[i].until < g_takes[slot].until) slot = i;
        }
        g_takes[slot] = PushTake{ fid, lane, until, sub, kind };
    }

    // The face family of sub-regions (the kiss flicker PPB warns about stays inside it).
    bool IsFaceSub(int sub) {
        switch (sub) {
        case PPBAPI::kSubHead: case PPBAPI::kSubHeadEar: case PPBAPI::kSubFaceSurface:
        case PPBAPI::kSubMouthOpening: case PPBAPI::kSubInMouth: case PPBAPI::kSubInMouthDeep:
        case PPBAPI::kSubMouthWall:
            return true;
        default:
            return false;
        }
    }

    // ── Small helpers ──────────────────────────────────────────────────────────
    void CopyStr(char* dst, std::size_t cap, const char* src) {
        std::size_t i = 0;
        if (src) {
            for (; i + 1 < cap && src[i]; ++i) {
                dst[i] = src[i];
            }
        }
        dst[i] = '\0';
    }

    // Field sanitizer: the contract forbids '|' inside any field.
    std::string Sanitize(const char* s) {
        std::string out(s ? s : "");
        for (auto& ch : out) {
            if (ch == '|') ch = '/';
        }
        return out;
    }

    const char* SourceStr(unsigned char kind) {
        switch (kind) {
        case PPBAPI::kSourceFinger: return "FINGER";
        case PPBAPI::kSourcePalm:   return "PALM";
        case PPBAPI::kSourceFist:   return "FIST";
        case PPBAPI::kSourceHand:   return "HAND";
        case PPBAPI::kSourceGrab:   return "GRAB";
        case PPBAPI::kSourceWeapon: return "WEAPON";
        case PPBAPI::kSourceObject: return "OBJECT";
        // ★ SHIPPED in PPB 2.0.0. ⚠ The LIVE build is 20101 (2.1.1) — gate on
        //   >= 20000, NEVER on an exact value; the number moves every build.
        //   The player's own genitals as a
        // touch source. PPB gates emission itself on GenitalProbe::IsExposed
        // (skin carries slot 52 AND no worn armor on 52), so a dressed or
        // schlong-less player produces NO contacts at all — VRTE adds no gate
        // of its own (an earlier VRTE-side slot-52 test was exactly inverted
        // against this one and would have dropped every contact).
        case PPBAPI::kSourceGenital: return "GENITAL";
        // ★ HEAD — PPB >= 20102, behind PPB's `headBox` knob, which SHIPS OFF.
        // The player's own head as a touch probe. It exists because the head BOX
        // physically blocks him from pushing through her, so a contact here means
        // he leaned in until something stopped him — the touch is a by-product of
        // the collision, not the point of it.
        // ✅ CANNOT reach the choke: arming requires src1 == "GRAB" (MainScript:2669)
        // and so does the liveness stamp (:3262). PPB's warning that a head on the
        // "front neck" capsule must not choke is already answered by construction —
        // a head on the front neck is a nuzzle, and narrates as an ordinary neck touch.
        // ⚠ PPB DESTROYS the head box during an OStim/SexLab scene, so head contacts
        // never arrive inside a scene — VRTE's own scene gate is belt-and-braces here.
        case PPBAPI::kSourceHead:   return "HEAD";
        default:                    return "HAND";
        }
    }

    const char* SubName(int subRegion) {
        const char* n = g_ppb ? g_ppb->SubRegionName(subRegion) : nullptr;
        return n ? n : "";
    }

    // Fill one lane's 8 clause fields (W/SRC/NAME/PART/SUB/DEP/DIST/DUR) into f[0..7].
    void FillEntry(std::string* f, const WandEntry& e, int wandIdx, double now) {
        // ★ INTEGRATION.md on kSourceGenital: "wand is MEANINGLESS and reads 0.
        // It is not a hand. Switch on sourceKind, never on wand." Reporting it as
        // "R" would have been an outright lie in the payload — and W1 is what the
        // narration and the choke-hand latch read. "G" says what it is.
        // (Safe for the two L/R consumers: both sit behind src=="GRAB", which a
        // genital contact can never be.)
        // ★ HEAD joins GENITAL as a source whose `wand` is meaningless and reads 0.
        // "H" says what it is rather than lying with "R".
        f[0] = (e.sourceKind == PPBAPI::kSourceGenital) ? "G"
             : (e.sourceKind == PPBAPI::kSourceHead)    ? "H"
             : (wandIdx == 1)                           ? "L"
                                                        : "R";
        f[1] = SourceStr(e.sourceKind);
        // ★ GENITAL joins WEAPON/OBJECT as a source that NAMES ITSELF: PPB puts
        // "shaft" or "tip" in sourceName (which segment of him made contact),
        // exactly as a weapon carries its own name. Dropping it here would have
        // thrown that detail away before Papyrus ever saw it.
        // ★ HEAD names itself too: PPB puts "face" (front of the box won) or "head"
        // (back of the skull won) in sourceName. That is the KISS-vs-HEADBUTT
        // discriminator, already computed by PPB — VRTE must never re-derive it with
        // geometry of its own (two detectors for one thing drift, silently).
        f[2] = (e.sourceKind == PPBAPI::kSourceWeapon ||
                e.sourceKind == PPBAPI::kSourceObject ||
                e.sourceKind == PPBAPI::kSourceGenital ||
                e.sourceKind == PPBAPI::kSourceHead)
                   ? Sanitize(e.sourceName) : "";
        f[3] = Sanitize(e.bodyPart);
        f[4] = Sanitize(SubName(e.subRegion));
        f[5] = std::to_string(e.depth);
        char d[32];
        std::snprintf(d, sizeof(d), "%.2f", e.distDeepest);
        f[6] = d;
        // The lane's own hold: a hand that joined a running session carries its own clock, so Papyrus
        // measures its dwell on it (the session clock would call a fresh brush "held for 5 s").
        const double end = e.live ? now : e.lastSeen;
        const double held = (e.laneStart > 0.0 && end > e.laneStart) ? (end - e.laneStart) : 0.0;
        std::snprintf(d, sizeof(d), "%.2f", held);
        f[7] = d;
    }

    // lanes[0..n-1] = the lane indices to name, highest priority first.
    std::string BuildStrArg(const WandEntry* wand, const int* lanes, int n, const char* esc, double now) {
        std::string f[kPayloadFields];        // unused clauses stay ""
        f[0] = esc;
        f[1] = n > 0 ? Sanitize(wand[lanes[0]].skeleton) : "";
        f[2] = std::to_string(n);
        for (int k = 0; k < n && k < kLanes; ++k) {
            FillEntry(&f[3 + k * kClauseFields], wand[lanes[k]], lanes[k], now);
        }
        std::string out;
        out.reserve(384);
        for (int i = 0; i < kPayloadFields; ++i) {
            if (i) out += '|';
            out += f[i];
        }
        return out;
    }

    // Already on the MAIN thread (PPB callback / SKSE task) — send directly,
    // no task handoff needed (unlike the cbp worker-thread hook).
    void SendModEvent(const char* evName, const std::string& strArg,
                      float numArg, std::uint32_t fid) {
        auto* src = SKSE::GetModCallbackEventSource();
        if (!src) {
            return;
        }
        SKSE::ModCallbackEvent ev{};
        ev.eventName = evName;
        ev.strArg    = strArg.c_str();
        ev.numArg    = numArg;
        ev.sender    = RE::TESForm::LookupByID(fid);
        src->SendEvent(&ev);
    }

    // Tie-break contract: higher priority, then higher depth, then deeper distU
    // (more negative), then keep the incumbent (return false).
    bool ContactBeats(const PPBAPI::PpbTouchContact& a, const PPBAPI::PpbTouchContact& b) {
        const int pa = PriorityOfContact(a);
        const int pb = PriorityOfContact(b);
        if (pa != pb)             return pa > pb;
        if (a.depth != b.depth)   return a.depth > b.depth;
        if (a.distU != b.distU)   return a.distU < b.distU;
        return false;
    }

    bool EntryBeats(const WandEntry& a, const WandEntry& b) {
        if (a.priority != b.priority)       return a.priority > b.priority;
        if (a.depth != b.depth)             return a.depth > b.depth;
        if (a.distDeepest != b.distDeepest) return a.distDeepest < b.distDeepest;
        return false;
    }

    // Merge one sweep's winning raw contact into a wand slot. distDeepest is
    // per-PART: it carries (min) while the same capsule stays current and
    // resets when the wand moves to a different capsule (or after a stale gap).
    void ApplyContact(WandEntry& e, const PPBAPI::PpbTouchContact& c, double now, double digestStart) {
        const bool samePart = e.live && e.slot == c.slot && e.child == c.child &&
                              e.leftTwin == c.leftTwin;
        e.distDeepest = samePart ? (std::min)(e.distDeepest, c.distU) : c.distU;
        if (!e.live) {
            // A dead lane coming back is a NEW contact with its own clock. ★ The clock starts at the lane's
            // digest Start, not at this first RAW merge: raw lags the digest by a tick or two (see
            // kRawGraceS), and starting late made every dwell ~0.5 s longer than the old session clock
            // (review 2026-09-13). For the lane that opened the session this IS startTime.
            e.laneStart = (digestStart > 0.0 && digestStart <= now && now - digestStart < 1.0) ? digestStart : now;
        } else if (c.sourceKind == PPBAPI::kSourceHead && IsFaceSub(e.subRegion) != IsFaceSub(c.subRegion)) {
            // The HEAD lane's clock restarts when the head moves between her FACE and the rest of her (lips -> neck:
            // a new kiss "held for" its own time). Only on that crossing - a head resting on a boundary flickers
            // between neighbouring capsules, and restarting on every flicker meant its dwell never ripened (final
            // verify 2026-09-13). Hands keep the interaction clock: a wandering hand must not restart its dwell.
            e.laneStart = now;
        }
        e.live       = true;
        e.everSeen   = true;
        e.slot       = c.slot;
        e.child      = c.child;
        e.leftTwin   = c.leftTwin;
        e.sourceKind = c.sourceKind;
        e.subRegion  = c.subRegion;
        e.depth      = c.depth;
        e.priority   = PriorityOfContact(c);
        e.durationS  = c.durationS;
        e.lastSeen   = now;
        CopyStr(e.bodyPart,   sizeof(e.bodyPart),   c.bodyPart);
        CopyStr(e.sourceName, sizeof(e.sourceName), c.sourceName);
        CopyStr(e.skeleton,   sizeof(e.skeleton),   c.skeleton);
    }

    void EmitEnd(const Session& s, double now);  // defined below (eviction needs it)

    // Existing session for this actor, or -1. The RAW sweep never creates a
    // session — PPB's digest Start callback is the sole creator, so a session
    // always has a valid digest lifecycle to close it (the raw snapshot is one
    // frame stale and cannot be trusted to say "the touch is over").
    int FindSession(std::uint32_t fid) {
        for (int i = 0; i < kMaxSessions; ++i) {
            if (g_sessions[i].active && g_sessions[i].fid == fid) {
                return i;
            }
        }
        return -1;
    }

    // Open (or return) this actor's session; windowDeadline = now + 1.0 s.
    // Cap kMaxSessions: claim a free slot, else LRU-evict the oldest — emitting
    // its VRTE_ContactEnd first so Papyrus never strands a pending-ring entry.
    int OpenSession(std::uint32_t fid, double now) {
        const int found = FindSession(fid);
        if (found >= 0) {
            return found;
        }
        int    freeIdx = -1, oldestIdx = 0;
        double oldest  = 1e300;
        for (int i = 0; i < kMaxSessions; ++i) {
            if (!g_sessions[i].active) {
                if (freeIdx < 0) freeIdx = i;
            } else if (g_sessions[i].lastSeenAny < oldest) {
                oldest = g_sessions[i].lastSeenAny;
                oldestIdx = i;
            }
        }
        const int idx = (freeIdx >= 0) ? freeIdx : oldestIdx;
        if (freeIdx < 0) {
            logger::info("[PPB-BRIDGE] session cap hit — evicting fid=0x{:08X} for 0x{:08X}",
                         g_sessions[idx].fid, fid);
            EmitEnd(g_sessions[idx], now);
        }
        g_sessions[idx] = Session{};
        g_sessions[idx].active         = true;
        g_sessions[idx].fid            = fid;
        g_sessions[idx].startTime      = now;
        g_sessions[idx].windowDeadline = now + kWindowS;
        g_sessions[idx].lastSeenAny    = now;
        for (int l = 0; l < kLanes; ++l) {
            s_cand[idx][l] = -1;
        }
        return idx;
    }

    // The lanes to name, highest priority first (EntryBeats; the lower lane index is the incumbent on a
    // full tie). mode 0 = live and not taken by a push (what an event names) · 1 = live, taken or not ·
    // 2 = ever seen (the End snapshot). Returns the count.
    int OrderedLanes(const Session& s, int mode, int out[kLanes], double now) {
        const WandEntry* wand = s.wand;
        int n = 0;
        for (int l = 0; l < kLanes; ++l) {
            const WandEntry& e = wand[l];
            const bool ok = (mode == 2) ? e.everSeen
                                        : (e.live && (mode == 1 || now >= TakenUntil(s.fid, l)));
            if (!ok) continue;
            int at = n;
            while (at > 0 && EntryBeats(e, wand[out[at - 1]])) {
                out[at] = out[at - 1];
                --at;
            }
            out[at] = l;
            ++n;
        }
        return n;
    }

    unsigned MaskOf(const int* lanes, int n) {
        unsigned m = 0;
        for (int k = 0; k < n; ++k) m |= (1u << lanes[k]);
        return m;
    }

    // Move `lane` to the front of `lanes` (keeping the others in their order): clause 0 of an escalation or a
    // JOIN is the lane that CAUSED it, so Papyrus can apply ESC to that clause alone.
    void CauseFirst(int* lanes, int n, int lane) {
        for (int k = 0; k < n; ++k) {
            if (lanes[k] != lane) continue;
            for (int j = k; j > 0; --j) lanes[j] = lanes[j - 1];
            lanes[0] = lane;
            return;
        }
    }

    void EmitSessionEvent(const char* evName, const Session& s, const int* lanes, int n,
                          const char* esc, float numArg, double now) {
        const std::string strArg = BuildStrArg(s.wand, lanes, n, esc, now);
        SendModEvent(evName, strArg, numArg, s.fid);
    }

    void RememberRecent(const Session& s, double now) {
        int slot = 0;
        for (int i = 0; i < kMaxSessions; ++i) {
            if (g_recent[i].fid == s.fid) { slot = i; break; }
            if (g_recent[i].at < g_recent[slot].at) slot = i;
        }
        g_recent[slot].fid = s.fid;
        g_recent[slot].at  = now;
        for (int l = 0; l < kLanes; ++l) g_recent[slot].wand[l] = s.wand[l];
    }

    // Session over: emit VRTE_ContactEnd from the retained (everSeen) snapshots.
    // numArg = the span the touch was actually live (lastSeenAny - startTime),
    // NOT now - startTime — the End can arrive up to the stale window late.
    // A session that never emitted a Contact (touch shorter than the window)
    // sends NOTHING — Papyrus never saw it, so an End would just be noise.
    void EmitEnd(const Session& s, double now) {
        int ord[kLanes];
        const int nSeen = OrderedLanes(s, 2, ord, now);
        const int p = nSeen > 0 ? ord[0] : -1;
        if (p >= 0) {
            RememberRecent(s, now);   // a shove often lands just after the hand left (TakePushContact)
        }
        if (p < 0) {
            // ⛔ 2026-08-23 — THIS DID HAPPEN, TWICE, AND IT WAS SILENT.
            // A 7.18s PALM on a male's chest and a 7.23s FINGER on a female's
            // CLITORIS both had a digest lifecycle (Start..End) yet never had a
            // single RAW contact merged into either wand slot, so the session
            // closed reporting nothing at all. Papyrus never heard of either
            // touch. The old comment said "shouldn't happen" and returned — so
            // the one thing that could have explained it was never written down.
            // Now it says so, with everything needed to tell a PPB-side raw-stream
            // gap from a bridge-side sweep gap.
            //
            // ★ 2026-09-02 — AND NOW IT SAYS *WHICH*. The message below used to fire
            // unconditionally and read as an alarm ("NOTHING was sent to Papyrus"),
            // which caused a real misdiagnosis: an audit read 14 of these in one log
            // and filed them as 14 lost touches, ranking it the mod's top defect.
            // They were not lost. Their observed spans were 0.00-0.50 s — under PPB's
            // 0.25 s raw dwell filter (see kPpbRawDwellS), so no raw was ever
            // published for them, BY DESIGN. VRTE would have dropped them anyway:
            // they are far under the 1.0 s coalescer window.
            // ⛔ DO NOT "fix" that by defeating the filter — it is PPB's spam guard,
            // and removing it floods SkyrimNet with brush events.
            // A LONG contact with no raw behind it is the genuine fault (PPB's own
            // 2026-08-23 raw-latch rewrite was written for exactly that), so only
            // that case keeps the alarm.
            // ⚠ The discriminator is WALL-CLOCK age, not `lastSeenAny - startTime`.
            // `lastSeenAny` only advances on a digest Start or a raw merge, so a
            // genuinely lost LONG contact (one Start, one End, no raw — precisely
            // PPB's two 7 s cases) also reports span 0.00 and would be misfiled as a
            // brush by the observed span. Wall age cannot be fooled that way.
            const float wallAge = static_cast<float>(now - s.startTime);
            const float span    = static_cast<float>(s.lastSeenAny - s.startTime);
            if (wallAge < static_cast<float>(kWindowS)) {
                logger::info("[PPB-BRIDGE] sub-window brush dropped fid=0x{:08X} "
                             "wall={:.2f}s span={:.2f}s sweeps={} — under PPB's {:.2f}s "
                             "raw dwell and under the {:.2f}s window, so nothing was "
                             "published and nothing would have fired. EXPECTED.",
                             s.fid, wallAge, span, s.sweepsSeen,
                             static_cast<float>(kPpbRawDwellS),
                             static_cast<float>(kWindowS));
                return;
            }
            logger::info("[PPB-BRIDGE] ⛔ LONG contact with NO raw ever merged "
                         "fid=0x{:08X} liveDigest=[{},{},{},{}] sweeps-since-open={} "
                         "wall={:.2f}s span={:.2f}s — the digest saw a touch of at "
                         "least {:.2f}s but raw published nothing for it, so NOTHING "
                         "reached Papyrus. THIS ONE IS A REAL FAULT: suspect a PPB "
                         "raw-latch gap (its 2026-08-23 rewrite fixed the last one) "
                         "before suspecting the bridge.",
                         s.fid, s.liveDigest[0], s.liveDigest[1], s.liveDigest[2], s.liveDigest[3], s.sweepsSeen,
                         wallAge, span, static_cast<float>(kWindowS));
            return;
        }
        const float total = static_cast<float>(s.lastSeenAny - s.startTime);
        if (s.emittedPriority < 0) {
            logger::info("[PPB-BRIDGE] End (sub-window, unemitted) fid=0x{:08X} part='{}' "
                         "total={:.2f}s — no event sent",
                         s.fid, s.wand[p].bodyPart, total);
            return;
        }
        EmitSessionEvent(kEvEnd, s, ord, nSeen, "0", total, now);
        logger::info("[PPB-BRIDGE] End fid=0x{:08X} part='{}' lanes={} total={:.2f}s",
                     s.fid, s.wand[p].bodyPart, nSeen, total);
    }

    // ── The TRANSITION GUARD (2026-08-01, the Whiterun infinite-load hang) ─────
    //
    // Walking through a door does NOT fire kPreLoadGame/kNewGame, so sessions
    // opened in the old cell survived the transition and could fire a
    // VRTE_ContactEnd into the VM *mid-load*. PPB itself guards against exactly
    // this — `PpbApi::ClearOnLoad()` is commented "drop live touch contacts
    // (no End events across a load)". We now mirror that rule: across a load or
    // a cell change, sessions are dropped SILENTLY. An End for an interaction
    // that ended because the worldspace changed carries no information anyway.
    void ClearSessionsSilently(const char* why) {
        int n = 0;
        for (auto& s : g_sessions) {
            if (s.active) {
                s = Session{};
                ++n;
            }
        }
        for (auto& r : g_recent) {
            r = RecentSession{};
        }
        for (auto& t : g_takes) {
            t = PushTake{};
        }
        if (n > 0) {
            logger::info("[PPB-BRIDGE] {} — {} live session(s) dropped SILENTLY "
                         "(no End events across a transition).", why, n);
        }
    }

    // True while a loading screen is up. Cheap main-thread singleton read.
    bool InTransition() {
        auto* ui = RE::UI::GetSingleton();
        return ui && ui->IsMenuOpen("Loading Menu");
    }

    // ── ONE sweep: poll the raw snapshot, update sessions, decide emits ────────
    void Sweep(double now) {
        if (!g_ppb) {
            return;
        }

        // Never touch the VM during a load screen, and never carry a session
        // across a cell boundary (the old cell's actors are unloading).
        if (InTransition()) {
            ClearSessionsSilently("loading menu open");
            return;
        }
        auto*               pc     = RE::PlayerCharacter::GetSingleton();
        auto*               cell   = pc ? pc->GetParentCell() : nullptr;
        const std::uint32_t cellId = cell ? cell->GetFormID() : 0;
        if (cellId != s_lastCellId) {
            if (s_lastCellId != 0) {
                ClearSessionsSilently("player cell changed");
            }
            s_lastCellId = cellId;
        }

        PPBAPI::PpbTouchContact buf[kRawBufMax];
        const int n = std::clamp(g_ppb->GetRawContacts(buf, kRawBufMax), 0, kRawBufMax);

        for (int i = 0; i < kMaxSessions; ++i) {
            for (int l = 0; l < kLanes; ++l) {
                s_cand[i][l] = -1;
            }
        }

        // ★ Erection-byte harvest (see GenLevelEntry above). Reads _reserved[0]
        // on EVERY raw contact. ★ CORRECTED 2026-09-02: this is LIVE, not pending.
        // PPB ships it (StampGenLevel, PpbApi.cpp:513, on BOTH the raw and digest
        // paths) as genLevel+1 — 0 absent / 1 = level 0 flaccid / N = level N-1,
        // VRTE's own encoding. The old wording ("0 on today's PPB, tail is
        // contractually zero") predated PPB 2.0.0 and would talk a maintainer out
        // of a working feature. Done before the wand guard
        // so a future genital-wand contact also stamps it.
        for (int i = 0; i < n; ++i) {
            const unsigned char gl = buf[i]._reserved[0];
            // ⛔ FIXED 2026-08-23 from PPB's INTEGRATION.md, which is explicit:
            //   "The byte is written on EVERY contact including the zero, so a 0
            //    arriving mid-contact means 'no longer known' — not 'unchanged'."
            // The first cut only wrote on gl >= 1, so once a level was cached it
            // FROZE there: he dresses, the rig goes away, PPB starts sending 0 —
            // and VRTE would have gone on narrating "his erect penis" off a stale
            // byte indefinitely. Exactly the keep-last-nonempty trap PPB warns
            // about in its own stamping code. 0 now clears to unknown (-1), which
            // makes the narration drop the erection clause instead of lying.
            NoteGenLevel(buf[i].actorFormId,
                         gl >= 1 ? static_cast<int>(gl) - 1 : -1);
        }

        // Pass A — pick each (actor, LANE)'s winning raw contact this sweep.
        // GRAB wins a contested hand lane outright; otherwise priority decides
        // (ContactBeats keeps the incumbent on a full tie). ★ 2026-09-13: the head and the
        // genital have their own lanes now, so they never compete with the right hand.
        for (int i = 0; i < n; ++i) {
            const auto& c = buf[i];
            const int lane = LaneOf(c);
            if (c.toucherFormId != kPlayerFormId || c.actorFormId == 0 || lane < 0) {
                continue;
            }
            const int si = FindSession(c.actorFormId);
            if (si < 0) {
                continue;   // no digest session yet — the Start callback owns creation
            }
            int& cand = s_cand[si][lane];
            if (cand < 0) {
                cand = i;
                continue;
            }
            const auto& inc   = buf[cand];
            const bool  cGrab = (c.sourceKind == PPBAPI::kSourceGrab);
            const bool  iGrab = (inc.sourceKind == PPBAPI::kSourceGrab);
            if (cGrab != iGrab) {
                if (cGrab) cand = i;
                continue;
            }
            if (ContactBeats(c, inc)) {
                cand = i;
            }
        }

        // Pass B — merge the winners into the persistent wand slots.
        for (int si = 0; si < kMaxSessions; ++si) {
            Session& s = g_sessions[si];
            if (!s.active) {
                continue;
            }
            ++s.sweepsSeen;   // diagnostic for the "no raw contact ever merged" case
            for (int w = 0; w < kLanes; ++w) {
                if (s_cand[si][w] >= 0) {
                    ApplyContact(s.wand[w], buf[s_cand[si][w]], now, s.laneDigestStart[w]);
                    s.lastSeenAny = now;
                    // Pre-emit (rule 2 — priority overrides duration): remember
                    // the BEST capsule this wand has shown during the window, so
                    // breast 0.3 s -> slid to chest ring still emits "breast".
                    // (A lane TAKEN by a push collects no window-best: a part the pushing hand crossed must not be
                    // swapped back in and narrated as a current touch when the take ends - verify 2026-09-13.)
                    // (A grip GRACE keeps collecting: it is the same grab, narrated at the grace's end if no undress arms.)
                    if (s.emittedPriority < 0 && (now >= TakenUntil(s.fid, w) || TakenKind(s.fid, w) == kTakeGrip) &&
                        (!s.windowBest[w].everSeen || EntryBeats(s.wand[w], s.windowBest[w]))) {
                        s.windowBest[w] = s.wand[w];
                    }
                }
            }
        }

        // Pass C — per-session lifecycle + emit decisions.
        for (int si = 0; si < kMaxSessions; ++si) {
            Session& s = g_sessions[si];
            if (!s.active) {
                continue;
            }

            // (d) clear a wand when PPB's digest lifecycle says the hand is off
            // her (Start/End balanced to zero — AUTHORITATIVE, and the only
            // reliable signal since the raw snapshot lags a frame), or as a
            // backstop if it simply went unseen. Data is retained for the End
            // emit; no live entries => session over.
            // ★ BOTH conditions are required (2026-08-01 fragmentation fix).
            // PPB's digest is per (actor, wand, REGION), so ONE continuous touch
            // legitimately cycles End(regionA)/Start(regionB) as the hand
            // wanders — a hand resting on the belly flickers between
            // 'belly / navel' (region Belly) and 'lower abdomen' (region Waist).
            // Killing the wand the moment liveDigest hit 0 tore a single 2.8 s
            // touch into 0.25 s / 0.51 s fragments, none of which reached the
            // 1.0 s window, so NOTHING was ever emitted. The raw-recency window
            // (kWandStaleS) bridges the ~0.26 s region-handover gap.
            for (int w = 0; w < kLanes; ++w) {
                if (!s.wand[w].live) {
                    continue;
                }
                const bool digestDone = (s.liveDigest[w] <= 0);
                const bool rawStale   = (now - s.wand[w].lastSeen > kWandStaleS);
                if (digestDone && rawStale) {
                    s.wand[w].live = false;
                }
            }
            int liveAll[kLanes];
            const int nLiveAll = OrderedLanes(s, 1, liveAll, now);
            if (nLiveAll == 0) {
                // ★ liveDigest is PPB's AUTHORITATIVE "is this hand still on her"
                // (this file says so 30 lines up, and the wand-clearing rule above
                // already refuses to act on raw alone). Honour it HERE too: while
                // the digest says a hand is on her, a missing raw entry means raw
                // has not caught up yet — not that the touch ended. Bounded by
                // kRawGraceS so a stuck digest cannot pin a session open forever,
                // and the give-up still logs (see EmitEnd) so a genuine raw-stream
                // gap is still reported rather than silently waited out.
                bool digestLive = false;
                // ★ The grace runs from the NEWEST digest Start still counted, not the session's start (verify
                // 2026-09-13): a new source arriving in a 3 s old session (the hand lifts, the mouth lands) has no
                // raw yet either, and measuring from the old start wiped the session and lost the new touch.
                double graceFrom = s.startTime;
                for (int l = 0; l < kLanes; ++l) {
                    if (s.liveDigest[l] > 0) {
                        digestLive = true;
                        if (s.laneDigestStart[l] > graceFrom) graceFrom = s.laneDigestStart[l];
                    }
                }
                if (digestLive && (now - graceFrom) < kRawGraceS) {
                    continue;   // raw is one frame behind — give it a moment
                }
                EmitEnd(s, now);
                s = Session{};
                continue;
            }
            // A push take that just ran out: that hand's clock restarts where the push ended, so a hand still
            // resting on her afterwards waits its own dwell rather than reading "held for 8 s" at once.
            for (int l = 0; l < kLanes; ++l) {
                const double tu = TakenUntil(s.fid, l);
                if (tu > 0.0 && now >= tu && s.wand[l].live && s.wand[l].laneStart < tu &&
                    TakenKind(s.fid, l) != kTakeGrip) {
                    s.wand[l].laneStart = tu;
                    s.windowBest[l] = WandEntry{};   // nothing the take hid may be swapped back in
                }
            }
            // What an event may name: live lanes NOT taken by a push reaction. When every live lane is
            // taken, the session stays open (it still ends normally) but says nothing.
            int ord[kLanes];
            const int nOrd = OrderedLanes(s, 0, ord, now);
            if (nOrd == 0) {
                s.emittedMask = 0;
                continue;
            }
            const int      p        = ord[0];
            const unsigned liveMask = MaskOf(ord, nOrd);
            // Remember where each named lane is, so a brief lift-and-return to the SAME part is not "new".
            for (int k = 0; k < nOrd; ++k) {
                const int l = ord[k];
                if (s.emittedMask & (1u << l)) {
                    s.lastNamedSub[l] = s.wand[l].subRegion;
                    s.lastNamedAt[l]  = now;
                }
            }
            s.emittedMask &= liveMask;   // a lane that left is no longer "named"; if it returns, it JOINS
            // ★ ...unless it came back to the part it was named on within kSessionRetireS, or it is a push TAKE that
            // just ran out while the hand stayed on the taken part: that is the same contact, already said (or said
            // by the push line) - put it back silently, no JOIN (verify 2026-09-13: a patting hand re-narrated on
            // every pat; a palm left on her after a shove came back as a third event).
            for (int k = 0; k < nOrd; ++k) {
                const int l = ord[k];
                if (s.emittedMask & (1u << l)) continue;
                const double tu        = TakenUntil(s.fid, l);
                const bool   sameReturn = s.lastNamedSub[l] == s.wand[l].subRegion && s.lastNamedAt[l] > 0.0 &&
                                          now - s.lastNamedAt[l] <= kSessionRetireS;
                const bool   takeEnded  = tu > 0.0 && now >= tu && now - tu <= kSessionRetireS &&
                                          TakenSub(s.fid, l) == s.wand[l].subRegion;
                if (sameReturn || takeEnded) {
                    s.emittedMask |= (1u << l);
                    if (s.wand[l].priority > s.emittedPri[l]) s.emittedPri[l] = s.wand[l].priority;
                    if (s.emittedPriority < 0) {
                        // Only the taken contact is on her and the push line already said it: count the session as
                        // emitted, silently, so no first Contact repeats it.
                        s.emittedPriority = s.wand[l].priority;
                        s.lastUpdateEmit  = now;
                    }
                }
            }

            if (s.emittedPriority < 0) {
                // (a) coalescer window: first emit once the window has passed.
                // ★ A breast winner uses the short window (kWindowBreastS). Escalation
                // already bypasses the window entirely, so a strictly higher-priority part
                // arriving later still upgrades the emitted event via ESC=1 -- emitting the
                // breast early costs no accuracy, it only stops costing a second.
                const bool   breastPrimary = (s.wand[p].subRegion == PPBAPI::kSubBreast);
                const double firstDeadline = breastPrimary
                                           ? (s.startTime + kWindowBreastS)
                                           : s.windowDeadline;
                if (now >= firstDeadline) {
                    // Rule 2 — a higher-priority capsule seen transiently during
                    // the window beats the one currently touched: swap its
                    // snapshot back in so IT is the emitted event. The next
                    // sweep's ApplyContact resumes current-capsule tracking.
                    for (int w = 0; w < kLanes; ++w) {
                        WandEntry&       lv = s.wand[w];
                        const WandEntry& wb = s.windowBest[w];
                        if (lv.live && now >= TakenUntil(s.fid, w) && wb.everSeen && EntryBeats(wb, lv)) {
                            const double seen  = lv.lastSeen;
                            const double start = lv.laneStart;
                            lv           = wb;
                            lv.live      = true;
                            lv.lastSeen  = seen;   // stale-tracking keeps the REAL last sighting
                            lv.laneStart = start;  // and the lane keeps its own clock
                        }
                    }
                    int       eo[kLanes];
                    const int en = OrderedLanes(s, 0, eo, now);   // re-order after the swap
                    // numArg = the SESSION's accumulated duration, not PPB's
                    // per-contact durationS: after a region handover the new
                    // digest contact's clock has restarted, but the touch has
                    // been going the whole time. Each clause also carries its own lane clock.
                    const float sdur = static_cast<float>(now - s.startTime);
                    EmitSessionEvent(kEvContact, s, eo, en, "0", sdur, now);
                    s.emittedPriority = s.wand[eo[0]].priority;
                    s.emittedMask     = MaskOf(eo, en);
                    for (int k = 0; k < en; ++k) s.emittedPri[eo[k]] = s.wand[eo[k]].priority;
                    s.lastUpdateEmit  = now;
                    logger::info("[PPB-BRIDGE] Contact fid=0x{:08X} part='{}' sub={} pri={} "
                                 "src={} lanes={} dur={:.2f}s",
                                 s.fid, s.wand[eo[0]].bodyPart, s.wand[eo[0]].subRegion, s.emittedPriority,
                                 SourceStr(s.wand[eo[0]].sourceKind), en, sdur);
                }
            } else {
                // ★ 2026-09-13 PER-LANE escalation and JOIN. The old rule compared the SESSION's best priority
                // with the best ever emitted, so once a kiss (floored at 70) was named, a hand already on her
                // sliding from her belly to her breast said nothing for the rest of the session (review).
                //   escalation = a lane ALREADY named whose priority rose above ITS OWN last named value
                //   JOIN       = a live lane not named in the last event
                // In both, the causing lane is moved to clause 0 so Papyrus applies ESC to that clause alone.
                int escLane = -1, joinLane = -1;
                for (int k = 0; k < nOrd; ++k) {
                    const int l = ord[k];
                    const bool named = (s.emittedMask & (1u << l)) != 0;
                    if (named && s.wand[l].priority > s.emittedPri[l]) {
                        if (escLane < 0 || EntryBeats(s.wand[l], s.wand[escLane])) escLane = l;
                    } else if (!named) {
                        if (joinLane < 0 || EntryBeats(s.wand[l], s.wand[joinLane])) joinLane = l;
                    }
                }
                if (escLane >= 0 || joinLane >= 0) {
                    // (b) escalation fires IMMEDIATELY; (b2) a source JOINED: re-send the whole picture so
                    // Papyrus can name it. ESC "2" is new information, NOT an escalation - it bypasses no clock.
                    const bool isEsc = (escLane >= 0);
                    const int  cause = isEsc ? escLane : joinLane;
                    CauseFirst(ord, nOrd, cause);
                    EmitSessionEvent(kEvContact, s, ord, nOrd, isEsc ? "1" : "2",
                                     static_cast<float>(now - s.startTime), now);
                    // Baselines (verify 2026-09-13): the CAUSE and any lane that was not named before take their
                    // current priority. A lane already named keeps its own baseline - lowering it made a hand bobbing
                    // between two parts re-escalate on every upward move, and raising it swallowed a second lane that
                    // rose in the same sweep (it now escalates on the next sweep as its own clause 0).
                    for (int k = 0; k < nOrd; ++k) {
                        const int l = ord[k];
                        const bool wasNamed = (s.emittedMask & (1u << l)) != 0;
                        if (l == cause || !wasNamed) {
                            s.emittedPri[l] = s.wand[l].priority;
                        } else if (s.wand[l].priority > s.emittedPri[l]) {
                            // A named lane that ROSE in the same sweep is named in this line with its new part: raise
                            // its baseline too, or it escalates again 0.2 s later with the same content (final verify).
                            s.emittedPri[l] = s.wand[l].priority;
                        }
                    }
                    if (s.wand[cause].priority > s.emittedPriority) s.emittedPriority = s.wand[cause].priority;
                    s.emittedMask    = liveMask;
                    s.lastUpdateEmit = now;
                    logger::info("[PPB-BRIDGE] {} fid=0x{:08X} lane={} part='{}' sub={} pri={} lanes={}",
                                 isEsc ? "ESCALATION" : "JOIN", s.fid, cause, s.wand[cause].bodyPart,
                                 s.wand[cause].subRegion, s.wand[cause].priority, nOrd);
                    continue;
                }
            }
            if (s.emittedPriority < 0) {
                continue;   // still inside the first window
            }
            if (now - s.lastUpdateEmit >= kUpdatePeriodS) {
                // (c) heartbeat while the session lives — carries the durations so Papyrus's pending
                // dwell-waits can mature.
                const float sdur = static_cast<float>(now - s.startTime);
                EmitSessionEvent(kEvUpdate, s, ord, nOrd, "0", sdur, now);
                s.lastUpdateEmit = now;
                if constexpr (kSweepDebug) {
                    logger::info("[PPB-BRIDGE] Update fid=0x{:08X} part='{}' dur={:.2f}s",
                                 s.fid, s.wand[p].bodyPart, sdur);
                }
            }
        }

        if constexpr (kSweepDebug) {
            int live = 0;
            for (const auto& s : g_sessions) {
                if (s.active) ++live;
            }
            logger::info("[PPB-BRIDGE] sweep: {} raw contact(s), {} session(s)", n, live);
        }
    }

    // ── The tick: PPB's callback, and NOTHING else ─────────────────────────────
    //
    // ★★ THE 2026-08-01 FREEZE — READ BEFORE CHANGING THIS FUNCTION.
    //
    // This callback runs INSIDE HIGGS's PostVrikPostHiggs frame callback:
    //     HIGGS AddPostVrikPostHiggsCallback -> PerfSys.cpp:259 lambda
    //       -> PpbApi::OnFrame() -> Emit() -> PpbApi.cpp:1118 -> here.
    // i.e. deep inside the game's frame update, on the main thread.
    //
    // **`SKSE::GetTaskInterface()->AddTask()` from this context HARD-FREEZES the
    // game** (main-thread deadlock on the task-queue lock; no exception, no
    // crash log). Two sessions were lost to it. `SendEvent` from here is FINE —
    // PPB itself sends its own mod events from this exact spot (PpbApi.cpp:1120+)
    // and never calls AddTask anywhere. So: do the work synchronously, right
    // here, exactly like PPB does. There is NO deferral and NO pump.
    //
    // Session lifecycle rides PPB's own digest phases (balanced Start/End per
    // (actor, wand)) rather than a timer, so no tick source is needed after the
    // last contact ends — the End callback itself closes the session. The raw
    // snapshot (polled in Sweep) supplies the CURRENT capsule for the priority
    // rule; it lags one frame (PPB publishes it after Emit), which is why it is
    // never used to decide that a touch is over.
    // Keep the digest callback's contact as this lane's provisional snapshot (see Session::prov).
    void NoteProvisional(Session& s, int w, const PPBAPI::PpbTouchContact& c, double now) {
        WandEntry& e = s.prov[w];
        e.everSeen    = true;
        e.live        = false;
        e.slot        = c.slot;
        e.child       = c.child;
        e.leftTwin    = c.leftTwin;
        e.sourceKind  = c.sourceKind;
        e.subRegion   = c.subRegion;
        e.depth       = c.depth;
        e.priority    = PriorityOfContact(c);
        e.distDeepest = c.distU;
        e.lastSeen    = now;
        e.laneStart   = s.laneDigestStart[w] > 0.0 ? s.laneDigestStart[w] : now;
        const char* cap = g_ppb ? g_ppb->CapsuleName(c.slot, c.child) : nullptr;
        CopyStr(e.bodyPart,   sizeof(e.bodyPart),   (cap && cap[0]) ? cap : c.bodyPart);
        CopyStr(e.sourceName, sizeof(e.sourceName), c.sourceName);
        CopyStr(e.skeleton,   sizeof(e.skeleton),   c.skeleton);
    }

    void OnPpbTouch(const PPBAPI::PpbTouchContact* c, int phase) {
        if (!g_ppb || !c || c->toucherFormId != kPlayerFormId ||
            c->actorFormId == 0 || LaneOf(*c) < 0 || s_paused.load()) {
            return;
        }
        std::lock_guard<std::recursive_mutex> guard(g_lock);
        const double now = NowS();
        const int    w   = LaneOf(*c);

        if (phase == PPBAPI::kPhaseStart) {
            // A session lingers after the last contact (no tick source once PPB
            // stops calling us — see the note above), so a genuinely NEW touch
            // must retire the stale one rather than resume it with a spent
            // window and a stale accumulated duration.
            const int old = FindSession(c->actorFormId);
            if (old >= 0) {
                Session& os = g_sessions[old];
                // ★ 2026-09-13 (review): a lane only dies inside a sweep, and sweeps only run on PPB callbacks - so a
                // lane whose touch ended can still read live=true, holding its old snapshot and clock. Apply the
                // sweep's own kill rule HERE, before the new touch merges into it, so that merge is a REVIVAL.
                if (os.liveDigest[w] <= 0 && os.wand[w].live && now - os.wand[w].lastSeen > kWandStaleS) {
                    os.wand[w].live = false;
                }
                bool oldDigestIdle = true;
                for (int l = 0; l < kLanes; ++l) {
                    oldDigestIdle = oldDigestIdle && os.liveDigest[l] <= 0;
                }
                // The pre-lanes retire rule, unchanged: only a session idle for more than kSessionRetireS is retired.
                // A quicker lift-and-return stays in the SAME session - the killed lane revives with a fresh clock,
                // keeps its "named" state, and escalates only above its own baseline (final verify 2026-09-13: retiring
                // it re-narrated every pat). The Pass C grace now runs from this Start, so the session cannot be wiped
                // while the new touch's raw is still on its way.
                if (oldDigestIdle && now - os.lastSeenAny > kSessionRetireS) {
                    EmitEnd(os, now);
                    os = Session{};
                }
            }
            const int si = OpenSession(c->actorFormId, now);
            Session&  s  = g_sessions[si];
            if (s.liveDigest[w] <= 0) {
                if (s.wand[w].live && now - s.wand[w].lastSeen > kWandStaleS) {
                    s.wand[w].live = false;
                }
                s.laneDigestStart[w] = now;   // this lane's touch begins now (its clause clock)
            }
            ++s.liveDigest[w];
            s.lastSeenAny = now;
            NoteProvisional(s, w, *c, now);
        } else if (phase == PPBAPI::kPhaseEnd) {
            const int si = FindSession(c->actorFormId);
            // An End on a zero count is an ORPHAN (its Start was counted in a session since wiped): ignore it. A
            // Start and its End always map to the same lane (PPB >= 20102 keys digest identity on the source lane).
            if (si >= 0 && g_sessions[si].liveDigest[w] > 0) {
                --g_sessions[si].liveDigest[w];
            }
        } else {
            const int si = FindSession(c->actorFormId);
            if (si >= 0) {
                NoteProvisional(g_sessions[si], w, *c, now);
            }
        }

        // A phase change alters the lifecycle, so it always sweeps; Continue
        // ticks are throttled (PPB fires them at apiHz per live contact).
        const bool lifecycle = (phase != PPBAPI::kPhaseContinue);
        if (!lifecycle && now - s_lastSweepS < kSweepMinGapS) {
            return;
        }
        s_lastSweepS = now;
        Sweep(now);
    }
}

namespace PpbBridge {

    void InstallGestureSink();   // below, beside the grip grace

    void Install() {
        static std::atomic<bool> installed{ false };
        if (installed.exchange(true)) return;

        auto* messaging = SKSE::GetMessagingInterface();
        if (!messaging) {
            logger::error("[PPB-BRIDGE] SKSE messaging interface unavailable — bridge inert.");
            return;
        }

        PPBAPI::PpbMessage msg{};
        messaging->Dispatch(PPBAPI::PpbMessage::kGetTouchInterface, &msg, sizeof(msg), "PPB");
        if (!msg.GetApiFunction) {
            logger::info("[PPB-BRIDGE] PPB not installed (no reply to 'PPBT') — bridge inert; "
                         "everything else unaffected.");
            return;
        }
        auto* api = static_cast<PPBAPI::IPpbTouchInterface1*>(msg.GetApiFunction(1));
        if (!api) {
            logger::info("[PPB-BRIDGE] PPB present but does not speak interface revision 1 — "
                         "bridge inert.");
            return;
        }
        if (!api->AddTouchCallback(&OnPpbTouch)) {
            logger::error("[PPB-BRIDGE] PPB touch-callback table full — bridge inert.");
            return;
        }
        g_ppb      = api;
        g_ppbBuild = static_cast<int>(api->GetBuildNumber());
        logger::info("[PPB-BRIDGE] IPpbTouchInterface1 acquired (PPB build {}) — coalescer armed "
                     "(window {:.1f}s, update {:.1f}s, stale {:.1f}s, {} session slots, {} source lanes{}).",
                     g_ppbBuild, kWindowS, kUpdatePeriodS, kWandStaleS, kMaxSessions,
                     g_ppbBuild >= 20102 ? 4 : 2,
                     g_ppbBuild >= 20102 ? "" : " - PPB < 20102: head/genital share the hand lanes");
        InstallGestureSink();
    }

    int GetErectionLevel(std::uint32_t actorFormId)
{
    std::lock_guard<std::recursive_mutex> guard(g_lock);
    for (int i = 0; i < 16; ++i) {
        if (g_genLevel[i].fid == actorFormId) return g_genLevel[i].level;
    }
    return -1;
}

    // ★★ 2026-09-13 — THE CONTACT BEHIND A PUSH (the user: "there can't be a push without a contact, we just
    // need to look at that. be mindful that only core contact can do push/shove/stumble, and leg sweep is
    // always at the leg" · "we prevent the contact event and add it to the push/shove event").
    // Candidates = the player's contacts on her seen within kPushRecentS (a live flag alone is not evidence: a
    // lane can read live long after its touch ended - review 2026-09-13), from a source PPB can push with:
    //   push / shove / dropped : FINGER / PALM / FIST / HAND / WEAPON / OBJECT - PPB's push pressure
    //                            (PushStep.cpp: sourceKind <= Hand, a drawn weapon, an object when that knob is
    //                            on). NEVER the head ("THE PLAYER'S HEAD IS NOT A PUSH SOURCE") or the genital.
    //   sweeped                : any hand class, a GRAB, a weapon or an object - PPB's lift attribution
    //                            (sourceKind <= Object). Never the head or the genital.
    // WHERE on her (the user, 2026-09-13): a push / shove / stumble "should always be from thigh, pelvis, belly,
    // chest, back or head, a NPC can't be pushed by their hand or forearm, they would simply flail away" =
    // PPB slots 3 head · 4 spine0 · 5 spine1 · 6 spine2 (chest / back) · 8 thigh · 11 com (pelvis). A sweep is
    // "always at the leg" = 8 thigh · 9 calf · 10 foot. Nothing else is ever taken.
    // Ranked: still touching her now · then the most recently seen · then the touch that started most recently ·
    // then the SHALLOWER press (PPB: the pushed capsule "flees" the pushing hand; a resting hand sinks in).
    // ⚠ PPB fact to know (review): with pushStepTravelMode on, PPB itself can push from ANY slot, arms included.
    //   Such a push finds no contact here: its line goes out without the HOW, and the arm contact is not taken.
    // The winner's lane is TAKEN for kPushTakeS (RecordTake). Returns its 8 clause fields, or "" when none.
    // ★ PPB build 20105 names the pusher (PushReaction field 2, "R"/"L"): that hand's contact wins over the ranking below
    // whenever it qualifies (the user, 2026-09-13: "sure, sound better"). "" (older PPB, or no contact on record) = rank.
    std::string TakePushContact(std::uint32_t actorFormId, const std::string& kind, const std::string& wand) {
        std::lock_guard<std::recursive_mutex> guard(g_lock);
        const bool   legs = (kind == "sweeped");
        const double now  = NowS();
        const int    preferLane = (wand == "R") ? 0 : (wand == "L") ? 1 : -1;
        auto sourceOk = [legs](const WandEntry& e) {
            const int k = e.sourceKind;
            if (k == PPBAPI::kSourceHead || k == PPBAPI::kSourceGenital) return false;
            if (legs) return k <= PPBAPI::kSourceObject;
            // No OBJECT: the installed PPB_tuning ships pushStepObjectPush 0, so a held object never pushes.
            return k <= PPBAPI::kSourceHand || k == PPBAPI::kSourceWeapon;
        };
        auto classRank = [legs](const WandEntry& e) {
            if (legs) {
                return (e.slot == 8 || e.slot == 9 || e.slot == 10) ? 1 : -1;   // her legs only
            }
            // head · belly (spine0/1) · chest and back (spine2) · thigh · pelvis (com) - never her arms or hands
            return (e.slot == 3 || e.slot == 4 || e.slot == 5 || e.slot == 6 || e.slot == 8 || e.slot == 11) ? 1 : -1;
        };
        const WandEntry* best      = nullptr;
        int              bestLane  = -1;
        int              bestClass = -1;
        bool             bestLive  = false;
        bool             bestInSes = false;
        bool             bestPref  = false;
        auto consider = [&](const WandEntry& e, int lane, bool inSession) {
            if (!e.everSeen || !sourceOk(e) || now - e.lastSeen > kPushRecentS) return;
            const int  cls  = classRank(e);
            if (cls < 0) return;
            const bool live = inSession && e.live && now - e.lastSeen <= kWandStaleS;
            const bool pref = (lane == preferLane);
            if (best) {
                if (pref != bestPref) { if (!pref) return; }
                else if (cls != bestClass) { if (cls < bestClass) return; }
                else if (live != bestLive) { if (!live) return; }
                else if (e.lastSeen != best->lastSeen) { if (e.lastSeen < best->lastSeen) return; }
                // Two hands both on her merge in the same sweep (same lastSeen): the touch that STARTED most recently
                // is the likelier push, then the SHALLOWER press - PPB: the pushed capsule flees the pushing hand,
                // while a resting hand sinks in (verify 2026-09-13).
                else if (e.laneStart != best->laneStart) { if (e.laneStart < best->laneStart) return; }
                else if (e.distDeepest <= best->distDeepest) return;
            }
            best = &e; bestLane = lane; bestClass = cls; bestLive = live; bestInSes = inSession; bestPref = pref;
        };
        const int si = FindSession(actorFormId);
        if (si >= 0) {
            for (int l = 0; l < kLanes; ++l) consider(g_sessions[si].wand[l], l, true);
            // ★ The digest's own contact for a lane still touching her but not yet merged from raw (final verify
            // 2026-09-13, measured: PPB's walk engaged 0.38 / 0.61 s after contact, before the bridge had raw).
            for (int l = 0; l < kLanes; ++l) {
                if (g_sessions[si].liveDigest[l] > 0 && !g_sessions[si].wand[l].live) {
                    consider(g_sessions[si].prov[l], l, true);
                }
            }
        }
        for (const auto& r : g_recent) {
            if (r.fid != actorFormId || now - r.at > kPushRecentS) continue;
            for (int l = 0; l < kLanes; ++l) consider(r.wand[l], l, false);
        }
        // ★ PPB NAMED A HAND THAT PUSHED FROM A PART THAT CANNOT PUSH (the user, 2026-09-13: "i like your fix, implement").
        // With pushStepTravelMode PPB pushes from any slot - an arm, a forearm. The line keeps no HOW (arms cannot push, the
        // user's rule) but that hand's contact is still TAKEN, so it is not narrated as a separate touch on top of the push.
        // Only when the named hand's own contact did not qualify; a hand PPB named with no contact at all falls to the ranking.
        if (preferLane >= 0 && (!best || !bestPref)) {
            const WandEntry* named = nullptr;
            auto recentOf = [&](const WandEntry& e) {
                return e.everSeen && sourceOk(e) && now - e.lastSeen <= kPushRecentS;
            };
            if (si >= 0) {
                const Session& ses = g_sessions[si];
                if (recentOf(ses.wand[preferLane])) named = &ses.wand[preferLane];
                else if (ses.liveDigest[preferLane] > 0 && recentOf(ses.prov[preferLane])) named = &ses.prov[preferLane];
            }
            for (const auto& r : g_recent) {
                if (named) break;
                if (r.fid == actorFormId && now - r.at <= kPushRecentS && recentOf(r.wand[preferLane])) named = &r.wand[preferLane];
            }
            if (named) {
                RecordTake(actorFormId, preferLane, now + kPushTakeS, named->subRegion);
                logger::info("[PUSH-CONTACT] 0x{:08X} {}: PPB named lane {} but its contact is on slot {} (not a part that can "
                             "push) - contact TAKEN {:.1f}s, the line goes out without a HOW", actorFormId, kind, preferLane,
                             named->slot, kPushTakeS);
                return "";
            }
        }
        if (!best) {
            logger::info("[PUSH-CONTACT] 0x{:08X} {}: no recent pushing contact from the player - the line goes out without it",
                         actorFormId, kind);
            return "";
        }
        // Taken for kPushTakeS whether the session is open or already ended: the same hand returning to her
        // inside the push interaction must not be narrated as a new touch.
        RecordTake(actorFormId, bestLane, now + kPushTakeS, best->subRegion);
        std::string f[kClauseFields];
        FillEntry(f, *best, bestLane, now);
        std::string out;
        for (int i = 0; i < kClauseFields; ++i) {
            if (i) out += '|';
            out += f[i];
        }
        logger::info("[PUSH-CONTACT] 0x{:08X} {}: lane {} ({}, {}, class {}, PPB named '{}'{}) TAKEN {:.1f}s -> {}",
                     actorFormId, kind, bestLane, bestLive ? "live" : "recent",
                     bestInSes ? "session" : "ended session", bestClass, wand,
                     (preferLane >= 0 && !bestPref) ? " - that hand had no qualifying contact" : "", kPushTakeS, out);
        return out;
    }

    // ★ 2026-09-13 GESTURE TAKES - the two-hand undress (the user: an unequip must never "end up as a contact grab
    // event while it was an unequip event"). PPB_GestureUndressArm takes BOTH hand lanes on her; the End sets the
    // take to a short tail, because the grab contacts measurably outlive PPB's End by up to 0.49 s. The same take
    // machinery as a push, with sub -1: when it runs out a hand still on her restarts its lane clock and waits its
    // own dwell - it is never silently restored as "already said". HEAD and GENITAL lanes are not touched.
    // Overwrites the lanes' take (the End shortens the Arm's). A load or a scene pause clears every take.
    void TakeGestureLanes(std::uint32_t actorFormId, double secs) {
        std::lock_guard<std::recursive_mutex> guard(g_lock);
        if (!(secs >= 0.0)) secs = 0.0;
        if (secs > 30.0)    secs = 30.0;
        const double now = NowS();
        for (int l = 0; l < 2; ++l) {
            RecordTake(actorFormId, l, now + secs, -1, kTakeGesture);
        }
        logger::info("[GESTURE-TAKE] 0x{:08X}: both hand lanes taken for {:.1f}s", actorFormId, secs);
    }

    // ★★ 2026-09-13 THE GRIP GRACE (PPB build 20105 PPB_GestureUndressGrip; the user: "short grace, so if the second hand
    // grab close and a unequip event is detected, the grab contact event is hold").
    // PPB sends a Grip when ONE hand's grab lands on a worn piece - the first half of a two-hand undress, OR an ordinary
    // clothed grab (PPB cannot tell). That hand's lane is held for kGripGraceS: measured, the second hand grabs and PPB
    // arms the undress 0.32-0.87 s after the first grab (n=17), so an undress arms inside the grace and the Arm's take
    // keeps the hand quiet; an ordinary grab is narrated when the grace ends, its hold clock untouched.
    // Consumed HERE, in C++, not in Papyrus: PPB sends the Grip in the same frame as the grab's TouchStart, and a Papyrus
    // round trip could land after the 0.25 s breast window.
    constexpr double kGripGraceS = 1.0;

    void GripGrace(std::uint32_t fid, int lane) {
        std::lock_guard<std::recursive_mutex> guard(g_lock);
        const double now = NowS();
        const double tu  = TakenUntil(fid, lane);
        if (tu > now + kGripGraceS) return;                       // an Arm / push take already holds it longer
        const int kind = (tu > now) ? TakenKind(fid, lane) : static_cast<int>(kTakeGrip);
        RecordTake(fid, lane, now + kGripGraceS, -1, kind);       // (a running tail keeps its clock-restart rule)
        logger::info("[GRIP-GRACE] 0x{:08X} lane {}: held {:.1f}s (a grip on worn gear - an undress may follow)",
                     fid, lane, kGripGraceS);
    }

    // The grip ended without ever arming: give the hand back at once.
    void GripRelease(std::uint32_t fid, int lane) {
        std::lock_guard<std::recursive_mutex> guard(g_lock);
        const double now = NowS();
        for (auto& t : g_takes) {
            if (t.fid == fid && t.lane == lane && t.kind == kTakeGrip && t.until > now) {
                t.until = now;
                logger::info("[GRIP-GRACE] 0x{:08X} lane {}: released (the grip ended, no undress)", fid, lane);
            }
        }
    }

    // ★ V15 (fix list 41, 2026-09-13): the actor the last undress ARMED on. PPB sends UndressEnd(false, "gone") with NO
    // sender when her form is gone, so neither this sink nor Papyrus can tell whose 20 s Arm take to end - this can.
    // Read and written only under g_lock.
    std::uint32_t g_lastUndressFid = 0;

    // PPB's gesture bus, heard directly. PPB raises these from its own main-thread frame work: nothing here may queue a
    // task or call into the VM - only the take table, under the lock.
    class GestureSink : public RE::BSTEventSink<SKSE::ModCallbackEvent> {
    public:
        RE::BSEventNotifyControl ProcessEvent(const SKSE::ModCallbackEvent* ev,
                                              RE::BSTEventSource<SKSE::ModCallbackEvent>*) override {
            if (!ev || !ev->eventName.c_str()) return RE::BSEventNotifyControl::kContinue;
            const char* name = ev->eventName.c_str();
            if (_stricmp(name, "PPB_GestureUndressEnd") == 0) {
                std::lock_guard<std::recursive_mutex> guard(g_lock);
                if (ev->sender) {
                    // The normal End: Papyrus sets the short tail (UndressMuteTail). Only forget the armed actor.
                    if (ev->sender->GetFormID() == g_lastUndressFid) g_lastUndressFid = 0;
                } else if (g_lastUndressFid != 0) {
                    // The actor is gone: her hands are given back now instead of at the 20 s Arm take's end.
                    const std::uint32_t gone = g_lastUndressFid;
                    g_lastUndressFid = 0;
                    TakeGestureLanes(gone, 0.0);
                    logger::info("[GRIP-GRACE] 0x{:08X}: undress END with no sender (the actor is gone) - hand lanes released", gone);
                }
                return RE::BSEventNotifyControl::kContinue;
            }
            if (!ev->sender) return RE::BSEventNotifyControl::kContinue;
            const bool grip    = _stricmp(name, "PPB_GestureUndressGrip") == 0;
            const bool gripEnd = !grip && _stricmp(name, "PPB_GestureUndressGripEnd") == 0;
            const bool arm     = !grip && !gripEnd && _stricmp(name, "PPB_GestureUndressArm") == 0;
            if (!grip && !gripEnd && !arm) return RE::BSEventNotifyControl::kContinue;
            const std::uint32_t fid = ev->sender->GetFormID();
            if (fid == kPlayerFormId) return RE::BSEventNotifyControl::kContinue;
            if (arm) {
                // The undress armed: both hands, the same 20 s the Papyrus handler asks for - but from this frame.
                std::lock_guard<std::recursive_mutex> guard(g_lock);
                const double now = NowS();
                for (int l = 0; l < 2; ++l) {
                    if (TakenUntil(fid, l) < now + 20.0) RecordTake(fid, l, now + 20.0, -1, kTakeGesture);
                }
                g_lastUndressFid = fid;
                logger::info("[GRIP-GRACE] 0x{:08X}: undress ARMED - both hand lanes held", fid);
                return RE::BSEventNotifyControl::kContinue;
            }
            // "<hand R|L>|<name>|<slotMask>|<isDD>|<class>|<capsule>[|<armed>|<reason>]"
            const std::string s(ev->strArg.c_str() ? ev->strArg.c_str() : "");
            if (s.empty()) return RE::BSEventNotifyControl::kContinue;
            const int lane = (s[0] == 'L' || s[0] == 'l') ? 1 : 0;
            if (grip) {
                // ★ NO GRACE ON THE THROAT (the user, 2026-09-13: "remove the choke grace"). PPB's undress candidates for a
                // neck grab include body slot 32, so nearly every front-neck grab on a dressed NPC is a "grip on worn
                // gear" - a grace there would arm every choke a second late. Field 5 = the capsule under the hand; the
                // choke arms on exactly "front neck" (VRTouch_TriggerLib.V3IsNeckFrontPart).
                std::size_t cp = 0;
                for (int k = 0; k < 5 && cp != std::string::npos; ++k) {
                    cp = s.find('|', cp);
                    if (cp != std::string::npos) ++cp;
                }
                if (cp != std::string::npos) {
                    std::size_t ce = s.find('|', cp);
                    std::string cap = s.substr(cp, ce == std::string::npos ? std::string::npos : ce - cp);
                    std::transform(cap.begin(), cap.end(), cap.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
                    if (cap.find("front neck") != std::string::npos) {
                        logger::info("[GRIP-GRACE] 0x{:08X} lane {}: grip on the front neck - no grace (the choke arms at once)", fid, lane);
                        return RE::BSEventNotifyControl::kContinue;
                    }
                }
                GripGrace(fid, lane);
                return RE::BSEventNotifyControl::kContinue;
            }
            // GripEnd: field 6 = armed. armed 1 = the UndressEnd carries the outcome - leave the Arm's take alone.
            std::size_t pos = 0;
            int field = 0;
            while (field < 6 && pos != std::string::npos) {
                pos = s.find('|', pos);
                if (pos != std::string::npos) { ++pos; ++field; }
            }
            const bool armed = (pos != std::string::npos && pos < s.size() && s[pos] == '1');
            if (!armed) GripRelease(fid, lane);
            return RE::BSEventNotifyControl::kContinue;
        }
    };
    GestureSink g_gestureSink;

    void InstallGestureSink() {
        auto* src = SKSE::GetModCallbackEventSource();
        if (!src) {
            logger::error("[GRIP-GRACE] SKSE mod-event source unavailable - no grip grace (grabs narrate as before).");
            return;
        }
        src->AddEventSink(&g_gestureSink);
        logger::info("[GRIP-GRACE] listening to PPB_GestureUndressGrip / GripEnd / UndressArm (grace {:.1f}s{}).",
                     kGripGraceS, g_ppbBuild >= 20105 ? "" : " - PPB < 20105 sends no Grip, only the Arm take applies");
    }

void SetPaused(bool paused) {
        std::lock_guard<std::recursive_mutex> guard(g_lock);
        const bool was = s_paused.exchange(paused);
        if (was == paused) {
            return;
        }
        if (paused) {
            // Same rule as a cell change: drop silently. Papyrus has already
            // unregistered its VRTE sinks for the scene, so an End would be
            // both unheard and meaningless.
            ClearSessionsSilently("scene started — bridge paused");
        }
        logger::info("[PPB-BRIDGE] {} (scene suppression).", paused ? "PAUSED" : "RESUMED");
    }

    void Reset() {
        std::lock_guard<std::recursive_mutex> guard(g_lock);
        for (auto& r : g_recent) {
            r = RecentSession{};
        }
        for (auto& t : g_takes) {
            t = PushTake{};
        }
        int cleared = 0;
        for (auto& s : g_sessions) {
            if (s.active) {
                s = Session{};
                ++cleared;
            }
        }
        s_lastCellId = 0;   // re-baseline the transition guard for the new game/save
        if (cleared > 0) {
            logger::info("[PPB-BRIDGE] reset — {} live session(s) cleared (load boundary, "
                         "the ledger rule: no events fired).", cleared);
        }
    }

}  // namespace PpbBridge
