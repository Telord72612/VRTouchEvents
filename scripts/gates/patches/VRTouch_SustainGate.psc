Scriptname VRTouch_SustainGate Hidden
; ================================================================
; VRTouch_SustainGate - DISABLED override (FOMOD: "Subtle contact")
;
; Overrides the base stub, which returns True. MO2 loads this .pex
; over VRTouchEvents' own, so IsEnabled() answers False.
;
; The sustain upgrade never arms. A contact that goes out as a Thought or a
; Persistent event STAYS quiet no matter how long it is held - no held touch is
; ever upgraded to a spoken DirectNarration.
;
; Interrupt and Speak rows are untouched: those were always spoken and still are.
; This is the quieter, pre-V3.3 feel.
;
; Uninstalling this optional file restores the full feature - the base
; mod's own stub returns True again. Nothing else changes.
; ================================================================

Bool Function IsEnabled() Global
    return False
EndFunction
