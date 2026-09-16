#include "PCH.h"
#include "PromptState.h"

#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>

// Same include the SkyrimNet Captive Bridge uses for its PublicAPI binding (proven in VR with this
// CommonLibVR + VS2026 toolchain). Only this translation unit and SkyrimNetReplies.cpp see it.
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
    // SkyrimNet API v3+: FormID -> the entity UUID a template sees as npc.UUID. 0 = not known yet.
    std::uint64_t (*PublicFormIDToUUID)(std::uint32_t) = nullptr;

    struct Entry
    {
        std::string   name;
        std::int32_t  state = 0;
        std::uint64_t uuid  = 0;
    };

    std::mutex                        g_mtx;
    std::map<std::uint32_t, Entry>    g_npcs;  // FormID -> entry (ordered: stable file output)

    // Relative to the game's working directory, so MO2's virtual filesystem resolves it exactly like
    // SkyrimNet's read_json does ("Data\SKSE\Plugins\<mod>\<file>.json").
    const std::filesystem::path kDir  = std::filesystem::path("Data") / "SKSE" / "Plugins" / "VRTouchEvents";
    const std::filesystem::path kFile = kDir / "prompt_state.json";
    const std::filesystem::path kTmp  = kDir / "prompt_state.json.tmp";

    std::string JsonEscape(const std::string& s)
    {
        std::string out;
        out.reserve(s.size() + 2);
        for (const unsigned char c : s) {
            switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
            }
        }
        return out;
    }

    std::uint64_t ResolveUUID(std::uint32_t fid)
    {
        return PublicFormIDToUUID ? PublicFormIDToUUID(fid) : 0;
    }

    // Call with g_mtx held. Builds the whole file, writes it to a temp file and swaps it in, so
    // SkyrimNet's read_json can never parse a half-written file.
    void WriteLocked(const char* why)
    {
        std::ostringstream js;
        js << "{\"version\":1,\"npcs\":[";
        bool first = true;
        for (const auto& [fid, e] : g_npcs) {
            if (!first) {
                js << ",";
            }
            first = false;
            js << "{\"uuid\":" << e.uuid << ",\"formId\":" << fid << ",\"name\":\"" << JsonEscape(e.name)
               << "\",\"state\":" << e.state << "}";
        }
        js << "]}";
        const std::string text = js.str();

        std::error_code ec;
        std::filesystem::create_directories(kDir, ec);
        {
            std::ofstream f(kTmp, std::ios::binary | std::ios::trunc);
            if (!f) {
                logger::warn("[PROMPT-STATE] cannot open {} for writing ({}) - state NOT published", kTmp.string(), why);
                return;
            }
            f.write(text.data(), static_cast<std::streamsize>(text.size()));
        }
        if (!::MoveFileExW(kTmp.wstring().c_str(), kFile.wstring().c_str(),
                           MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            // Fall back to a direct write (a tiny window where a reader could see a partial file).
            const auto err = ::GetLastError();
            std::ofstream f(kFile, std::ios::binary | std::ios::trunc);
            if (!f) {
                logger::warn("[PROMPT-STATE] swap failed (err {}) and direct write failed ({})", err, why);
                return;
            }
            f.write(text.data(), static_cast<std::streamsize>(text.size()));
            logger::warn("[PROMPT-STATE] swap failed (err {}) - wrote directly instead ({})", err, why);
        }
        logger::info("[PROMPT-STATE] {} -> {}", why, text);
    }
}

namespace PromptState
{
    void Install()
    {
        HMODULE h = ::LoadLibraryA("SkyrimNet");
        if (h) {
            auto* getVersion = reinterpret_cast<int (*)()>(::GetProcAddress(h, "PublicGetVersion"));
            const int version = getVersion ? getVersion() : 0;
            if (version >= 3) {
                PublicFormIDToUUID = reinterpret_cast<std::uint64_t (*)(std::uint32_t)>(
                    ::GetProcAddress(h, "PublicFormIDToUUID"));
            }
            logger::info("[PROMPT-STATE] SkyrimNet API v{} - FormIDToUUID {}", version,
                         PublicFormIDToUUID ? "resolved" : "MISSING (entries will carry uuid 0 and never match)");
        } else {
            logger::warn("[PROMPT-STATE] SkyrimNet.dll not loaded - prompt state is written but nothing reads it");
        }
        std::lock_guard lk(g_mtx);
        g_npcs.clear();
        WriteLocked("data loaded - empty");
    }

    void Reset()
    {
        std::lock_guard lk(g_mtx);
        g_npcs.clear();
        WriteLocked("load boundary - empty");
    }

    void Set(std::uint32_t formID, const std::string& name, std::int32_t state)
    {
        std::lock_guard lk(g_mtx);
        if (state <= 0) {
            if (g_npcs.erase(formID) == 0) {
                return;  // was not listed - nothing to publish
            }
            WriteLocked("removed");
            return;
        }
        auto& e  = g_npcs[formID];
        e.name   = name;
        e.state  = state;
        e.uuid   = ResolveUUID(formID);
        if (e.uuid == 0) {
            logger::warn("[PROMPT-STATE] 0x{:08X} '{}' has no SkyrimNet UUID yet - re-resolved on the next "
                         "SkyrimNet dialogue event", formID, name);
        }
        WriteLocked("set");
    }

    // Called from SNReplies' dialogue callback (any NPC spoke): SkyrimNet may have created the entity since.
    void RefreshUnresolved()
    {
        std::lock_guard lk(g_mtx);
        bool changed = false;
        for (auto& [fid, e] : g_npcs) {
            if (e.uuid == 0) {
                e.uuid = ResolveUUID(fid);
                changed = changed || e.uuid != 0;
            }
        }
        if (changed) {
            WriteLocked("late UUID resolved");
        }
    }
}
