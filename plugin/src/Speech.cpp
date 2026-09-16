#include "PCH.h"
#include "Speech.h"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

namespace logger = SKSE::log;

// SkyrimNet sends these as SKSE mod events, sender = the speaker (measured by the SkyrimNet Mouth Bridge's payload
// receipts, VR 2026-09-15 17:36; the same receipts DD SN 1.3.9 built from):
//   SkyrimNet_SpeechStarted  / SkyrimNet_SpeechComplete  - her reply is being WRITTEN (several Started per reply)
//   SkyrimNet_AudioStarted   / SkyrimNet_AudioEnded      - one pair per SPOKEN line
// strArg JSON: "speakerFormId" in DECIMAL (318889551 = 0x1301DE4F, the sender), "isNarration", and on AudioEnded
// "remainingQueueSize" (her next line). Measured gap between two lines of one reply: 0.30 s (AudioEnded 17:36:18.192 ->
// AudioStarted 18.496).
// "Talking" = from the moment her reply starts being written until her last queued line has played. The windows in
// IsTalking only bridge the gaps BETWEEN those signals (text done -> voice ~1.5 s, line -> next line ~0.3 s). They are
// detection tolerances copied from DD SN 1.3.9, not limits on anything she or the player does.
// ⚠ The sink only records. It runs inside SkyrimNet's SendModEvent, so it never queues a task or calls into the VM.
namespace
{
    struct TalkState
    {
        double preparingAt = -1.0;  // last SpeechStarted
        double completeAt  = -1.0;  // SpeechComplete after it
        bool   playing     = false; // AudioStarted without its AudioEnded yet
        double endedAt     = -1.0;  // last AudioEnded
        int    remaining   = 0;     // remainingQueueSize at that AudioEnded
    };

    std::mutex                                   g_mtx; // held only to touch the map, never while calling out
    std::unordered_map<std::uint32_t, TalkState> g_talk;

    double NowSeconds()
    {
        using namespace std::chrono;
        return duration<double>(steady_clock::now().time_since_epoch()).count();
    }

    long long JsonIntField(const char* json, const char* key)
    {
        if (!json || !key) {
            return -1;
        }
        const std::string needle = std::string("\"") + key + "\":";
        const char*       p      = std::strstr(json, needle.c_str());
        if (!p) {
            return -1;
        }
        return std::strtoll(p + needle.size(), nullptr, 10);
    }

    class SpeechSink : public RE::BSTEventSink<SKSE::ModCallbackEvent>
    {
    public:
        RE::BSEventNotifyControl ProcessEvent(const SKSE::ModCallbackEvent* ev,
                                              RE::BSTEventSource<SKSE::ModCallbackEvent>*) override
        {
            if (!ev || !ev->eventName.c_str()) {
                return RE::BSEventNotifyControl::kContinue;
            }
            const char* name = ev->eventName.c_str();
            if (_strnicmp(name, "SkyrimNet_", 10) != 0) {
                return RE::BSEventNotifyControl::kContinue;
            }
            const bool sStart = _stricmp(name, "SkyrimNet_SpeechStarted") == 0;
            const bool sDone  = _stricmp(name, "SkyrimNet_SpeechComplete") == 0;
            const bool aStart = _stricmp(name, "SkyrimNet_AudioStarted") == 0;
            const bool aEnd   = _stricmp(name, "SkyrimNet_AudioEnded") == 0;
            if (!sStart && !sDone && !aStart && !aEnd) {
                return RE::BSEventNotifyControl::kContinue;
            }
            const char* json = ev->strArg.c_str();
            if (json && std::strstr(json, "\"isNarration\":true")) {
                return RE::BSEventNotifyControl::kContinue; // the narrator is nobody's line
            }
            std::uint32_t fid = 0;
            if (ev->sender && ev->sender->GetFormType() == RE::FormType::ActorCharacter) {
                fid = ev->sender->GetFormID();
            } else if (const long long id = JsonIntField(json, "speakerFormId"); id > 0) {
                fid = static_cast<std::uint32_t>(id);
            }
            if (!fid || fid == 0x14) {
                return RE::BSEventNotifyControl::kContinue; // no actor / the player
            }
            const double     now = NowSeconds();
            std::scoped_lock lk(g_mtx);
            auto&            t = g_talk[fid];
            if (sStart) {
                t.preparingAt = now;
                t.completeAt  = -1.0;
            } else if (sDone) {
                t.completeAt = now;
            } else if (aStart) {
                t.playing     = true;
                t.preparingAt = -1.0;
                t.completeAt  = -1.0;
            } else {
                t.playing         = false;
                t.endedAt         = now;
                const long long r = JsonIntField(json, "remainingQueueSize");
                t.remaining       = r < 0 ? 0 : static_cast<int>(r);
            }
            return RE::BSEventNotifyControl::kContinue;
        }
    };

    SpeechSink g_sink;
}

namespace Speech
{
    void Install()
    {
        if (auto* src = SKSE::GetModCallbackEventSource()) {
            src->AddEventSink(&g_sink);
            logger::info("[SPEECH] listening for SkyrimNet's speech and audio signals - an interrupt cuts only the NPC "
                         "who is talking");
        } else {
            logger::error("[SPEECH] no SKSE mod-event source - IsTalking will always answer no (nothing is cut)");
        }
    }

    void Reset()
    {
        std::scoped_lock lk(g_mtx);
        g_talk.clear();
    }

    bool IsTalking(std::uint32_t fid, const char** why)
    {
        const char* dummy = nullptr;
        const char*& w    = why ? *why : dummy;
        w                 = "no SkyrimNet speech seen from this NPC";
        if (!fid) {
            return false;
        }
        const double     now = NowSeconds();
        std::scoped_lock lk(g_mtx);
        const auto       it = g_talk.find(fid);
        if (it == g_talk.end()) {
            return false;
        }
        const TalkState& t = it->second;
        if (t.playing) {
            w = "her voice is playing";
            return true;
        }
        if (t.remaining > 0 && t.endedAt >= 0.0 && now - t.endedAt < 2.0) {
            w = "between two lines of her reply";
            return true;
        }
        if (t.preparingAt >= 0.0) {
            if (t.completeAt < 0.0) {
                if (now - t.preparingAt < 20.0) {
                    w = "her reply is being written";
                    return true;
                }
            } else if (now - t.completeAt < 15.0) {
                // 2026-09-15: widened 5.0 -> 15.0 to match DD SN Database 1.3.10.
                // They measured 94 replies over five SkyrimNet logs, pairing each
                // SpeechComplete with the next AudioStarted from the same sender:
                // median 2.0 s, p90 5.5 s, max 12.7 s -- 12 of 94 (13 %) exceeded 5 s.
                // At 5.0 roughly one reply in eight answered "not talking" while its
                // voice was still on the way, so the cut never landed and her line
                // then played over the reaction. A new SpeechStarted or AudioStarted
                // still ends this window early, so a normal reply is unaffected.
                // This definition is DD SN's, copied verbatim on purpose: both mods
                // must answer the same about the same NPC at the same moment.
                w = "her reply is written, its voice is on the way";
                return true;
            }
        }
        w = "not talking";
        return false;
    }
}
