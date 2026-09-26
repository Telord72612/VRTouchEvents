#include "PCH.h"
#include "PromptState.h"

#include <atomic>
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

    // ⛔ THE RULE (2026-09-25, ported from the DDAB Base's fix - DDAB_to_VRTE_Notice_2026-09-24_JsonEscape_UTF8.md):
    //   every byte this writer emits is valid UTF-8, whatever name the game hands over.
    //   - a sequence that is ALREADY valid UTF-8 passes untouched (translations, future literals);
    //   - a run of bytes that is not is the game's own 8-bit text: converted through the Windows ANSI
    //     codepage (1252 on a Western install turns F6 into U+00F6; 1251 keeps a Cyrillic name right);
    //   - whatever still cannot convert becomes U+FFFD, so the file ALWAYS parses.
    // WHY: the old escaper copied every byte >= 0x80 straight through. A lone cp1252 byte (a mod-added
    // "Bjorn" with an o-umlaut, a translation, a rename) is illegal UTF-8, and SkyrimNet's parser
    // (nlohmann::json) then rejects the WHOLE prompt_state.json - every choke/recovery/wake block went
    // dark while that NPC was tracked, with nothing but error spam in SkyrimNet.log.
    // Per SEQUENCE, never per string: a name can be half UTF-8 and half cp1252, and converting the whole
    // string would garble the half that was already right.
    // ⚠ Converted ONLY here, at the door out. Inside the plugin a name stays the game's own bytes.

    // Length of the valid UTF-8 sequence at p (RFC 3629: no overlongs, no surrogates, nothing above
    // U+10FFFF - exactly what nlohmann::json, SkyrimNet's parser, enforces). 0 = not a valid sequence.
    std::size_t Utf8SeqLen(const unsigned char* p, std::size_t n)
    {
        const unsigned char c    = p[0];
        const auto          cont = [&](std::size_t i, unsigned char lo = 0x80, unsigned char hi = 0xBF) {
            return i < n && p[i] >= lo && p[i] <= hi;
        };
        if (c < 0x80) return 1;
        if (c >= 0xC2 && c <= 0xDF) return cont(1) ? 2 : 0;
        if (c == 0xE0) return cont(1, 0xA0) && cont(2) ? 3 : 0;
        if ((c >= 0xE1 && c <= 0xEC) || c == 0xEE || c == 0xEF) return cont(1) && cont(2) ? 3 : 0;
        if (c == 0xED) return cont(1, 0x80, 0x9F) && cont(2) ? 3 : 0;
        if (c == 0xF0) return cont(1, 0x90) && cont(2) && cont(3) ? 4 : 0;
        if (c >= 0xF1 && c <= 0xF3) return cont(1) && cont(2) && cont(3) ? 4 : 0;
        if (c == 0xF4) return cont(1, 0x80, 0x8F) && cont(2) && cont(3) ? 4 : 0;
        return 0;   // 80-C1 (a stray continuation / overlong lead) and F5-FF are never legal
    }

    // The game's 8-bit text -> UTF-8 through the ANSI codepage. Never fails: if Windows cannot convert
    // the run, each byte becomes U+FFFD. The run holds only bytes >= 0x80, so the result can never carry
    // a quote, a backslash or a control character that would still need escaping.
    std::string AnsiToUtf8(const char* s, std::size_t n)
    {
        const int len = static_cast<int>(n);
        const int wn  = ::MultiByteToWideChar(CP_ACP, 0, s, len, nullptr, 0);
        if (wn > 0) {
            std::wstring w(static_cast<std::size_t>(wn), L'\0');
            ::MultiByteToWideChar(CP_ACP, 0, s, len, w.data(), wn);
            const int un = ::WideCharToMultiByte(CP_UTF8, 0, w.data(), wn, nullptr, 0, nullptr, nullptr);
            if (un > 0) {
                std::string u(static_cast<std::size_t>(un), '\0');
                ::WideCharToMultiByte(CP_UTF8, 0, w.data(), wn, u.data(), un, nullptr, nullptr);
                return u;
            }
        }
        std::string out;
        for (std::size_t i = 0; i < n; ++i) out += "\xEF\xBF\xBD";
        return out;
    }

    std::atomic<bool> g_convertLogged{ false };   // said once per session: the VR test greps for it

    std::string JsonEscape(const std::string& s)
    {
        std::string out;
        out.reserve(s.size() + 8);
        const auto*       p         = reinterpret_cast<const unsigned char*>(s.data());
        const std::size_t n         = s.size();
        bool              converted = false;
        for (std::size_t i = 0; i < n;) {
            const unsigned char c = p[i];
            if (c < 0x80) {
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
                ++i;
                continue;
            }
            if (const std::size_t len = Utf8SeqLen(p + i, n - i)) {   // already UTF-8: keep it as is
                out.append(s, i, len);
                i += len;
                continue;
            }
            std::size_t j = i;                                        // the game's own 8-bit text
            while (j < n && p[j] >= 0x80 && !Utf8SeqLen(p + j, n - j)) ++j;
            out += AnsiToUtf8(s.data() + i, j - i);
            converted = true;
            i         = j;
        }
        if (converted && !g_convertLogged.exchange(true, std::memory_order_relaxed)) {
            logger::info("[PROMPT-STATE] an NPC name was not UTF-8 (the game's 8-bit text) - converted for "
                         "SkyrimNet: '{}'. Before VRTE 3.4 this made SkyrimNet reject the whole file.", out);
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
