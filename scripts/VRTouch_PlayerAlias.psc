Scriptname VRTouch_PlayerAlias extends ReferenceAlias
; ================================================================
; VRTouch_PlayerAlias
; Attached to the single player alias on VRTouchEvents_MainQuest
; (000800), filled with PlayerRef via Forced Reference.
;
; The whole reason this script exists: HIGGS grab/drop subscriptions
; are SKSE *session*-scoped — wiped on every game launch — and were
; only ever (re)registered inside VRTouch_MainScript.Setup().  Setup()
; ran from OnInit (install only) and from a bare-Quest OnPlayerLoadGame
; that THE ENGINE NEVER DISPATCHES (OnPlayerLoadGame only fires on
; Actor / ReferenceAlias scripts, never on a script that extends Quest).
; So after the install session HIGGS went dead every reload.
;
; OnPlayerLoadGame DOES fire on a ReferenceAlias filled with the player
; (the proven Gift by Hand VR / SkyUI / SkyrimNet pattern).  We forward
; it into the quest's per-load re-arm so HIGGS re-registers on every load
; of a NEW game / fresh install.
;
; NOTE on EXISTING saves: a save that was already running this quest
; before the alias was added will NOT auto-fill the alias (the engine
; fills aliases only at quest start), so this event won't fire there
; until the quest is restarted.  That's a one-time migration: the user
; runs `stopquest VRTouchEvents_MainQuest` then `startquest
; VRTouchEvents_MainQuest` once (or starts a new game) — which re-fires
; OnInit -> Setup (re-registering HIGGS immediately) and fills this alias
; for all future loads.  Documented in the mod's update notes.
; ================================================================

Event OnPlayerLoadGame()
    VRTouch_MainScript q = GetOwningQuest() as VRTouch_MainScript
    if q
        q.OnGameReload()
    endif
EndEvent
