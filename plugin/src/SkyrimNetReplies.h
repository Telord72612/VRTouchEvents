#pragma once
//
// ★ VRTouchEvents x SkyrimNet — counting an NPC's SPOKEN REPLIES (2026-09-12, third design).
//
// THE HISTORY, so nobody re-tries a dead road:
//  v1  Papyrus decorators (VRTouch_Decorators.psc). SkyrimNet refreshes those in an async pass
//      2-3 s AFTER the render that needs them -> the choke block ran a turn late.
//  v2  Native C++ decorators (PublicRegisterDecorator). Called live - but SkyrimNet REUSES a
//      decorator's answer per NPC for ~30 s, undocumented. VR test 2: the choke block never
//      reached the LLM, and the wake block rendered 2 m 45 s late, twice, from one call.
//  v3  (this) The ON/OFF STATE is a marker faction in VRTouchEvents.esp
//      (VRTE_ChokeStateFaction, rank 1 choked / 2 moderate / 3 severe recovery / 4 just woke),
//      read by SkyrimNet's BUILT-IN get_faction_rank, which reads the actor at render time -
//      the reason DD SN Database's gag block (worn_has_keyword) has always been on time.
//      What a built-in cannot do is COUNT, so this file counts: it listens to SkyrimNet's
//      "dialogue" event (fires when an NPC speaks) and, when a tracked NPC has spoken the
//      owed number of replies, sends the mod event VRTE_RepliesDone (sender = that actor).
//      VRTouch_MainScript clears the faction rank in answer.
//
// Threading: SkyrimNet calls the event callback on its own thread. Only the counter map is
// touched there; the mod event is sent through SKSE's task queue on the main thread - the
// exact pattern the SkyrimNet Captive Bridge's "dialogue" callback runs in VR.
// (The AddTask deadlock rule is about another mod's FRAME-HOOK callback, not this thread.)
//
#include <cstdint>

namespace SNReplies
{
    // kDataLoaded: resolve SkyrimNet.dll at runtime (soft dependency) and subscribe to "dialogue".
    void Install();

    // kPreLoadGame / kNewGame: nothing is counted across a load (the ledger rule).
    void Reset();

    // Count this NPC's next 'replies' spoken lines, then fire VRTE_RepliesDone. <= 0 stops counting.
    void Count(std::uint32_t formID, std::int32_t replies);
}
