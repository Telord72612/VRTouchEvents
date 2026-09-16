Scriptname VRTouchEvents_Native Hidden Native
; ================================================================
; Native bridge to VRTouchEvents.dll (registered in the plugin's main.cpp).
;
; SetScenePaused(True)  -> the C++ CBPC hook stops firing VRTouchEvents_CBPCTouch
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
