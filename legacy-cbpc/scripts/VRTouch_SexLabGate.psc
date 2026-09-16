Scriptname VRTouch_SexLabGate Hidden
; ================================================================
; VRTouch_SexLabGate — stub version (ships with base VRTouchEvents)
;
; Returns False unconditionally.  If the user installs the
; "VRTouchEvents - SexLab patch" optional download, MO2 overrides
; this stub's .pex with a patched version that checks the SexLab
; animating faction.  No hard dependency on SexLab in the base mod.
;
; To call: VRTouch_SexLabGate.IsInScene(akActor)
; ================================================================

Bool Function IsInScene(Actor a) Global
    return False
EndFunction
