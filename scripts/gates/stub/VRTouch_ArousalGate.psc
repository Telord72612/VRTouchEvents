Scriptname VRTouch_ArousalGate Hidden
; ================================================================
; VRTouch_ArousalGate — STUB (arousal DISABLED, ships in Base).
; IsEnabled() returns False, so the arousal system is OFF by default
; (it costs LLM tokens per touch).  Install the FOMOD "Arousal" option
; to override this with the patch (IsEnabled() returns True).  Same
; stub-override pattern as the SexLab/OStim/GrabGate gates.
; ================================================================

Bool Function IsEnabled() Global
    return False
EndFunction
