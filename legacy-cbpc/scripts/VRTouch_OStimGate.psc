Scriptname VRTouch_OStimGate Hidden
; ================================================================
; VRTouch_OStimGate — stub version (ships with base VRTouchEvents)
;
; Returns False unconditionally.  If the user installs the
; "VRTouchEvents - OStim patch" optional download, MO2 overrides
; this stub's .pex with a patched version that calls
; OActor.IsInOStim(a).  No hard dependency on OStim in the base mod.
;
; To call: VRTouch_OStimGate.IsInScene(akActor)
; ================================================================

Bool Function IsInScene(Actor a) Global
    return False
EndFunction
