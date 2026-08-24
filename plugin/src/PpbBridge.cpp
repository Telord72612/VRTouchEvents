#include "PCH.h"
#include "PpbBridge.h"
#include "PpbTouchAPI.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
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
    //   numArg    : PRIMARY contact duration in seconds (on End: the session's
    //               total live duration)
    //   strArg    : EXACTLY 16 pipe-separated fields; '|' inside a name is
    //               replaced with '/' so no field can ever contain '|':
    //      0 W1     primary wand: "L" or "R"
    //      1 SRC1   primary source: FINGER/PALM/FIST/HAND/GRAB/WEAPON/OBJECT
    //      2 NAME1  weapon/object base name for WEAPON/OBJECT, else ""
    //      3 PART1  primary capsule name as PPB reports it ("BREAST R", "chest ring")
    //      4 SUB1   primary sub-region NAME from SubRegionName() ("Breast", "In mouth")
    //      5 DEP1   primary depth 0-3 (SubRegionDepthLevel), decimal string
    //      6 DIST1  deepest distU reached this session for the primary part, "%.2f"
    //      7 W2     secondary wand or "" if only one hand
    //      8 SRC2   secondary source or ""
    //      9 NAME2  secondary weapon/object name or ""
    //     10 PART2  secondary capsule name or ""
    //     11 SUB2   secondary sub-region name or ""
    //     12 DEP2   secondary depth or ""
    //     13 DIST2  secondary deepest distU or ""
    //     14 SKEL   "human"/"argonian"/"khajiit"/"draenei"
    //     15 ESC    "1" if this is an escalation re-emit, else "0"
    constexpr const char* kEvContact = "VRTE_Contact";
    constexpr const char* kEvUpdate  = "VRTE_ContactUpdate";
    constexpr const char* kEvEnd     = "VRTE_ContactEnd";

    // ── Tunables (the user's rules; see the header banner) ─────────────────────
    constexpr double kSweepMinGapS  = 0.2;   // min gap between sweeps (callback tick guard)
    constexpr double kWindowS       = 1.0;   // uniform coalescer window on first contact
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
    constexpr double kSessionRetireS = 1.5;  // a lingering dead session older than this is
                                             //   retired when a NEW touch on that actor starts
    constexpr int    kMaxSessions   = 8;     // session cap (LRU-evict oldest, End emitted)
    constexpr int    kRawBufMax     = 32;    // GetRawContacts buffer
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
        char          bodyPart[48]   = {};
        char          sourceName[48] = {};
        char          skeleton[12]   = {};
    };

    struct Session {
        bool          active          = false;
        std::uint32_t fid             = 0;
        WandEntry     wand[2];               // index = PpbTouchContact::wand (0=RIGHT, 1=LEFT)
        WandEntry     windowBest[2];         // best capsule seen PRE-EMIT (rule 2: a transient
                                             //   high-priority part must survive a downgrade)
        int           liveDigest[2]   = {0, 0};  // PPB digest Start/End balance per wand — the
                                             //   AUTHORITATIVE "is this hand still on her"
        double        startTime       = 0.0;
        double        windowDeadline  = 0.0; // startTime + kWindowS
        int           emittedPriority = -1;  // -1 until the first VRTE_Contact
        double        lastUpdateEmit  = 0.0;
        double        lastSeenAny     = 0.0;
        int           sweepsSeen      = 0;   // sweeps run while this session was open —
                                             // 0 means the sweep never even looked
    };

    Session g_sessions[kMaxSessions];
    int     s_cand[kMaxSessions][2];         // per-sweep winning raw-contact index, -1 = none
    double  s_lastSweepS   = 0.0;
    std::uint32_t s_lastCellId = 0;          // player's cell, for the transition guard
    std::atomic<bool> s_paused{ false };     // scene suppression (SetScenePaused)

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
        // ★ SHIPPED in PPB 2.0.0 (build 20000): the player's own genitals as a
        // touch source. PPB gates emission itself on GenitalProbe::IsExposed
        // (skin carries slot 52 AND no worn armor on 52), so a dressed or
        // schlong-less player produces NO contacts at all — VRTE adds no gate
        // of its own (an earlier VRTE-side slot-52 test was exactly inverted
        // against this one and would have dropped every contact).
        case PPBAPI::kSourceGenital: return "GENITAL";
        default:                    return "HAND";
        }
    }

    const char* SubName(int subRegion) {
        const char* n = g_ppb ? g_ppb->SubRegionName(subRegion) : nullptr;
        return n ? n : "";
    }

    // Fill one wand's 7 strArg fields (W/SRC/NAME/PART/SUB/DEP/DIST) into f[0..6].
    void FillEntry(std::string* f, const WandEntry& e, int wandIdx) {
        // ★ INTEGRATION.md on kSourceGenital: "wand is MEANINGLESS and reads 0.
        // It is not a hand. Switch on sourceKind, never on wand." Reporting it as
        // "R" would have been an outright lie in the payload — and W1 is what the
        // narration and the choke-hand latch read. "G" says what it is.
        // (Safe for the two L/R consumers: both sit behind src=="GRAB", which a
        // genital contact can never be.)
        f[0] = (e.sourceKind == PPBAPI::kSourceGenital) ? "G"
             : (wandIdx == 1)                          ? "L"
                                                       : "R";
        f[1] = SourceStr(e.sourceKind);
        // ★ GENITAL joins WEAPON/OBJECT as a source that NAMES ITSELF: PPB puts
        // "shaft" or "tip" in sourceName (which segment of him made contact),
        // exactly as a weapon carries its own name. Dropping it here would have
        // thrown that detail away before Papyrus ever saw it.
        f[2] = (e.sourceKind == PPBAPI::kSourceWeapon ||
                e.sourceKind == PPBAPI::kSourceObject ||
                e.sourceKind == PPBAPI::kSourceGenital)
                   ? Sanitize(e.sourceName) : "";
        f[3] = Sanitize(e.bodyPart);
        f[4] = Sanitize(SubName(e.subRegion));
        f[5] = std::to_string(e.depth);
        char d[32];
        std::snprintf(d, sizeof(d), "%.2f", e.distDeepest);
        f[6] = d;
    }

    std::string BuildStrArg(const WandEntry& prim, int primIdx,
                            const WandEntry* secd, int secIdx, bool escalation) {
        std::string f[16];                    // 7..13 stay "" when one-handed
        FillEntry(&f[0], prim, primIdx);
        if (secd) {
            FillEntry(&f[7], *secd, secIdx);
        }
        f[14] = Sanitize(prim.skeleton);
        f[15] = escalation ? "1" : "0";

        std::string out;
        out.reserve(192);
        for (int i = 0; i < 16; ++i) {
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
    void ApplyContact(WandEntry& e, const PPBAPI::PpbTouchContact& c, double now) {
        const bool samePart = e.live && e.slot == c.slot && e.child == c.child &&
                              e.leftTwin == c.leftTwin;
        e.distDeepest = samePart ? (std::min)(e.distDeepest, c.distU) : c.distU;
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
        s_cand[idx][0] = -1;
        s_cand[idx][1] = -1;
        return idx;
    }

    // Primary = highest-priority live wand entry (EntryBeats tie-breaks; wand R
    // is the incumbent on a full tie). Returns -1 if neither is live.
    int PickPrimaryLive(const Session& s) {
        const bool l0 = s.wand[0].live, l1 = s.wand[1].live;
        if (l0 && l1) return EntryBeats(s.wand[1], s.wand[0]) ? 1 : 0;
        if (l0)       return 0;
        if (l1)       return 1;
        return -1;
    }

    void EmitSessionEvent(const char* evName, const Session& s, int p, int sec,
                          bool escalation, float numArg) {
        const WandEntry& prim = s.wand[p];
        const WandEntry* secd = (sec >= 0) ? &s.wand[sec] : nullptr;
        const std::string strArg = BuildStrArg(prim, p, secd, sec, escalation);
        SendModEvent(evName, strArg, numArg, s.fid);
    }

    // Session over: emit VRTE_ContactEnd from the retained (everSeen) snapshots.
    // numArg = the span the touch was actually live (lastSeenAny - startTime),
    // NOT now - startTime — the End can arrive up to the stale window late.
    // A session that never emitted a Contact (touch shorter than the window)
    // sends NOTHING — Papyrus never saw it, so an End would just be noise.
    void EmitEnd(const Session& s, double /*now*/) {
        int p = -1;
        if (s.wand[0].everSeen && s.wand[1].everSeen) {
            p = EntryBeats(s.wand[1], s.wand[0]) ? 1 : 0;
        } else if (s.wand[0].everSeen) {
            p = 0;
        } else if (s.wand[1].everSeen) {
            p = 1;
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
            logger::info("[PPB-BRIDGE] ⛔ End with NO raw contact ever merged "
                         "fid=0x{:08X} liveDigest=[{},{}] sweeps-since-open={} "
                         "age={:.2f}s — the digest saw this touch but the raw "
                         "stream never did in {:.1f}s. NOTHING was sent to Papyrus.",
                         s.fid, s.liveDigest[0], s.liveDigest[1], s.sweepsSeen,
                         static_cast<float>(s.lastSeenAny - s.startTime),
                         static_cast<float>(kRawGraceS));
            return;
        }
        const float total = static_cast<float>(s.lastSeenAny - s.startTime);
        if (s.emittedPriority < 0) {
            logger::info("[PPB-BRIDGE] End (sub-window, unemitted) fid=0x{:08X} part='{}' "
                         "total={:.2f}s — no event sent",
                         s.fid, s.wand[p].bodyPart, total);
            return;
        }
        const int sec = s.wand[1 - p].everSeen ? (1 - p) : -1;
        EmitSessionEvent(kEvEnd, s, p, sec, false, total);
        logger::info("[PPB-BRIDGE] End fid=0x{:08X} part='{}' total={:.2f}s",
                     s.fid, s.wand[p].bodyPart, total);
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
            s_cand[i][0] = -1;
            s_cand[i][1] = -1;
        }

        // ★ Erection-byte harvest (see GenLevelEntry above). Reads _reserved[0]
        // on EVERY raw contact — 0 on today's PPB (tail is contractually zero),
        // genLevel+1 once the handoff request ships. Done before the wand guard
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

        // Pass A — pick each (actor, wand)'s winning raw contact this sweep.
        // GRAB wins a contested wand slot outright; otherwise priority decides
        // (ContactBeats keeps the incumbent on a full tie).
        for (int i = 0; i < n; ++i) {
            const auto& c = buf[i];
            if (c.toucherFormId != kPlayerFormId || c.actorFormId == 0 || c.wand > 1) {
                continue;
            }
            const int si = FindSession(c.actorFormId);
            if (si < 0) {
                continue;   // no digest session yet — the Start callback owns creation
            }
            int& cand = s_cand[si][c.wand];
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
            for (int w = 0; w < 2; ++w) {
                if (s_cand[si][w] >= 0) {
                    ApplyContact(s.wand[w], buf[s_cand[si][w]], now);
                    s.lastSeenAny = now;
                    // Pre-emit (rule 2 — priority overrides duration): remember
                    // the BEST capsule this wand has shown during the window, so
                    // breast 0.3 s -> slid to chest ring still emits "breast".
                    if (s.emittedPriority < 0 &&
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
            for (int w = 0; w < 2; ++w) {
                if (!s.wand[w].live) {
                    continue;
                }
                const bool digestDone = (s.liveDigest[w] <= 0);
                const bool rawStale   = (now - s.wand[w].lastSeen > kWandStaleS);
                if (digestDone && rawStale) {
                    s.wand[w].live = false;
                }
            }
            const int p = PickPrimaryLive(s);
            if (p < 0) {
                // ★ liveDigest is PPB's AUTHORITATIVE "is this hand still on her"
                // (this file says so 30 lines up, and the wand-clearing rule above
                // already refuses to act on raw alone). Honour it HERE too: while
                // the digest says a hand is on her, a missing raw entry means raw
                // has not caught up yet — not that the touch ended. Bounded by
                // kRawGraceS so a stuck digest cannot pin a session open forever,
                // and the give-up still logs (see EmitEnd) so a genuine raw-stream
                // gap is still reported rather than silently waited out.
                const bool digestLive = (s.liveDigest[0] > 0 || s.liveDigest[1] > 0);
                if (digestLive && (now - s.startTime) < kRawGraceS) {
                    continue;   // raw is one frame behind — give it a moment
                }
                EmitEnd(s, now);
                s = Session{};
                continue;
            }
            const int sec     = s.wand[1 - p].live ? (1 - p) : -1;
            const int bestPri = s.wand[p].priority;

            if (s.emittedPriority < 0) {
                // (a) coalescer window: first emit once the window has passed.
                if (now >= s.windowDeadline) {
                    // Rule 2 — a higher-priority capsule seen transiently during
                    // the window beats the one currently touched: swap its
                    // snapshot back in so IT is the emitted event. The next
                    // sweep's ApplyContact resumes current-capsule tracking.
                    for (int w = 0; w < 2; ++w) {
                        WandEntry&       lv = s.wand[w];
                        const WandEntry& wb = s.windowBest[w];
                        if (lv.live && wb.everSeen && EntryBeats(wb, lv)) {
                            const double seen = lv.lastSeen;
                            lv          = wb;
                            lv.live     = true;
                            lv.lastSeen = seen;  // stale-tracking keeps the REAL last sighting
                        }
                    }
                    const int   ep   = PickPrimaryLive(s);   // re-pick after the swap
                    const int   esec = s.wand[1 - ep].live ? (1 - ep) : -1;
                    // numArg = the SESSION's accumulated duration, not PPB's
                    // per-contact durationS: after a region handover the new
                    // digest contact's clock has restarted, but the touch has
                    // been going the whole time — and VRTE's dwell policy is
                    // measured against the interaction, not the capsule visit.
                    const float sdur = static_cast<float>(now - s.startTime);
                    EmitSessionEvent(kEvContact, s, ep, esec, false, sdur);
                    s.emittedPriority = s.wand[ep].priority;
                    s.lastUpdateEmit  = now;
                    logger::info("[PPB-BRIDGE] Contact fid=0x{:08X} part='{}' sub={} pri={} "
                                 "src={} sec={} dur={:.2f}s",
                                 s.fid, s.wand[ep].bodyPart, s.wand[ep].subRegion, s.emittedPriority,
                                 SourceStr(s.wand[ep].sourceKind), esec >= 0 ? "yes" : "no", sdur);
                }
            } else if (bestPri > s.emittedPriority) {
                // (b) escalation: strictly higher priority fires IMMEDIATELY.
                EmitSessionEvent(kEvContact, s, p, sec, true,
                                 static_cast<float>(now - s.startTime));
                s.emittedPriority = bestPri;
                s.lastUpdateEmit  = now;
                logger::info("[PPB-BRIDGE] ESCALATION fid=0x{:08X} part='{}' sub={} pri={}",
                             s.fid, s.wand[p].bodyPart, s.wand[p].subRegion, bestPri);
            } else if (now - s.lastUpdateEmit >= kUpdatePeriodS) {
                // (c) heartbeat while the session lives — carries the session
                // duration so Papyrus's pending dwell-waits can mature.
                const float sdur = static_cast<float>(now - s.startTime);
                EmitSessionEvent(kEvUpdate, s, p, sec, false, sdur);
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
    void OnPpbTouch(const PPBAPI::PpbTouchContact* c, int phase) {
        if (!g_ppb || !c || c->toucherFormId != kPlayerFormId ||
            c->actorFormId == 0 || c->wand > 1 || s_paused.load()) {
            return;
        }
        const double now = NowS();
        const int    w   = c->wand;

        if (phase == PPBAPI::kPhaseStart) {
            // A session lingers after the last contact (no tick source once PPB
            // stops calling us — see the note above), so a genuinely NEW touch
            // must retire the stale one rather than resume it with a spent
            // window and a stale accumulated duration.
            const int old = FindSession(c->actorFormId);
            if (old >= 0 && g_sessions[old].liveDigest[0] <= 0 &&
                g_sessions[old].liveDigest[1] <= 0 &&
                now - g_sessions[old].lastSeenAny > kSessionRetireS) {
                EmitEnd(g_sessions[old], now);
                g_sessions[old] = Session{};
            }
            const int si = OpenSession(c->actorFormId, now);
            ++g_sessions[si].liveDigest[w];
            g_sessions[si].lastSeenAny = now;
        } else if (phase == PPBAPI::kPhaseEnd) {
            const int si = FindSession(c->actorFormId);
            if (si >= 0 && g_sessions[si].liveDigest[w] > 0) {
                --g_sessions[si].liveDigest[w];
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
        g_ppb = api;
        logger::info("[PPB-BRIDGE] IPpbTouchInterface1 acquired (PPB build {}) — coalescer armed "
                     "(window {:.1f}s, update {:.1f}s, stale {:.1f}s, {} session slots).",
                     api->GetBuildNumber(), kWindowS, kUpdatePeriodS, kWandStaleS, kMaxSessions);
    }

    int GetErectionLevel(std::uint32_t actorFormId)
{
    for (int i = 0; i < 16; ++i) {
        if (g_genLevel[i].fid == actorFormId) return g_genLevel[i].level;
    }
    return -1;
}

void SetPaused(bool paused) {
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
