#include "PCH.h"
#include "CBPCHook.h"
#include "PpbBridge.h"

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
        break;
    case SKSE::MessagingInterface::kPreLoadGame:
    case SKSE::MessagingInterface::kNewGame:
        // The ledger rule: touch sessions never survive a load boundary.
        PpbBridge::Reset();
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

static bool RegisterPapyrusFuncs(RE::BSScript::IVirtualMachine* vm)
{
    vm->RegisterFunction("SetScenePaused", "VRTouchEvents_Native", Papyrus_SetScenePaused);
    vm->RegisterFunction("WasHitRecently", "VRTouchEvents_Native", Papyrus_WasHitRecently);
    logger::info("Registered Papyrus natives VRTouchEvents_Native.SetScenePaused / WasHitRecently.");
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
