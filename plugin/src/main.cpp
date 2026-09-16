#include "PCH.h"
#include "CBPCHook.h"
#include "PpbBridge.h"
#include "SkyrimNetReplies.h"
#include "PromptState.h"
#include "Speech.h"

namespace logger = SKSE::log;

SKSEPluginInfo(
    .Version              = { 1, 0, 0 },
    .Name                 = "VRTouchEvents",
    .Author               = "mad72",
    .StructCompatibility  = SKSE::StructCompatibility::Independent,
    .RuntimeCompatibility = SKSE::VersionIndependence::AddressLibrary
)

static void InitLogging()
{
    // SKSE::log::log_directory() -> <Documents>\My Games\Skyrim VR\SKSE\.
    // This is the SKSE log folder, NOT the Steam install — safe to write.
    auto path = SKSE::log::log_directory();
    if (!path) {
        return;
    }
    *path /= "VRTouchEvents.log";

    auto sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(path->string(), true);
    auto log  = std::make_shared<spdlog::logger>("VRTouchEvents", sink);
    log->set_level(spdlog::level::info);
    log->flush_on(spdlog::level::info);
    spdlog::set_default_logger(std::move(log));
    spdlog::set_pattern("[%H:%M:%S.%e] [%l] %v");
}

static void OnSKSEMessage(SKSE::MessagingInterface::Message* msg)
{
    switch (msg->type) {
    case SKSE::MessagingInterface::kDataLoaded:
        // ★ 2026-08-02 — CBPC IS NO LONGER HOOKED.
        //
        // CBPCHook::Install() used to trampoline three cbp.dll call sites to
        // recover which wand (L/R) and whether hand-or-weapon drove each CBPC
        // collision, then raise "VRTouchEvents_CBPCTouch" per touch. PPB now
        // reports all of that natively and in-band (wand, source class, weapon
        // name, the exact named capsule, penetration depth and duration), so
        // the hook is pure cost: three detours into another mod's binary for
        // information we already have from a supported API.
        //
        // NOT installing it also means cbp.dll stops evaluating VRTouchEvents'
        // collision spheres entirely — the four CBPCollisionConfig files are
        // removed from the mod as well. CBPC keeps doing its own job (jiggle
        // physics) untouched, and any other plugin chained onto the same call
        // sites (e.g. AIHands) is unaffected because we never insert ourselves.
        //
        // InstallHitSink() STAYS, and is now load-bearing: it backs
        // WasHitRecently, which V3Dispatch uses as the combat gate so a real
        // sword hit is never narrated as a gentle weapon touch. It is a plain
        // TESHitEvent sink and has nothing to do with cbp.dll.
        logger::info("DataLoaded — CBPC hook NOT installed (PPB is the sole sensor); "
                     "arming the hit sink + PPB bridge.");
        CBPCHook::InstallHitSink();
        PpbBridge::Install();
        // ★ 2026-09-12 (third design): the choke / recovery / wake prompt blocks are GATED by a
        // marker faction the prompts read with SkyrimNet's built-in get_faction_rank; this only
        // counts the NPC's spoken replies to end the recovery / wake blocks. SkyrimNetReplies.h
        // records why the two decorator designs before it failed.
        SNReplies::Install();
        // ★ 2026-09-12 (fourth design): the prompt blocks now read a live state FILE with SkyrimNet's
        // read_json, which re-reads on every modification - see PromptState.h for why nothing else worked.
        PromptState::Install();
        // ★ 2026-09-15: who is talking in SkyrimNet - an interrupt cuts only the NPC the line is about (Speech.h).
        Speech::Install();
        break;
    case SKSE::MessagingInterface::kPreLoadGame:
    case SKSE::MessagingInterface::kNewGame:
        // The ledger rule: touch sessions never survive a load boundary.
        PpbBridge::Reset();
        // ...and neither does a choke, so neither does its reply counting or its prompt state.
        SNReplies::Reset();
        PromptState::Reset();
        Speech::Reset();
        break;
    default:
        break;
    }
}

// Papyrus-callable native: VRTouchEvents_Native.SetScenePaused(bool).
// VRTouch_MainScript calls this on EnterSceneOff/ExitSceneOff so the C++ side
// goes fully dormant during a SexLab/OStim scene. Synchronous — flips an
// atomic, no event queue.
//
// ★ RE-POINTED 2026-08-02 (report 16 §9.2). This used to set the CBPC hook's
// g_sceneSuppress flag, which is read ONLY by the hand/weapon hooks — with
// those no longer installed it had become a silent no-op, so a scene would
// have left the coalescer sweeping at 4 Hz for nobody. It now pauses the PPB
// bridge, which is the thing that actually costs something.
//
// ★ 2026-09-15: VRTouchEvents_Native.IsTalking(Actor) - SkyrimNet's speaker right now (Speech.h). Logged on every call,
// with the rule that answered, so a VR run shows why a line was or was not cut.
static bool Papyrus_IsTalking(RE::StaticFunctionTag*, RE::Actor* a)
{
    if (!a) {
        return false;
    }
    const char* why = nullptr;
    const bool  yes = Speech::IsTalking(a->GetFormID(), &why);
    const char* nm  = a->GetName();
    logger::info("[SPEECH] IsTalking 0x{:08X} '{}' -> {} ({})", a->GetFormID(), nm ? nm : "", yes ? "yes" : "no",
                 why ? why : "");
    return yes;
}

// Free function (NOT a lambda): CommonLib's RegisterFunction needs a function
// pointer — RE::NativeFunction<lambda> is undefined.
static void Papyrus_SetScenePaused(RE::StaticFunctionTag*, bool paused)
{
    PpbBridge::SetPaused(paused);
}

// Was this NPC dealt damage by the PLAYER within the last `withinSec` seconds?
// The weapon-touch path calls this to skip a social reaction on a real combat hit
// (a gentle blade-rest deals no damage, so it returns false and still reacts).
static bool Papyrus_WasHitRecently(RE::StaticFunctionTag*, RE::Actor* a, float withinSec)
{
    return a ? CBPCHook::WasPlayerHitRecently(a->GetFormID(), withinSec) : false;
}

// ★ MALE UPDATE (2026-08-23): last erection level PPB reported for this actor,
// -1 = unknown. ★ CORRECTED 2026-09-02: PPB SHIPS THE BYTE and this returns real
// levels — the old text said "today: always [-1]" and was three PPB releases stale.
// (Kept for the genuine unknowns: female, no GEN rig, or an older PPB. The
// handoff request asks for — the narration omits the erection clause on -1).
static std::int32_t Papyrus_GetErectionLevel(RE::StaticFunctionTag*, RE::Actor* a)
{
    return a ? PpbBridge::GetErectionLevel(a->GetFormID()) : -1;
}

// ★ 2026-09-12: count this NPC's next 'replies' spoken lines through SkyrimNet's "dialogue"
// event, then send VRTE_RepliesDone (sender = the NPC). <= 0 stops counting.
static void Papyrus_CountReplies(RE::StaticFunctionTag*, RE::Actor* a, std::int32_t replies)
{
    if (a) {
        SNReplies::Count(a->GetFormID(), replies);
    }
}

// ★ 2026-09-12: a FormID as an UNSIGNED decimal string. Papyrus's GetFormID() is a signed Int,
// so any form from load slot 0x80 or higher (e.g. Sofia, 0xDC001827) comes out NEGATIVE - and a
// JSON context built from it would hand SkyrimNet's formid_to_uuid() a negative number. The
// arousal query's context uses this.
static RE::BSFixedString Papyrus_FormIDDec(RE::StaticFunctionTag*, RE::TESForm* f)
{
    return f ? RE::BSFixedString(std::to_string(f->GetFormID()).c_str()) : RE::BSFixedString("");
}

// ★ 2026-09-12 (fourth design): publish an NPC's prompt state (0 off · 1 choked · 2 moderate ·
// 3 severe · 4 just woke) to Data/SKSE/Plugins/VRTouchEvents/prompt_state.json, immediately.
// 0796 / 0797 / 0798 read it with read_json. Call BEFORE the narration that follows a change.
static void Papyrus_SetPromptState(RE::StaticFunctionTag*, RE::Actor* a, RE::BSFixedString displayName,
                                   std::int32_t state)
{
    if (a) {
        PromptState::Set(a->GetFormID(), displayName.c_str() ? displayName.c_str() : "", state);
    }
}

// ★ 2026-09-13: the contact that made a PPB push reaction (her head/belly/chest/back/thigh/pelvis for
// push/shove/dropped, her legs for sweeped), taken out of touch narration for 5 s so the push line carries it.
// "" = none found.
// ⚠ Registered WITHOUT the tasklet flag on purpose: the VM runs it on the main thread, like the bridge.
static RE::BSFixedString Papyrus_TakePushContact(RE::StaticFunctionTag*, RE::Actor* a, RE::BSFixedString kind,
                                                 RE::BSFixedString wand)
{
    if (!a) {
        return RE::BSFixedString("");
    }
    const std::string out = PpbBridge::TakePushContact(a->GetFormID(), kind.c_str() ? kind.c_str() : "",
                                                       wand.c_str() ? wand.c_str() : "");
    return RE::BSFixedString(out.c_str());
}

// ★ 2026-09-13: a two-hand undress is running on this NPC - both hand lanes stay out of touch narration for `secs`.
// ⚠ No tasklet flag, same as TakePushContact.
static void Papyrus_TakeGestureLanes(RE::StaticFunctionTag*, RE::Actor* a, float secs)
{
    if (a) {
        PpbBridge::TakeGestureLanes(a->GetFormID(), static_cast<double>(secs));
    }
}

static bool RegisterPapyrusFuncs(RE::BSScript::IVirtualMachine* vm)
{
    vm->RegisterFunction("TakePushContact", "VRTouchEvents_Native", Papyrus_TakePushContact);
    vm->RegisterFunction("TakeGestureLanes", "VRTouchEvents_Native", Papyrus_TakeGestureLanes);
    vm->RegisterFunction("SetPromptState", "VRTouchEvents_Native", Papyrus_SetPromptState);
    vm->RegisterFunction("SetScenePaused", "VRTouchEvents_Native", Papyrus_SetScenePaused);
    vm->RegisterFunction("WasHitRecently", "VRTouchEvents_Native", Papyrus_WasHitRecently);
    vm->RegisterFunction("GetErectionLevel", "VRTouchEvents_Native", Papyrus_GetErectionLevel);
    vm->RegisterFunction("CountReplies", "VRTouchEvents_Native", Papyrus_CountReplies);
    vm->RegisterFunction("FormIDDec", "VRTouchEvents_Native", Papyrus_FormIDDec);
    vm->RegisterFunction("IsTalking", "VRTouchEvents_Native", Papyrus_IsTalking);
    logger::info("Registered Papyrus natives VRTouchEvents_Native.TakePushContact / TakeGestureLanes / SetScenePaused / WasHitRecently"
                 " / GetErectionLevel / CountReplies / FormIDDec / SetPromptState.");
    return true;
}

SKSEPluginLoad(const SKSE::LoadInterface* skse)
{
    InitLogging();
    SKSE::Init(skse);

    logger::info("VRTouchEvents plugin v1.0.0 loaded");

    const auto msg = SKSE::GetMessagingInterface();
    if (msg) {
        msg->RegisterListener(OnSKSEMessage);
    }

    if (auto* papyrus = SKSE::GetPapyrusInterface()) {
        papyrus->Register(RegisterPapyrusFuncs);
    }

    return true;
}
