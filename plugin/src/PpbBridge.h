#pragma once

// =============================================================================
// PpbBridge — the V3 touch COALESCER: senses touches through PPB's raw contact
// API (PpbTouchAPI.h), aggregates them into per-NPC touch sessions, applies the
// sub-region priority table + the ~1 s coalescer window + escalation, merges
// both hands into ONE interaction, and emits a compact mod-event stream the
// V3 Papyrus dispatcher (VRTouch_MainScript) subscribes to:
//
//   "VRTE_Contact"        first emit for a session, or an escalation re-emit
//   "VRTE_ContactUpdate"  once per ~1 s while the session lives (after first emit)
//   "VRTE_ContactEnd"     session over
//
//   sender = the touched NPC (Form); numArg = primary contact duration in
//   seconds (on End: the session's total live duration); strArg = exactly 16
//   pipe-separated fields — see the contract block in PpbBridge.cpp.
//
// WHY RAW, NOT DIGEST: the digest reports one contact per (actor, wand, REGION)
// keyed to the LONGEST-dwelt capsule — after 2 s on the chest ring and 0.25 s
// on the breast it still says "chest ring". The user's rule is the opposite:
// the more specific part wins the moment it is touched. Only GetRawContacts
// carries the CURRENT capsule, so the bridge polls the raw snapshot and owns
// its own aggregation (priority-over-duration, window, escalation).
//
// Driver: PPB's AddTouchCallback fires on the MAIN thread at apiHz (~4/s)
// while any contact lives; the callback is used purely as a tick signal (a
// >= 0.2 s guard, then one sweep of GetRawContacts). A short SKSE-task pump
// keeps ticking after the last PPB callback so lingering sessions still get
// their VRTE_ContactEnd. Everything (sweep, emits, reset) runs on the main
// thread — no locks, no task handoff for the events themselves.
//
// BOOT-SAFE: PPB absent / too old / callback table full => one log line and
// the bridge stays inert.
//
// ★ 2026-08-02: this is now the mod's ONLY touch sensor. The CBPC hook is no
// longer installed and the four CBPC collision configs are gone, so there is
// no second path and no fallback: if PPB is absent, VRTouchEvents does
// nothing. That is the deliberate trade — PPB covers females of mapped races
// only, and males/children/creatures come back as PPB's coverage grows.
// =============================================================================

namespace PpbBridge {
    // Acquire PPB's IPpbTouchInterface1 (PpbMessage dispatch to "PPB") and
    // register the touch callback that drives the coalescer. Call once at
    // kDataLoaded (any time at/after kPostLoad is legal per the PPB header).
    // Null/missing PPB is logged once and leaves the bridge inert.
    void Install();

    // Drop every live touch session (no events fired — the ledger rule: touch
    // sessions never survive a load boundary). Call on kPreLoadGame and
    // kNewGame. Safe to call before Install or when the bridge is inert.
    void Reset();

    // Scene suppression. While paused the sweep returns immediately, so a
    // SexLab/OStim scene costs zero coalescer work — previously this flag
    // gated the (now uninstalled) CBPC hook, which made it a no-op.
    // Pausing also drops live sessions silently, exactly like a cell change:
    // an End for an interaction that stopped because a scene started carries
    // no information, and Papyrus has unregistered its sinks anyway.
    void SetPaused(bool paused);
}
