#include "PCH.h"
#include "CBPCHook.h"

#include <atomic>
#include <chrono>
#include <string>

namespace logger = SKSE::log;

namespace {
    // ── The Papyrus mod event VRTouchEvents subscribes to ──────────────────────
    //   eventName : "VRTouchEvents_CBPCTouch"
    //   sender    : the touched NPC actor (Form)
    //   strArg    : "<WAND>|<SOURCE>|<NODE>"   e.g. "RIGHT|WEAPON|CME Spine2 [Spn2]"
    //                 WAND   = LEFT | RIGHT | BOTH | UNKNOWN
    //                 SOURCE = HAND | WEAPON
    //                 NODE   = the CBPC node string (same as the stock nodeName)
    //   numArg    : compact code — ones digit = wand (1=RIGHT,2=LEFT,3=BOTH,0=UNK),
    //               tens digit = source (0=HAND,1=WEAPON). So 1=right hand, 2=left
    //               hand, 11=right weapon, 12=left weapon, 13=both weapons.
    //               isWeapon = numArg >= 10 ;  wand = (numArg as Int) % 10
    constexpr const char* kEventName = "VRTouchEvents_CBPCTouch";

    // ── cbp.dll RVAs (version-specific; guarded by a call-site signature check) ──
    // Reverse-engineered from cbp.pdb + dumpbin disasm (tools/diadump/cbp_disasm.txt).
    constexpr std::uintptr_t kRVA_ThingUpdate_CallSite = 0x19011;  // call ?update@Thing@@...
    constexpr std::uintptr_t kRVA_Haptic_CallSite1     = 0xA384;   // call HandHapticFeedbackEffect (cl=1 -> LEFT)
    constexpr std::uintptr_t kRVA_Haptic_CallSite2     = 0xA398;   // call HandHapticFeedbackEffect (cl=0 -> RIGHT)
    constexpr std::uintptr_t kThingBoneNameOffset      = 0x40;     // Thing::boneName (StringCache::Ref == const char*)
    // Expected call TARGETS (function RVAs) — the decoded rel32 of each site must
    // equal base+these, so a different cbp.dll layout can't mis-route the hook.
    constexpr std::uintptr_t kRVA_ThingUpdate_Fn       = 0x65740;  // ?update@Thing@@
    constexpr std::uintptr_t kRVA_Haptic_Fn            = 0x86F0;   // ?HandHapticFeedbackEffect@@
    // WEAPON collision: Thing::update's call to the triangle-mesh test (separate
    // from the hand test; weapons fire NO haptic, so this is the only weapon
    // signal). Call site is inside Thing::update -> tl_thing is valid.
    constexpr std::uintptr_t kRVA_Weapon_CallSite      = 0x678E1;  // call IsItCollidingTriangleToAffectedNodes
    constexpr std::uintptr_t kRVA_Weapon_Fn            = 0xA3B0;   // ?IsItCollidingTriangleToAffectedNodes@Collision@@

    // First bytes of each target function on the reverse-engineered cbp.dll build
    // (dumped from cbp.dll: SizeOfImage 0x124000). Used to verify the build WITHOUT
    // relying on the call-site targets, so we can chain on top of another plugin's
    // hook. Body bytes aren't touched by call-site hooks, so these stay stable.
    constexpr std::uint8_t kPrologue_ThingUpdate[8] = { 0x48, 0x8B, 0xC4, 0x55, 0x53, 0x56, 0x57, 0x41 };
    constexpr std::uint8_t kPrologue_Haptic[8]      = { 0x48, 0x83, 0xEC, 0x38, 0x48, 0x8B, 0x05, 0xE5 };
    constexpr std::uint8_t kPrologue_Triangle[8]    = { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x10, 0x4C };

    // Original targets recovered by write_call (the rel32 the call site held).
    using ThingUpdateFn = void (*)(void* thiz, RE::Actor* actor, void* m1, void* m2);
    using HapticFn      = void (*)(bool isLeft);
    // Weapon test: all by-value structs (CollisionConfigs, 148B) pass by hidden
    // pointer in the x64 ABI, so every arg is a pointer or bool -> void*/bool.
    using TriangleFn    = bool (*)(void* thiz, void* p0, void* p1, void* p2, void* p3,
                                   void* cfg, bool b5, bool b6, bool b7);
    ThingUpdateFn s_origThingUpdate = nullptr;
    HapticFn      s_origHaptic      = nullptr;
    TriangleFn    s_origTriangle    = nullptr;

    // Scene shutdown flag (set from Papyrus via CBPCHook::SetScenePaused). When
    // true, the haptic/weapon hooks skip firing VRTouchEvents' mod event but
    // STILL call cbp.dll's original (collision/physics/haptic unaffected). This
    // kills the residual per-touch task-post + event-dispatch during a SexLab/
    // OStim scene. VRTouchEvents-only — does not alter cbp.dll or any chained hook.
    std::atomic<bool> g_sceneSuppress{ false };

    // Set by the Thing::update hook; read by the haptic hook (nested call, same
    // worker thread). CBPC's parallel_for runs one actor per worker thread and
    // calls Thing::update -> IsItColliding -> HandHapticFeedbackEffect inline.
    // tl_inUpdate gates the haptic hook to ONLY the genuine Thing::update path:
    // the same haptic ALSO fires via CheckPelvisCollision (pelvis/anal), a
    // SIBLING path we don't hook, where tl_thing would be stale (possibly freed)
    // -> dangling deref / CTD. Require tl_inUpdate before touching tl_thing.
    thread_local void*      tl_thing    = nullptr;
    thread_local RE::Actor* tl_actor    = nullptr;
    thread_local bool       tl_inUpdate = false;

    // Per-actor weapon-touch throttle. CBPC runs one actor per worker thread, so a
    // single shared slot would coalesce weapon events across NPCs touched at once
    // (a crowd / melee) and starve all but one. Keying by actor FormID gives each
    // NPC its own ~4/sec cadence. Relaxed atomics, lock-free: a rare find/claim
    // race only costs one extra (benign) event. (Hand touches are already
    // per-wand via a 2-slot array, so only the weapon path needed this.)
    struct WpnThrottleSlot {
        std::atomic<std::uint32_t> fid{ 0 };
        std::atomic<std::int64_t>  ms { 0 };
    };
    constexpr int      kWpnThrottleSlots = 8;
    WpnThrottleSlot    g_wpnThrottle[kWpnThrottleSlots];

    // Reserve/return this actor's throttle slot and report whether enough time has
    // passed since its last weapon event. gapMs = the throttle interval.
    bool WeaponThrottlePasses(std::uint32_t fid, std::int64_t nowMs, std::int64_t gapMs) {
        int  slot       = -1;
        int  stalestIdx = 0;
        std::int64_t stalestMs = nowMs;
        for (int i = 0; i < kWpnThrottleSlots; ++i) {
            if (g_wpnThrottle[i].fid.load(std::memory_order_relaxed) == fid) { slot = i; break; }
            const auto sms = g_wpnThrottle[i].ms.load(std::memory_order_relaxed);
            if (sms < stalestMs) { stalestMs = sms; stalestIdx = i; }
        }
        if (slot < 0) {
            // New actor: claim the least-recently-used slot. Its old ms is the
            // stalest, so the staleness check below naturally lets the first event through.
            slot = stalestIdx;
            g_wpnThrottle[slot].fid.store(fid, std::memory_order_relaxed);
        }
        const auto prev = g_wpnThrottle[slot].ms.load(std::memory_order_relaxed);
        if (nowMs - prev > gapMs) {
            g_wpnThrottle[slot].ms.store(nowMs, std::memory_order_relaxed);
            return true;
        }
        return false;
    }

    // --- Player-hit tracker (weapon-touch combat-hit gate) -----------------
    // Records when the PLAYER deals damage to an NPC, so the weapon-touch path
    // can tell a real combat hit (damage) from a deliberate gentle blade-rest
    // (no damage). Written on the main thread (the TESHitEvent sink), read from
    // the Papyrus VM (WasPlayerHitRecently) — a lock-free atomic ring, same
    // pattern as the weapon throttle above; a rare slot race only costs a benign
    // miss. Gentle CBPC contact deals no damage -> raises no TESHitEvent -> never
    // recorded -> still reacts (so resting steel on a yielding enemy still works).
    struct HitSlot {
        std::atomic<std::uint32_t> fid{ 0 };
        std::atomic<std::int64_t>  ms { 0 };
    };
    constexpr int kHitSlots = 16;
    HitSlot       g_playerHits[kHitSlots];

    std::int64_t NowMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now().time_since_epoch()).count();
    }

    void RecordPlayerHit(std::uint32_t fid) {
        const auto now = NowMs();
        int slot = -1, stalestIdx = 0;
        std::int64_t stalestMs = now;
        for (int i = 0; i < kHitSlots; ++i) {
            if (g_playerHits[i].fid.load(std::memory_order_relaxed) == fid) { slot = i; break; }
            const auto m = g_playerHits[i].ms.load(std::memory_order_relaxed);
            if (m < stalestMs) { stalestMs = m; stalestIdx = i; }
        }
        if (slot < 0) {
            slot = stalestIdx;
            g_playerHits[slot].fid.store(fid, std::memory_order_relaxed);
        }
        g_playerHits[slot].ms.store(now, std::memory_order_relaxed);
    }

    // Record every hit where the PLAYER is the aggressor and an ACTOR is the
    // target. Fires on the main thread (script event source).
    class PlayerHitSink : public RE::BSTEventSink<RE::TESHitEvent> {
    public:
        static PlayerHitSink* GetSingleton() {
            static PlayerHitSink s;
            return &s;
        }
        RE::BSEventNotifyControl ProcessEvent(const RE::TESHitEvent* ev,
                                              RE::BSTEventSource<RE::TESHitEvent>*) override {
            if (ev && ev->cause && ev->target) {
                auto* pc = RE::PlayerCharacter::GetSingleton();
                if (pc && ev->cause.get() == pc) {
                    if (auto* victim = ev->target->As<RE::Actor>(); victim) {
                        RecordPlayerHit(victim->GetFormID());
                    }
                }
            }
            return RE::BSEventNotifyControl::kContinue;
        }
    };

    // Our own trampoline, allocated NEAR cbp.dll so the 5-byte call relay's
    // rel32 can reach it (cbp.dll may be >2GB from the game-module trampoline).
    SKSE::Trampoline s_cbpTramp{ "VRTouchEvents_cbp_tramp" };

    // wand string + numeric code paired so the event packs both forms.
    struct Wand { const char* str; int code; };

    // The game string cache stores a BSFixedString / StringCache::Ref as a
    // direct const char* to the interned chars (header at negative offsets).
    const char* ThingBoneName(void* thing) {
        if (!thing) return "";
        const char* s = *reinterpret_cast<const char* const*>(
            reinterpret_cast<const std::byte*>(thing) + kThingBoneNameOffset);
        return s ? s : "";
    }

    // Worker-thread -> main-thread handoff. Papyrus mod events MUST be raised on
    // the main thread; the hooks run on CBPC worker threads. We snapshot the
    // touch (wand/source/node-copy/formID) and post a main-thread task that looks
    // up the actor and fires the event. node is copied into a std::string up front
    // so we never deref CBPC's string cache off-thread or after the touch ends.
    void FireTouchEvent(const Wand& wand, bool isWeapon, std::string node, std::uint32_t fid) {
        auto* task = SKSE::GetTaskInterface();
        if (!task) {
            return;
        }
        std::string strArg = std::string(wand.str) + "|" + (isWeapon ? "WEAPON" : "HAND") + "|" + std::move(node);
        const float numArg = static_cast<float>((isWeapon ? 10 : 0) + wand.code);

        task->AddTask([strArg = std::move(strArg), numArg, fid]() {
            auto* src = SKSE::GetModCallbackEventSource();
            if (!src) {
                return;
            }
            SKSE::ModCallbackEvent ev{};
            ev.eventName = kEventName;
            ev.strArg    = strArg.c_str();
            ev.numArg    = numArg;
            ev.sender    = fid ? RE::TESForm::LookupByID(fid) : nullptr;
            src->SendEvent(&ev);
        });
    }

    void HookedThingUpdate(void* thiz, RE::Actor* actor, void* m1, void* m2) {
        // Save/restore so nested or reentrant updates can't leak context.
        void* prevT = tl_thing; RE::Actor* prevA = tl_actor; bool prevIn = tl_inUpdate;
        tl_thing = thiz; tl_actor = actor; tl_inUpdate = true;
        if (s_origThingUpdate) {
            s_origThingUpdate(thiz, actor, m1, m2);
        }
        tl_thing = prevT; tl_actor = prevA; tl_inUpdate = prevIn;
    }

    void HookedHaptic(bool isLeft) {
        // Worker-thread context: read-only field access + a throttled main-thread
        // task post (the task interface is thread-safe). Throttle per-wand to
        // ~4 touches/sec so sustained contact doesn't flood the task queue.
        // Only act on collisions that arrived through the hooked Thing::update
        // path. The pelvis/anal sibling path (CheckPelvisCollision -> IsItColliding)
        // hits this same haptic with a STALE tl_thing -> skip it (no deref).
        void* thing = tl_inUpdate ? tl_thing : nullptr;
        // Scene shutdown: skip our event entirely while paused (orig haptic below
        // still runs, so cbp.dll's controller rumble is unaffected).
        if (thing && !g_sceneSuppress.load(std::memory_order_relaxed)) {
            static std::atomic<std::int64_t> lastMs[2] = { 0, 0 };
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now().time_since_epoch()).count();
            auto& slot = lastMs[isLeft ? 0 : 1];
            const auto prev = slot.load(std::memory_order_relaxed);
            if (ms - prev > 250) {
                slot.store(ms, std::memory_order_relaxed);
                const char*         node = ThingBoneName(thing);
                const std::uint32_t fid  = tl_actor ? tl_actor->GetFormID() : 0u;
                const Wand          wand{ isLeft ? "LEFT" : "RIGHT", isLeft ? 2 : 1 };
                logger::info("[CBPC-TOUCH] wand={} node='{}' actorFID=0x{:08X} (HAND)",
                             wand.str, node, fid);
                FireTouchEvent(wand, /*isWeapon*/ false, std::string(node), fid);
            }
        }
        if (s_origHaptic) {
            s_origHaptic(isLeft);
        }
    }

    // Which player hand holds a drawn weapon = the weapon-touch wand. Read-only
    // singleton + equipped-slot reads, fully null-guarded for worker-thread use.
    // Dual-wield reports BOTH (ambiguous which weapon) — acceptable per spec.
    Wand PlayerWeaponWand() {
        auto* pc = RE::PlayerCharacter::GetSingleton();
        if (!pc) return { "UNKNOWN", 0 };
        auto* r = pc->GetEquippedObject(false);
        auto* l = pc->GetEquippedObject(true);
        const bool rw = r && r->IsWeapon();
        const bool lw = l && l->IsWeapon();
        if (rw && !lw) return { "RIGHT", 1 };
        if (lw && !rw) return { "LEFT",  2 };
        if (rw && lw)  return { "BOTH",  3 };
        return { "UNKNOWN", 0 };
    }

    // Weapon collision test (forward all 9 args verbatim, capture the bool).
    // This call site lives inside Thing::update, so tl_thing/tl_actor are the
    // node+actor being tested. Weapons fire no haptic, so this is the ONLY
    // weapon-touch signal. Throttled ~4/sec.
    bool HookedTriangleTest(void* thiz, void* p0, void* p1, void* p2, void* p3,
                            void* cfg, bool b5, bool b6, bool b7) {
        const bool hit = s_origTriangle
            ? s_origTriangle(thiz, p0, p1, p2, p3, cfg, b5, b6, b7)
            : false;
        // Scene shutdown: skip our event while paused. `hit` (cbp.dll's collision
        // result) was already computed above and is returned unchanged below, so
        // weapon collision/physics is unaffected — only our event is suppressed.
        if (hit && tl_inUpdate && tl_thing && !g_sceneSuppress.load(std::memory_order_relaxed)) {
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now().time_since_epoch()).count();
            const std::uint32_t fid = tl_actor ? tl_actor->GetFormID() : 0u;
            if (WeaponThrottlePasses(fid, ms, 250)) {
                const char* node = ThingBoneName(tl_thing);
                const Wand  wand = PlayerWeaponWand();
                logger::info("[CBPC-TOUCH] wand={} node='{}' actorFID=0x{:08X} (WEAPON)",
                             wand.str, node, fid);
                FireTouchEvent(wand, /*isWeapon*/ true, std::string(node), fid);
            }
        }
        return hit;
    }

    // Find a free, granularity-aligned region as CLOSE as possible to `target`
    // so a 5-byte rel32 call from cbp.dll can reach it. Scans outward both ways
    // and returns the nearest hit — unlike CommonLib's do_create, which returns
    // the LOWEST free region in a full ±2GB window (that handed back memory just
    // past int32 reach and crashed the first build).
    void* AllocNear(std::uintptr_t target, std::size_t size) {
        SYSTEM_INFO si{};
        GetSystemInfo(&si);
        const std::uintptr_t gran = si.dwAllocationGranularity;
        const std::uintptr_t aligned = target & ~(gran - 1);
        // Stay well under 2GiB so the eventual rel32 has margin to spare.
        const std::uintptr_t maxDelta = static_cast<std::uintptr_t>(1800) * 1024 * 1024;
        for (std::uintptr_t delta = gran; delta < maxDelta; delta += gran) {
            for (int dir = -1; dir <= 1; dir += 2) {
                const std::uintptr_t addr = (dir < 0) ? (aligned - delta) : (aligned + delta);
                if (addr < gran) continue;
                MEMORY_BASIC_INFORMATION mbi{};
                if (VirtualQuery(reinterpret_cast<void*>(addr), &mbi, sizeof(mbi)) &&
                    mbi.State == MEM_FREE) {
                    void* mem = VirtualAlloc(reinterpret_cast<void*>(addr), size,
                                             MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
                    if (mem) return mem;
                }
            }
        }
        return nullptr;
    }

    // True iff a rel32 branch from (srcEnd) to (dst) fits int32 with a 64KB
    // safety margin under the hard edge — so CommonLib's exact in_range() check
    // can never fail (and never report_and_fail, which would kill boot).
    bool Rel32Fits(std::uintptr_t srcEnd, std::uintptr_t dst) {
        const std::int64_t d = static_cast<std::int64_t>(dst) - static_cast<std::int64_t>(srcEnd);
        return d >= (static_cast<std::int64_t>(INT32_MIN) + 0x10000) &&
               d <= (static_cast<std::int64_t>(INT32_MAX) - 0x10000);
    }

    // Decode the rel32 of the E8 call at `site` to its absolute target address.
    std::uintptr_t CallTarget(std::uintptr_t site) {
        const std::int32_t rel = *reinterpret_cast<const std::int32_t*>(site + 1);
        return site + 5 + static_cast<std::uintptr_t>(static_cast<std::intptr_t>(rel));
    }

    // SizeOfImage of a loaded module (the mapped span from its base). The PE
    // headers are always in the first committed page, so reading them is safe;
    // we use this to bounds-check our call-site reads BEFORE dereferencing, so a
    // smaller/different cbp.dll build can't fault us into a boot CTD. 0 on failure.
    std::size_t ModuleImageSize(HMODULE mod) {
        if (!mod) return 0;
        const auto base = reinterpret_cast<const std::byte*>(mod);
        const auto dos  = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
        const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
        return nt->OptionalHeader.SizeOfImage;
    }

    // Compare n bytes at addr against an expected pattern (build-fingerprint check).
    bool BytesMatch(std::uintptr_t addr, const std::uint8_t* expected, std::size_t n) {
        const auto* p = reinterpret_cast<const std::uint8_t*>(addr);
        for (std::size_t i = 0; i < n; ++i) {
            if (p[i] != expected[i]) {
                return false;
            }
        }
        return true;
    }
}

namespace CBPCHook {

    void Install() {
        static std::atomic<bool> installed{ false };
        if (installed.exchange(true)) return;

        HMODULE cbp = GetModuleHandleA("cbp.dll");
        if (!cbp) {
            logger::info("[CBPC] cbp.dll not loaded — touch-wand hook skipped.");
            return;
        }
        const auto base = reinterpret_cast<std::uintptr_t>(cbp);

        // Bounds-check our highest base-relative read (the weapon call site + its
        // 5-byte E8) against cbp.dll's mapped image BEFORE any siteOk dereference,
        // so a smaller/unrecognized cbp.dll build aborts cleanly instead of faulting
        // on an out-of-bounds read at boot. (kRVA_Weapon_CallSite is the largest RVA
        // we read; the others are smaller, so this one check covers them all.)
        const std::size_t imgSize = ModuleImageSize(cbp);
        if (imgSize == 0 || (kRVA_Weapon_CallSite + 5) >= imgSize) {
            logger::error("[CBPC] cbp.dll image unrecognized/too small (size=0x{:X}) — touch-wand "
                          "hook ABORTED before any out-of-bounds read (game boots normally).", imgSize);
            return;
        }

        // --- Verify the build, independent of the call-site hook state ---
        // We confirm the cbp.dll build by matching the PROLOGUE bytes of the three
        // target functions. Function bodies are NOT touched by call-site hooks, so
        // this stays valid even if another plugin (e.g. AIHands) already hooked the
        // sites — which is what lets us CHAIN on top instead of aborting. If the
        // build differs (RVAs would be wrong) or a function was itself entry-hooked,
        // the bytes won't match and we abort cleanly (boot-safe, no detection).
        if (!BytesMatch(base + kRVA_ThingUpdate_Fn, kPrologue_ThingUpdate, sizeof(kPrologue_ThingUpdate)) ||
            !BytesMatch(base + kRVA_Haptic_Fn,      kPrologue_Haptic,      sizeof(kPrologue_Haptic))      ||
            !BytesMatch(base + kRVA_Weapon_Fn,      kPrologue_Triangle,    sizeof(kPrologue_Triangle))) {
            logger::error("[CBPC] cbp.dll function prologues don't match the reverse-engineered build "
                          "(different CBPC version, or a target function was entry-hooked) — touch-wand "
                          "hook ABORTED (game boots normally, just no touch-wand detection).");
            return;
        }

        // Each site must still be an E8 (call rel32). Its current target is EITHER
        // the original cbp.dll function (unhooked) OR another plugin's trampoline
        // (already hooked) — we accept BOTH. write_call<5> below captures whatever
        // is there as our 'original' and calls through to it, so we CHAIN on top of
        // any existing hook (every hook in the chain runs) rather than aborting.
        auto isCallSite = [&](std::uintptr_t rva) {
            return *reinterpret_cast<const std::uint8_t*>(base + rva) == 0xE8;
        };
        if (!isCallSite(kRVA_ThingUpdate_CallSite) || !isCallSite(kRVA_Haptic_CallSite1) ||
            !isCallSite(kRVA_Haptic_CallSite2)     || !isCallSite(kRVA_Weapon_CallSite)) {
            logger::error("[CBPC] a cbp.dll call site is not an E8 call (unexpected layout) — touch-wand "
                          "hook ABORTED (boot-safe).");
            return;
        }
        const bool alreadyHooked =
            CallTarget(base + kRVA_ThingUpdate_CallSite) != base + kRVA_ThingUpdate_Fn;
        if (alreadyHooked) {
            logger::info("[CBPC] sites already hooked by another plugin (e.g. AIHands) — CHAINING on "
                         "top (build verified via prologues; both hooks will run).");
        }

        // Allocate our own trampoline as close to cbp.dll as possible. NOT
        // CommonLib's create(size, module): its ±2GB window returned the lowest
        // free region (~2GB below cbp.dll's base), and with the call sites ABOVE
        // the base the displacement fell just past int32 -> boot crash.
        constexpr std::size_t kTrampSize = 256;
        void* mem = AllocNear(base, kTrampSize);
        if (!mem) {
            logger::error("[CBPC] no free memory within rel32 of cbp.dll — hook ABORTED "
                          "(game boots normally, just no touch-wand detection).");
            return;
        }
        const auto memAddr = reinterpret_cast<std::uintptr_t>(mem);

        // Pre-verify EVERY call site can rel32-reach the whole trampoline before
        // patching. If not, DON'T call write_call — its in_range() is a hard
        // report_and_fail that would kill boot. Bail cleanly instead.
        const std::uintptr_t sites[4] = {
            base + kRVA_ThingUpdate_CallSite,
            base + kRVA_Haptic_CallSite1,
            base + kRVA_Haptic_CallSite2,
            base + kRVA_Weapon_CallSite,
        };
        for (auto s : sites) {
            if (!Rel32Fits(s + 5, memAddr) || !Rel32Fits(s + 5, memAddr + kTrampSize)) {
                logger::error("[CBPC] trampoline 0x{:X} out of rel32 range of site 0x{:X} — "
                              "hook ABORTED (boot safe).", memAddr, s);
                VirtualFree(mem, 0, MEM_RELEASE);
                return;
            }
        }

        s_cbpTramp.set_trampoline(mem, kTrampSize, [](void* m, std::size_t) {
            VirtualFree(m, 0, MEM_RELEASE);
        });

        // Patch the haptic sites FIRST (s_origHaptic set) and the Thing::update
        // site LAST, so by the time HookedThingUpdate can run — and set tl_inUpdate,
        // the only state under which HookedHaptic does work — s_origHaptic is
        // already non-null. No null-original window on the meaningful path.
        const auto h1 = s_cbpTramp.write_call<5>(sites[1], reinterpret_cast<std::uintptr_t>(&HookedHaptic));
        s_cbpTramp.write_call<5>(sites[2], reinterpret_cast<std::uintptr_t>(&HookedHaptic));
        s_origHaptic = reinterpret_cast<HapticFn>(h1);
        s_origTriangle = reinterpret_cast<TriangleFn>(
            s_cbpTramp.write_call<5>(sites[3], reinterpret_cast<std::uintptr_t>(&HookedTriangleTest)));
        s_origThingUpdate = reinterpret_cast<ThingUpdateFn>(
            s_cbpTramp.write_call<5>(sites[0], reinterpret_cast<std::uintptr_t>(&HookedThingUpdate)));

        logger::info("[CBPC] touch-wand hook installed (hand+weapon). cbp.dll base=0x{:X} tramp=0x{:X} "
                     "ThingUpdate.orig=0x{:X} Haptic.orig=0x{:X} Weapon.orig=0x{:X}",
                     base, memAddr, reinterpret_cast<std::uintptr_t>(s_origThingUpdate), h1,
                     reinterpret_cast<std::uintptr_t>(s_origTriangle));
    }

    void SetScenePaused(bool paused) {
        g_sceneSuppress.store(paused, std::memory_order_relaxed);
        logger::info("[CBPC] scene shutdown {} (VRTouchEvents touch events {}; cbp.dll unaffected).",
                     paused ? "ENGAGED" : "lifted", paused ? "suppressed" : "resumed");
    }

    void InstallHitSink() {
        static std::atomic<bool> done{ false };
        if (done.exchange(true)) return;
        if (auto* holder = RE::ScriptEventSourceHolder::GetSingleton()) {
            holder->AddEventSink<RE::TESHitEvent>(PlayerHitSink::GetSingleton());
            logger::info("[CBPC] TESHitEvent sink installed (player-hit tracker for the weapon-touch gate).");
        } else {
            logger::error("[CBPC] ScriptEventSourceHolder unavailable — player-hit tracker NOT installed.");
        }
    }

    bool WasPlayerHitRecently(std::uint32_t formID, float withinSec) {
        const auto now      = NowMs();
        const auto windowMs = static_cast<std::int64_t>(withinSec * 1000.0f);
        for (int i = 0; i < kHitSlots; ++i) {
            if (g_playerHits[i].fid.load(std::memory_order_relaxed) == formID) {
                return (now - g_playerHits[i].ms.load(std::memory_order_relaxed)) <= windowMs;
            }
        }
        return false;
    }

}  // namespace CBPCHook
