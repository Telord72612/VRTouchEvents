Scriptname VRTouch_SustainGate Hidden
; ================================================================
; VRTouch_SustainGate — "every touch gets spoken", ENABLED (base stub)
;
; Returns True unconditionally -> the SUSTAIN UPGRADE runs: a contact
; that first went out quietly (a Thought or a Persistent event) and is
; then STILL being held when it reaches its sustain point is upgraded
; to a spoken DirectNarration, so the NPC answers out loud.
;
; This is the "all direct narration" feature: before it, a large part
; of the contact matrix only ever produced a silent thought or a
; context event, and a held touch never earned a spoken reaction.
;
; If the player picks "Subtle contact" in the FOMOD, MO2 overrides this
; stub's .pex with one returning False -> V3SusArm never arms, no hold
; is ever upgraded, and every contact keeps the tier the matrix gives
; it (Thought stays a thought, Persistent stays context).  Interrupt
; and Speak rows are NOT affected either way: they were always spoken.
;
; Opt-OUT by design (base = ON): a manual install with no FOMOD keeps
; the feature, which is the shipped V3.3 behaviour.
;
; Called from VRTouch_MainScript.V3SusArm:
;   if !VRTouch_SustainGate.IsEnabled()   ; False = never upgrade
; ================================================================

Bool Function IsEnabled() Global
    return True
EndFunction
