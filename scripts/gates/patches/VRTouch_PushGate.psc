Scriptname VRTouch_PushGate Hidden
; ================================================================
; VRTouch_PushGate - DISABLED override (FOMOD: "Push reactions off")
;
; Overrides the base stub, which returns True. MO2 loads this .pex
; over VRTouchEvents' own, so IsEnabled() answers False.
;
; VRTouchEvents narrates no push, shove, stumble or leg sweep.
;
; PPB still DETECTS the push and still physically moves the NPC - that is PPB's
; mechanic and this option cannot switch it off. Only the narration stops, and
; the pushing hand's contact is no longer consumed, so it narrates as a normal
; touch instead.
;
; Uninstalling this optional file restores the full feature - the base
; mod's own stub returns True again. Nothing else changes.
; ================================================================

Bool Function IsEnabled() Global
    return False
EndFunction
