Scriptname VRTouch_OStimGate Hidden
; ================================================================
; VRTouch_OStimGate — OStim patch version
;
; Overrides the stub that ships with VRTouchEvents.  When installed
; with MO2 below VRTouchEvents, this .pex replaces the stub and
; suppresses all VRTouch triggers while the actor is in an OStim
; scene.
;
; Calls OActor.IsInOStim(a), which is a Native Global provided by
; OStim Standalone (OActor.pex).  Gated by Game.GetModByName so the
; call only happens when OStim.esp is actually in the load order —
; meaning this patch is still safe to keep installed if OStim is
; temporarily removed.
; ================================================================

Bool Function IsInScene(Actor a) Global
    if a == None
        return False
    EndIf
    if Game.GetModByName("OStim.esp") == 255
        return False
    EndIf
    return OActor.IsInOStim(a)
EndFunction
