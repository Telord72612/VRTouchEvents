Scriptname VRTouch_GearGate Hidden
; ================================================================
; VRTouch_GearGate - DISABLED override (FOMOD: "Equip/unequip awareness off")
;
; Overrides the base stub, which returns True. MO2 loads this .pex
; over VRTouchEvents' own, so IsEnabled() answers False.
;
; VRTouchEvents narrates no hand equip, no removal and no refused equip/pull.
;
; Deliberately still running: the two-hand undress hand-mute and the held-armour
; suppression, so gripping a garment to pull it off still never produces a
; phantom grope line.
;
; Pick this if you run Gift by Hand VR and find held gear being absorbed as a
; gift instead of equipped.
;
; Uninstalling this optional file restores the full feature - the base
; mod's own stub returns True again. Nothing else changes.
; ================================================================

Bool Function IsEnabled() Global
    return False
EndFunction
