Scriptname VRTouch_SexLabGate Hidden
; ================================================================
; VRTouch_SexLabGate — SexLab patch version
;
; Overrides the stub that ships with VRTouchEvents.  When installed
; with MO2 below VRTouchEvents, this .pex replaces the stub and
; suppresses all VRTouch triggers while the actor is in a SexLab
; animation.
;
; Uses lazy Game.GetFormFromFile lookup of SexLab's animating faction
; (FormID 0x0000E50F in SexLab.esm).  The lookup returns None if
; SexLab.esm is not loaded, and the function returns False in that
; case — so this patch is also safe if someone installs it without
; actually having SexLab.
; ================================================================

Bool Function IsInScene(Actor a) Global
    if a == None
        return False
    EndIf
    Faction anim = Game.GetFormFromFile(0x0000E50F, "SexLab.esm") as Faction
    if anim == None
        return False
    EndIf
    return a.IsInFaction(anim)
EndFunction
