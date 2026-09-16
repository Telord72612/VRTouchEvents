Scriptname VRTouch_PushGate Hidden
; ================================================================
; VRTouch_PushGate — push / shove / stumble / leg-sweep, ENABLED (base stub)
;
; Returns True unconditionally -> VRTouchEvents listens to PPB's
; PPB_PushReaction and narrates the four push outcomes:
;   push    - a steady shove that makes her walk back  (persistent + thought)
;   shove   - a harder shove                            (persistent + thought)
;   dropped - the shove stumbles her to the ground      (interrupt + spoken)
;   sweeped - a leg sweep takes her down                (interrupt + spoken)
;
; The HOW ("with his right palm") comes from the hand contact that
; caused it; that contact's own touch line is suppressed so one push
; is one line, never a touch line plus a push line.
;
; If the player turns pushes OFF in the FOMOD, MO2 overrides this
; stub's .pex with one returning False -> OnPPBPushReaction returns
; immediately.  PPB still detects and still physically pushes the NPC
; (that is PPB's mechanic, not ours); only VRTouchEvents' narration of
; it stops, and the hand contact then narrates normally as a touch.
;
; Opt-OUT by design (base = ON): a manual install with no FOMOD keeps
; the feature.
;
; Called from VRTouch_MainScript.OnPPBPushReaction:
;   if !VRTouch_PushGate.IsEnabled()   ; False = narrate no pushes
; ================================================================

Bool Function IsEnabled() Global
    return True
EndFunction
