#pragma once
//
// ★★ VRTouchEvents' LIVE PROMPT STATE FILE (2026-09-12, fourth design — the user's placeholder idea).
//
// WHY A FILE. Every way SkyrimNet gives a template NPC data is a COPY it refreshes on its own
// schedule, because prompts are built on a background thread that cannot touch a live actor:
//   v1 Papyrus decorator  -> refreshed 2-3 s after the render that needed it
//   v2 C++ decorator      -> the answer reused per NPC for ~30 s
//   v3 faction rank       -> SkyrimNet's per-NPC game data reused ~20 s after its last read
//                            (VR test 4: Yamarz, last rendered 21.5 s before, saw it;
//                             Carmella, rendered 3-20 s before, did not)
// SkyrimNet's read_json decorator is different: it compares the file's modified time on EVERY
// call and re-reads on a change ("read_json: File modified since cached, reloading" - IntelEngine's
// political_state.json proves it live on this load order). So VRTE writes the state here the
// instant it changes, and 0796 / 0797 / 0798 read it with read_json("VRTouchEvents/prompt_state").
//
// File:  Data/SKSE/Plugins/VRTouchEvents/prompt_state.json
//        {"version":1,"npcs":[{"uuid":<SkyrimNet entity UUID, decimal>,"formId":<u32>,"name":"…","state":N}]}
// state: 1 being choked · 2 recovery moderate · 3 recovery severe · 4 just woke. Absent = no block.
// uuid is exactly what a template sees as npc.UUID (PublicFormIDToUUID; verified: Carmella
// 0x1DC40559654A101F = 2144845204044779551, the value the render preview printed).
//
#include <cstdint>
#include <string>

namespace PromptState
{
    // kDataLoaded: resolve SkyrimNet's PublicFormIDToUUID (API v3+) and write an empty state file.
    void Install();

    // kPreLoadGame / kNewGame: nothing survives a load - the file goes back to empty.
    void Reset();

    // state <= 0 removes the NPC. Writes the whole file atomically, immediately.
    void Set(std::uint32_t formID, const std::string& name, std::int32_t state);

    // An entry whose NPC had no SkyrimNet UUID yet is re-resolved here (called on every SkyrimNet
    // "dialogue" event, from SkyrimNetReplies) and the file rewritten if one resolved.
    void RefreshUnresolved();
}
