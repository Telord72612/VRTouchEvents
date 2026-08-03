Scriptname VRTouch_GrabGate Hidden
; ================================================================
; VRTouch_GrabGate — "VRTouchEvents - No Follower Grab" patch
; ================================================================
; Overrides the VRTouchEvents base stub (which returns False).  Returns
; True for ACTIVE followers, so VRTouchEvents skips its grab path for them:
; no grab trigger, no choke-by-grab, and the event never reaches SkyrimNet
; — the follower stays silent while you reposition them with HIGGS.
;
; UNAFFECTED: touch reactions on followers (petting still works), HIGGS's
; own physical grab (you can still pick up / move them), and every
; non-follower NPC.  Dismissed followers (teammate flag cleared) react to
; grabs normally again.
;
; Detection is framework-agnostic: IsPlayerTeammate() covers vanilla and
; every follower framework that flags active companions as teammates
; (NFF, AFT, Lazy Follower, etc.); vanilla CurrentFollowerFaction
; (0005C84E) is a null-guarded backstop.  GetFormFromFile per call is
; fine here — grabs are infrequent, player-initiated events.
; ================================================================

Bool Function ShouldSuppressGrab(Actor akActor) Global
    if akActor == None
        return False
    EndIf
    if akActor.IsPlayerTeammate()
        return True
    EndIf
    Faction fac = Game.GetFormFromFile(0x0005C84E, "Skyrim.esm") as Faction  ; CurrentFollowerFaction
    if fac != None && akActor.IsInFaction(fac)
        return True
    EndIf
    return False
EndFunction
