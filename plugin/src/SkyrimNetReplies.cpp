#include "PCH.h"
#include "SkyrimNetReplies.h"
#include "PromptState.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <unordered_map>

// Same include the SkyrimNet Captive Bridge uses for its PublicAPI binding (proven in VR
// with this CommonLibVR + VS2026 toolchain). Only this translation unit sees it.
#ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#    define NOMINMAX
#endif
#include <windows.h>

namespace logger = SKSE::log;

namespace
{
    // ── Lean binding to SkyrimNet.dll ────────────────────────────────────────
    // Only the exports this plugin needs, resolved at runtime like CppAPI/PublicAPI.h's
    // FindFunctions(). ABI: std::function crosses the DLL boundary -> dynamic CRT (/MD) on both
    // sides; this plugin builds x64-windows-static-md, same as the Captive Bridge.
    int           (*PublicGetVersion)()                                                     = nullptr;
    std::uint64_t (*PublicRegisterEventCallback)(const char*, std::function<void(const char*)>) = nullptr;

    std::mutex                                      g_mtx;
    std::unordered_map<std::uint32_t, std::int32_t> g_left;  // FormID -> replies still owed
    std::atomic<bool>                               g_loggedPayload{ false };

    // Reads an unsigned integer field out of the event JSON without a JSON library:
    // `"key": 123` or `"key":"123"`. Returns 0 when absent or out of range.
    std::uint32_t ReadUIntField(const char* json, const char* quotedKey)
    {
        const char* p = std::strstr(json, quotedKey);
        if (!p) {
            return 0;
        }
        p += std::strlen(quotedKey);
        while (*p == ' ' || *p == '\t' || *p == ':' || *p == '"') {
            ++p;
        }
        if (*p < '0' || *p > '9') {
            return 0;
        }
        char*                  end = nullptr;
        const unsigned long long v = std::strtoull(p, &end, 10);
        return (v > 0xFFFFFFFFull) ? 0 : static_cast<std::uint32_t>(v);
    }

    void SendRepliesDone(std::uint32_t fid)
    {
        auto* task = SKSE::GetTaskInterface();
        if (!task) {
            return;
        }
        task->AddTask([fid]() {
            auto* src = SKSE::GetModCallbackEventSource();
            auto* form = RE::TESForm::LookupByID(fid);
            if (!src || !form) {
                return;
            }
            SKSE::ModCallbackEvent ev{};
            ev.eventName = "VRTE_RepliesDone";
            ev.strArg    = "";
            ev.numArg    = 0.0f;
            ev.sender    = form;
            src->SendEvent(&ev);
        });
    }

    // SkyrimNet's "dialogue" event: fires whenever an NPC speaks through SkyrimNet.
    void OnDialogue(const char* json)
    {
        if (!json) {
            return;
        }
        // One payload per session goes to the log, so the field names are on record.
        if (!g_loggedPayload.exchange(true)) {
            std::string head(json);
            if (head.size() > 300) {
                head.resize(300);
            }
            logger::info("[SN-REPLIES] first dialogue payload (truncated): {}", head);
        }
        // Someone spoke: SkyrimNet may have just created an entity whose UUID the prompt-state file lacked.
        PromptState::RefreshUnresolved();
        const std::uint32_t fid = ReadUIntField(json, "\"originatingActorFormId\"");
        if (fid == 0) {
            return;
        }
        std::int32_t left = 0;
        bool         done = false;
        {
            std::lock_guard lk(g_mtx);
            const auto it = g_left.find(fid);
            if (it == g_left.end()) {
                return;
            }
            left = --it->second;
            if (left <= 0) {
                g_left.erase(it);
                done = true;
            }
        }
        logger::info("[SN-REPLIES] 0x{:08X} spoke - {} repl{} still owed{}", fid, left > 0 ? left : 0,
                     left == 1 ? "y" : "ies", done ? " -> VRTE_RepliesDone" : "");
        if (done) {
            SendRepliesDone(fid);
        }
    }
}

namespace SNReplies
{
    void Install()
    {
        HMODULE h = ::LoadLibraryA("SkyrimNet");
        if (!h) {
            logger::warn("[SN-REPLIES] SkyrimNet.dll not loaded - recovery / wake blocks will clear on their "
                         "time limits only.");
            return;
        }
        PublicGetVersion = reinterpret_cast<int (*)()>(::GetProcAddress(h, "PublicGetVersion"));
        if (!PublicGetVersion) {
            logger::warn("[SN-REPLIES] SkyrimNet.dll has no PublicGetVersion export - not subscribed.");
            return;
        }
        const int version = PublicGetVersion();
        if (version < 5) {
            logger::warn("[SN-REPLIES] SkyrimNet API v{} < 5 (no event callbacks) - not subscribed.", version);
            return;
        }
        PublicRegisterEventCallback =
            reinterpret_cast<std::uint64_t (*)(const char*, std::function<void(const char*)>)>(
                ::GetProcAddress(h, "PublicRegisterEventCallback"));
        if (!PublicRegisterEventCallback) {
            logger::warn("[SN-REPLIES] SkyrimNet API v{} but PublicRegisterEventCallback missing - not subscribed.",
                         version);
            return;
        }
        const std::uint64_t id = PublicRegisterEventCallback("dialogue", OnDialogue);
        logger::info("[SN-REPLIES] SkyrimNet API v{} - listening to 'dialogue' (cbId={}) to count owed replies",
                     version, id);
    }

    void Reset()
    {
        std::lock_guard lk(g_mtx);
        if (!g_left.empty()) {
            logger::info("[SN-REPLIES] load boundary - dropped {} reply counter(s)", g_left.size());
        }
        g_left.clear();
    }

    void Count(std::uint32_t formID, std::int32_t replies)
    {
        std::lock_guard lk(g_mtx);
        if (replies <= 0) {
            if (g_left.erase(formID) > 0) {
                logger::info("[SN-REPLIES] stopped counting 0x{:08X}", formID);
            }
            return;
        }
        g_left[formID] = replies;
        logger::info("[SN-REPLIES] counting 0x{:08X}: {} repl{} owed", formID, replies, replies == 1 ? "y" : "ies");
    }
}
