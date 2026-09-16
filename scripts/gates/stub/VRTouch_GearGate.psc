Scriptname VRTouch_GearGate Hidden
; ================================================================
; VRTouch_GearGate — equip / unequip awareness, ENABLED (base stub)
;
; Returns True unconditionally -> VRTouchEvents narrates hand-driven
; gear changes detected by PPB's gesture layer:
;   equip    - "Telord gently put Hide Boots on the feet of Carmella."
;   removal  - "Telord pulled Hide Boots off Carmella."
;              (a slot-32 body piece interrupts and can end "...leaving
;               Carmella naked.")
;   refused  - a piece that would not go on, or a locked piece that
;              would not come off, reaches her as a short-lived event.
;
; Covers EVERY piece — plain armour, clothes, ZaZ, Diary of Mine and
; Devious Devices alike.  The DD SN AddOn, when installed, adds the
; device-specific detail (mechanism, lock, onlookers) as awareness on
; top; that is the AddOn's lane and is NOT governed by this gate.
;
; If the player turns gear awareness OFF in the FOMOD, MO2 overrides
; this stub's .pex with one returning False -> the three narration
; senders (GearOnSend, GearOffQueue, GearRefusedTell) return at once.
; Everything else is deliberately left running: the undress hand-mute
; and the held-armour suppression still work, so gripping a garment to
; pull it off still does not produce a phantom grope line.
;
; ⚠ COMPATIBILITY — Gift by Hand VR / GiftByHandSN.  Equipping by hand
; means holding a piece of gear up to an NPC, and Gift by Hand treats an
; item held out to an NPC as a GIFT and can absorb it into her inventory
; before the equip gesture completes.  If you run Gift by Hand and find
; gear vanishing instead of being worn, turn this option OFF (or unbind
; Gift by Hand's give gesture).  Touch, grab, kiss, push and choke are
; unaffected either way.
;
; Opt-OUT by design (base = ON): a manual install with no FOMOD keeps
; the feature.
;
; Called from VRTouch_MainScript.GearOnSend / GearOffQueue / GearRefusedTell:
;   if !VRTouch_GearGate.IsEnabled()   ; False = narrate no gear changes
; ================================================================

Bool Function IsEnabled() Global
    return True
EndFunction
