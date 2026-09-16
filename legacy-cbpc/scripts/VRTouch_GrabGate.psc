Scriptname VRTouch_GrabGate Hidden
; ================================================================
; VRTouch_GrabGate — stub version (ships with base VRTouchEvents)
;
; Grab-suppression gate.  Returns False unconditionally → the base mod
; suppresses NOTHING: every actor (including followers) is grabbed and
; reacts normally, exactly as before this hook existed.
;
; If the user installs the "VRTouchEvents - No Follower Grab" optional
; download, MO2 overrides this stub's .pex with a version that returns
; True for active followers — so VRTouchEvents skips the grab trigger
; AND choke-by-grab for them, letting the player reposition followers
; via HIGGS with no SkyrimNet reaction.  No hard dependency on anything.
;
; Called from VRTouch_MainScript.OnObjectGrabbed:
;   if VRTouch_GrabGate.ShouldSuppressGrab(akActor)  ; True = suppress
; True suppresses ONLY the VRTouchEvents grab path (grab triggers + choke
; initiation) for akActor.  Touch reactions and HIGGS's own physical grab
; are unaffected.
; ================================================================

Bool Function ShouldSuppressGrab(Actor akActor) Global
    return False
EndFunction
