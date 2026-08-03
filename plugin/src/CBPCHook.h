#pragma once

// =============================================================================
// CBPCHook — surface WHICH player wand (left/right) and whether a HAND or a
// WEAPON drove each CBPC player-collision touch, then raise a Papyrus mod event
// ("VRTouchEvents_CBPCTouch") the VRTouchEvents scripts subscribe to.
//
// CBPC's stock Papyrus event (CBPCPlayerCollisionWith{Female,Male}Event) carries
// only (npcNode, actor, duration) — the wand is computed during collision
// detection and discarded before the event is raised (the PlayerCollisionEvent
// struct is just {bool collisionInThisCycle; float durationFilled; float total}).
//
// We recover the wand by call-site-hooking cbp.dll functions (RVAs from cbp.pdb
// via tools/diadump). Ported verbatim from the AIHands proof-of-concept hook,
// with one change: instead of only logging, each detected touch is dispatched to
// the MAIN thread (SKSE task interface) where it fires the mod event. The hooks
// themselves run on CBPC worker threads, so all game-facing work is deferred.
//
//   * Thing::update(Actor*, mutex&, mutex&)        -> touched NPC node + actor
//   * HandHapticFeedbackEffect(bool isLeft)        -> HAND wand (true=LEFT)
//   * IsItCollidingTriangleToAffectedNodes(...)    -> WEAPON test (separate path)
//
// The install verifies the cbp.dll build by matching the target functions'
// prologue bytes (NOT the call-site targets). If the build differs, it no-ops
// cleanly (game boots normally, just no detection) and never corrupts cbp.dll.
//
// CHAIN-TOLERANT: because the build is verified via function bodies (which
// call-site hooks don't touch), the install accepts a site that another plugin
// has ALREADY hooked and CHAINS on top of it (write_call<5> captures the existing
// target and calls through, so every hook in the chain runs). So if AIHands (or
// any future mod) also hooks these sites, VRTouchEvents still works — it no longer
// has to be the sole owner. (AIHands' own POC CBPCHook can be disabled regardless,
// since it's redundant now, but it's no longer REQUIRED to be.)
// =============================================================================

namespace CBPCHook {
    // Install the call-site hooks. Safe to call once cbp.dll is loaded
    // (kDataLoaded). No-op (logged) if cbp.dll is absent or its call-site
    // signatures don't match the build we reverse-engineered.
    void Install();

    // Scene shutdown: when paused, the hooks STILL call cbp.dll's originals
    // (collision, physics and controller haptic all run normally) but skip
    // firing VRTouchEvents' own "VRTouchEvents_CBPCTouch" mod event — so during
    // a SexLab/OStim scene the C++ side does zero VRTouchEvents work (no task
    // post, no event dispatch). Affects ONLY VRTouchEvents; cbp.dll and any
    // chained hook (e.g. AIHands) are untouched. Set from Papyrus via the
    // VRTouchEvents_Native.SetScenePaused() registered in main.cpp.
    void SetScenePaused(bool paused);

    // --- Player-hit tracker (weapon-touch combat-hit gate) ---------------------
    // InstallHitSink registers a TESHitEvent sink that records when the PLAYER
    // deals damage to an NPC (with a timestamp). WasPlayerHitRecently(formID,
    // withinSec) reports whether that NPC took player damage inside the window —
    // letting the weapon-touch path tell a real combat HIT (damage) from a
    // deliberate gentle blade-rest (no damage) and suppress only the former.
    // Sink writes on the main thread; the query is read lock-free from Papyrus.
    void InstallHitSink();
    bool WasPlayerHitRecently(std::uint32_t formID, float withinSec);
}
