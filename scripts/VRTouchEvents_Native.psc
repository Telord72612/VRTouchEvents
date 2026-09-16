Scriptname VRTouchEvents_Native Hidden Native
; ================================================================
; Native bridge to VRTouchEvents.dll (registered in the plugin's main.cpp).
;
; ★ CORRECTED 2026-09-02: RE-POINTED 2026-08-02.  This no longer touches CBPC
; at all — the CBPC hook is NOT INSTALLED (PPB is the sole sensor), so the old
; wording described a silent no-op.  It now pauses the PPB BRIDGE, which is the
; thing that actually costs something during a scene.
; SetScenePaused(True)  -> the PPB bridge stops sweeping and stops emitting
;                          events (kills the residual per-touch task-post + event
;                          dispatch during a SexLab/OStim scene).
; SetScenePaused(False) -> resumes.
;
; This affects ONLY VRTouchEvents.  The hook still calls cbp.dll's originals, so
; CBPC collision, physics and the controller haptic are unchanged, and any other
; plugin chained onto the same cbp.dll call sites (e.g. AIHands) keeps running.
;
; Called from VRTouch_MainScript.EnterSceneOff / ExitSceneOff / Setup.  If the
; DLL is missing or pre-dates this native, the call just logs "function not
; found" and is a harmless no-op (the Papyrus-side scene shutdown still works;
; only the small C++-side residual remains).
; ================================================================

Function SetScenePaused(Bool paused) Global Native

; True if the PLAYER dealt damage to actor 'a' within the last 'withinSec' seconds.
; Used by the weapon-touch path to skip a social reaction on a REAL combat hit
; (a gentle blade-rest deals no damage -> returns False -> still reacts).
; Backed by the plugin's TESHitEvent sink.  False if the DLL lacks this native.
Bool Function WasHitRecently(Actor a, Float withinSec) Global Native

; ★ 2026-08-23: the last erection level (PPB GENBEND, 0..9) the bridge saw for
; this actor, or -1 when unknown.  ★ CORRECTED 2026-09-12: PPB SHIPS the
; reserved-tail byte (since PPB 2.0) and this returns real levels; -1 now means a
; genuine unknown - a female, no GEN rig, or an older PPB.  Callers must still
; treat -1 as "omit the erection clause", never as an error.
Int Function GetErectionLevel(Actor a) Global Native

; ★ 2026-09-12 (third design): the choke / recovery / wake prompt blocks are gated by the
; marker faction VRTE_ChokeStateFaction (VRTouchEvents.esp 0x804), which the prompts read
; with SkyrimNet's built-in get_faction_rank. Both decorator designs before it were measured
; failing in VR (Papyrus: a turn late; C++: SkyrimNet reuses the answer for ~30 s).
; A built-in cannot count, so the DLL counts the NPC's SPOKEN replies from SkyrimNet's
; "dialogue" event and sends the mod event VRTE_RepliesDone (sender = the NPC) when the owed
; number is reached. Harmless no-ops on a DLL that predates them.

; Count this NPC's next 'replies' spoken lines, then fire VRTE_RepliesDone. <= 0 stops counting.
Function CountReplies(Actor a, Int replies) Global Native

; ★ 2026-09-12 (fourth design): publish this NPC's prompt state to
; Data/SKSE/Plugins/VRTouchEvents/prompt_state.json - 0 off · 1 choked · 2 moderate · 3 severe · 4 just woke.
; 0796 / 0797 / 0798 read it with SkyrimNet's read_json, which re-reads the file on every change, so the
; block is current on the very next render (every NPC-data path SkyrimNet has lags 2-30 s). Call it
; BEFORE the narration that follows the change.
Function SetPromptState(Actor a, String displayName, Int aiState) Global Native   ; ("state" is a reserved word)

; A FormID as an UNSIGNED decimal string. GetFormID() is a signed Int, so a form from load slot
; 0x80+ comes out negative; JSON built from it would hand formid_to_uuid() a negative number.
String Function FormIDDec(Form f) Global Native

; ★ 2026-09-13: the player's contact that made a PPB push reaction - on her CORE (torso/pelvis) for "push" /
; "shove" / "dropped", on her LEGS for "sweeped". VRTouchEvents.dll marks that contact TAKEN, so no touch event
; names it while it lives (the push line carries it), and returns its 8 fields
; "W|SRC|NAME|PART|SUB|DEP|DIST|DUR", or "" when none was found. "" on a DLL that predates it.
; wand = the pusher PPB names in PushReaction (build 20105, "R" / "L"): that hand's contact wins when it qualifies.
String Function TakePushContact(Actor a, String kind, String wand = "") Global Native

; ★ 2026-09-13: a two-hand undress is running on this NPC - VRTouchEvents.dll leaves BOTH of the player's hand
; lanes on her out of every touch event for `secs` (0-30; the latest call wins). The head and genital lanes are
; untouched. On a DLL that predates it the call fails (an unbound-native line in the Papyrus log) and nothing is taken.
Function TakeGestureLanes(Actor a, Float secs) Global Native

; ★ 2026-09-15: True while this NPC is SkyrimNet's speaker - her voice is playing, she is between two lines of one reply,
; or her reply is still being written (DD SN Database 1.3.9's definition, copied into VRTouchEvents.dll). Every call is
; logged in VRTouchEvents.log as [SPEECH] IsTalking ... with the rule that answered. False on a DLL that predates it.
Bool Function IsTalking(Actor a) Global Native
