#pragma once

// ★★ 2026-09-15 WHO IS TALKING - the user's interrupt rule:
//   "Every single interrupt event we push to SkyrimNet will be interrupt ONLY if the NPC that the interrupt is going to
//    is currently talking. If not, don't do an interrupt. So that if someone else is talking, they are not the one getting
//    interrupted."
// SkyrimNet's cut (PurgeDialogue / TriggerInterruptDialogue) is GLOBAL - it stops whoever is speaking. So VRTouch_MainScript
// asks IsTalking(her) first and cuts only when the answer is yes.
//
// The definition is DD SN Database 1.3.9's (WornDevices.cpp "WHO IS TALKING"), copied so both mods agree on the same NPC at
// the same moment and VRTouchEvents does not depend on the Database being installed.
namespace Speech
{
    // Registers the SkyrimNet speech/audio mod-event sink. Call once at kDataLoaded.
    void Install();
    // Forget every speaker (load boundary).
    void Reset();
    // True while this actor is SkyrimNet's speaker: her voice is playing, she is between two lines of one reply, or her
    // reply is still being written. `why` receives the rule that answered (for the log), may be null.
    bool IsTalking(std::uint32_t formId, const char** why = nullptr);
}
