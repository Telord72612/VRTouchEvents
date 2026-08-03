Scriptname VRTouch_ArousalGate Hidden
; ================================================================
; VRTouch_ArousalGate — Arousal module, ENABLED (patch version)
;
; Overrides the Base STUB (which returns False).  When this .pex is
; installed below VRTouchEvents in MO2 — i.e. the FOMOD "Arousal"
; option was selected — IsEnabled() returns True, so VRTouchEvents'
; arousal system runs.  The main script still ANDs this with an
; arousal-backend check (OSL Aroused Reborn OR SexLab Aroused), so
; nothing fires unless a backend is also present.
;
; Why this is opt-in: arousal sends ONE LLM prompt to SkyrimNet per
; qualifying touch/grab (to compute a personality- and relationship-
; adjusted arousal delta + facial reaction), so it consumes tokens.
; Same stub-override pattern as the SexLab/OStim/GrabGate gates.
; ================================================================

Bool Function IsEnabled() Global
    return True
EndFunction
