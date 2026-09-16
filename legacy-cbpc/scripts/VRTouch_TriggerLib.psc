; VRTouch_TriggerLib.psc
; Pure data functions for VRTouch trigger resolution.
; All functions are Global — no properties, no state, no ESP attachment needed.
;
; Body parts: head, face, face_hold, hands, arms, feet, legs,
;             left_breast, right_breast, chest, upper_back,
;             belly, lower_back, genitals, butt,
;             tail_base, tail_tip
;
; Armor states: 0=bare, 1=clothes, 2=light armor, 3=heavy armor
;
Scriptname VRTouch_TriggerLib

; ================================================================
; Trigger Name
; Returns "" if no trigger exists for the combination.
; ================================================================
String Function GetTriggerName(String bp, Bool isGrab, Int arm) Global
    ; --- Head ---
    if bp == "head"
        String hSuffix = ArmorSuffix3(arm)
        if isGrab
            return "VRTouch_Head_Grab_" + hSuffix
        EndIf
        return "VRTouch_Head_Touch_" + hSuffix
    EndIf

    ; --- Face Hold (head grab + face marker) ---
    if bp == "face_hold"
        if !isGrab
            return ""
        EndIf
        if arm == 0
            return "VRTouch_FaceHold_Grab_Bare"
        EndIf
        return "VRTouch_FaceHold_Grab_Mask"
    EndIf

    ; --- Face ---
    if bp == "face"
        if isGrab
            return ""
        EndIf
        if arm == 0
            return "VRTouch_Face_Touch_Bare"
        EndIf
        return "VRTouch_Face_Touch_Mask"
    EndIf

    ; --- Hands (grab only, all state) ---
    if bp == "hands"
        if isGrab
            return "VRTouch_Hand_Grab_AllState"
        EndIf
        return ""
    EndIf

    ; --- Arms (all state) ---
    if bp == "arms"
        if isGrab
            return "VRTouch_Arm_Grab_AllState"
        EndIf
        return "VRTouch_Arm_Touch_AllState"
    EndIf

    ; --- Feet ---
    if bp == "feet"
        if isGrab
            if arm == 0
                return "VRTouch_Foot_Grab_Bare"
            EndIf
            return "VRTouch_Foot_Grab_AllState"
        EndIf
        if arm == 0
            return "VRTouch_Foot_Touch_Bare"
        EndIf
        return "VRTouch_Foot_Touch_AllState"
    EndIf

    ; --- Legs ---
    if bp == "legs"
        String lSuffix = ArmorSuffix3(arm)
        if isGrab
            return "VRTouch_Leg_Grab_" + lSuffix
        EndIf
        return "VRTouch_Leg_Touch_" + lSuffix
    EndIf

    ; --- Breasts (sided: bare/clothes; generic: armor) ---
    if bp == "left_breast" || bp == "right_breast"
        String side = "LeftBreast"
        if bp == "right_breast"
            side = "RightBreast"
        EndIf
        if arm == 0
            if isGrab
                return "VRTouch_" + side + "_Grab_Bare"
            EndIf
            return "VRTouch_" + side + "_Touch_Bare"
        ElseIf arm == 1
            if isGrab
                return "VRTouch_" + side + "_Grab_Clothes"
            EndIf
            return "VRTouch_" + side + "_Touch_Clothes"
        ElseIf arm == 2
            if isGrab
                return "VRTouch_Breast_Grab_LArmor"
            EndIf
            return "VRTouch_Breast_Touch_LArmor"
        Else
            if isGrab
                return "VRTouch_Breast_Grab_HArmor"
            EndIf
            return "VRTouch_Breast_Touch_HArmor"
        EndIf
    EndIf

    ; --- Chest (touch only) ---
    if bp == "chest"
        if isGrab
            return ""
        EndIf
        return "VRTouch_Chest_Touch_" + ArmorSuffix3(arm)
    EndIf

    ; --- Upper Back ---
    if bp == "upper_back"
        String ubSuffix = "Bare"
        if arm == 1
            ubSuffix = "Clothes"
        ElseIf arm == 2
            ubSuffix = "LArmor"
        ElseIf arm == 3
            ubSuffix = "HArmor"
        EndIf
        if isGrab
            return "VRTouch_UpperBack_Grab_" + ubSuffix
        EndIf
        return "VRTouch_UpperBack_Touch_" + ubSuffix
    EndIf

    ; --- Belly ---
    if bp == "belly"
        String bSuffix = ArmorSuffix4(arm)
        if isGrab
            return "VRTouch_Belly_Grab_" + bSuffix
        EndIf
        return "VRTouch_Belly_Touch_" + bSuffix
    EndIf

    ; --- Lower Back ---
    if bp == "lower_back"
        if isGrab
            ; Grab: bare, clothes, armor (L+H combined)
            if arm == 0
                return "VRTouch_LowerBack_Grab_Bare"
            ElseIf arm == 1
                return "VRTouch_LowerBack_Grab_Clothes"
            EndIf
            return "VRTouch_LowerBack_Grab_Armor"
        EndIf
        ; Touch: bare, clothes, larmor, harmor
        if arm == 0
            return "VRTouch_LowerBack_Touch_Bare"
        ElseIf arm == 1
            return "VRTouch_LowerBack_Touch_Clothes"
        ElseIf arm == 2
            return "VRTouch_LowerBack_Touch_LArmor"
        EndIf
        return "VRTouch_LowerBack_Touch_HArmor"
    EndIf

    ; --- Genitals ---
    if bp == "genitals"
        String gSuffix = ArmorSuffix3(arm)
        if isGrab
            return "VRTouch_Genitals_Grab_" + gSuffix
        EndIf
        return "VRTouch_Genitals_Touch_" + gSuffix
    EndIf

    ; --- Butt ---
    if bp == "butt"
        if isGrab
            if arm == 0
                return "VRTouch_Butt_Grab_Bare"
            ElseIf arm == 1
                return "VRTouch_Butt_Grab_Clothes"
            EndIf
            return "VRTouch_Butt_Grab_Armor"
        EndIf
        return "VRTouch_Butt_Touch_" + ArmorSuffix4(arm)
    EndIf

    ; --- Tail (touch only, no armor) ---
    if bp == "tail_base"
        if isGrab
            return ""
        EndIf
        return "VRTouch_TailBase_Touch"
    EndIf
    if bp == "tail_tip"
        if isGrab
            return ""
        EndIf
        return "VRTouch_TailTip_Touch"
    EndIf

    return ""
EndFunction

; Helper: Bare / Clothes / Armor  (3 states — L and H combined)
String Function ArmorSuffix3(Int arm) Global
    if arm == 0
        return "Bare"
    ElseIf arm == 1
        return "Clothes"
    EndIf
    return "Armor"
EndFunction

; Helper: Bare / Clothes / LArmor / HArmor  (4 states)
String Function ArmorSuffix4(Int arm) Global
    if arm == 0
        return "Bare"
    ElseIf arm == 1
        return "Clothes"
    ElseIf arm == 2
        return "LArmor"
    EndIf
    return "HArmor"
EndFunction

; ================================================================
; Delay (seconds) — base values from trigger schema
; ================================================================
Float Function GetDelay(String bp, Bool isGrab, Int arm) Global
    ; --- Head ---
    if bp == "head"
        if !isGrab
            if arm == 0
                return 1.0
            ElseIf arm == 1
                return 2.0
            EndIf
            return 3.0
        EndIf
        if arm <= 1
            return 1.0
        EndIf
        return 2.0
    EndIf

    ; --- Face Hold ---
    if bp == "face_hold"
        if arm == 0
            return 1.0
        EndIf
        return 2.0
    EndIf

    ; --- Face ---
    if bp == "face"
        if arm == 0
            return 1.0
        EndIf
        return 2.0
    EndIf

    ; --- Hands ---
    if bp == "hands"
        return 3.0
    EndIf

    ; --- Arms ---
    if bp == "arms"
        return 4.0
    EndIf

    ; --- Feet ---
    if bp == "feet"
        if isGrab
            return 3.0
        EndIf
        return 4.0
    EndIf

    ; --- Legs ---
    if bp == "legs"
        if arm == 0
            return 2.0
        ElseIf arm == 1
            return 3.0
        EndIf
        return 4.0
    EndIf

    ; --- Breasts (sided bare/clothes) ---
    if bp == "left_breast" || bp == "right_breast"
        if arm <= 1
            return 0.0
        ElseIf arm == 2
            return 2.0
        EndIf
        return 3.0
    EndIf

    ; --- Chest ---
    if bp == "chest"
        if arm == 0
            return 1.0
        ElseIf arm == 1
            return 2.0
        EndIf
        return 4.0
    EndIf

    ; --- Upper Back ---
    if bp == "upper_back"
        if arm == 0
            return 1.0
        ElseIf arm == 1
            return 2.0
        EndIf
        return 4.0
    EndIf

    ; --- Belly ---
    if bp == "belly"
        if arm == 0
            return 1.0
        ElseIf arm == 1
            return 2.0
        ElseIf arm == 2
            return 3.0
        EndIf
        return 4.0
    EndIf

    ; --- Lower Back ---
    if bp == "lower_back"
        if isGrab && arm >= 2
            return 4.0
        EndIf
        if arm == 0
            return 1.0
        ElseIf arm == 1
            return 2.0
        EndIf
        return 3.0
    EndIf

    ; --- Genitals ---
    if bp == "genitals"
        if arm == 0
            return 0.0
        ElseIf arm == 1
            return 1.0
        EndIf
        return 2.0
    EndIf

    ; --- Butt ---
    if bp == "butt"
        if isGrab
            if arm == 0
                return 0.0
            ElseIf arm == 1
                return 1.0
            EndIf
            return 2.0
        EndIf
        if arm == 0
            return 0.0
        ElseIf arm == 1
            return 1.0
        ElseIf arm == 2
            return 2.0
        EndIf
        return 3.0
    EndIf

    ; --- Tail ---
    ; Shorter dwells than body parts: tails are thin, move with physics,
    ; and hard to stay in contact with for long.
    if bp == "tail_base"
        return 1.0
    EndIf
    if bp == "tail_tip"
        return 1.5
    EndIf

    return 0.0
EndFunction

; ================================================================
; IsInterrupting — bypasses the per-NPC cooldown.
;
; Intimate contact is always significant enough to fire regardless
; of whether other events have fired on this NPC recently:
;   - Genitals: touch or grab, any armor state.
;   - Breast (L/R) and butt: touch or grab, bare or clothes only.
;     Over light/heavy armor the contact is too muted to count as
;     an intimate moment (padding/plate mutes the feel), so those
;     fall back to normal cooldown rules.
;
; isGrab is retained in the signature (callers still pass it) but
; is no longer read — both touch and grab interrupt.
; ================================================================
Bool Function IsInterrupting(String bp, Bool isGrab, Int arm) Global
    if bp == "genitals"
        return True
    EndIf
    if arm > 1
        return False
    EndIf
    if bp == "left_breast" || bp == "right_breast" || bp == "butt"
        return True
    EndIf
    return False
EndFunction

; ================================================================
; Slot Mask for armor detection
; ================================================================
Int Function GetSlotMask(String bp) Global
    if bp == "head"
        return 1            ; slot 30
    EndIf
    if bp == "face" || bp == "face_hold"
        return 16384        ; slot 44
    EndIf
    if bp == "hands"
        return 8            ; slot 33
    EndIf
    if bp == "arms"
        return 16           ; slot 34
    EndIf
    if bp == "feet"
        return 128          ; slot 37
    EndIf
    ; Tail: no armor slot
    if bp == "tail_base" || bp == "tail_tip"
        return 0
    EndIf
    ; Everything else: body slot 32
    return 4
EndFunction

; ================================================================
; Region (for grab-supersede-touch matching)
; ================================================================
String Function GetRegion(String bp) Global
    if bp == "head" || bp == "face" || bp == "face_hold"
        return "head"
    EndIf
    if bp == "left_breast" || bp == "right_breast" || bp == "chest" || bp == "upper_back"
        return "chest"
    EndIf
    if bp == "belly" || bp == "lower_back"
        return "belly"
    EndIf
    if bp == "genitals" || bp == "butt"
        return "pelvis"
    EndIf
    if bp == "tail_base" || bp == "tail_tip"
        return "tail"
    EndIf
    return bp
EndFunction

; ================================================================
; Baseline arousal change per trigger (from the VRTouchEvents schema).
; arm: 0=bare, 1=clothes, 2=light armor, 3=heavy armor.  Returns 0 for
; non-intimate touches (no arousal effect).  The LLM adjusts around this
; baseline by personality + relationship (and may push it negative for an
; unwanted touch).
; ================================================================
Float Function GetArousal(String bp, Bool isGrab, Int arm) Global
    if bp == "left_breast" || bp == "right_breast"
        if arm <= 1
            if isGrab
                return 12.0
            EndIf
            return 10.0
        ElseIf arm == 2
            return 5.0
        EndIf
        return 3.0
    ElseIf bp == "genitals"
        if arm == 0
            if isGrab
                return 25.0
            EndIf
            return 20.0
        ElseIf arm == 1
            return 15.0
        EndIf
        return 10.0
    ElseIf bp == "butt"
        if arm <= 1
            if isGrab
                return 15.0
            EndIf
            return 10.0
        EndIf
        return 5.0
    ElseIf bp == "belly"
        if arm == 0
            if isGrab
                return 6.0
            EndIf
            return 4.0
        ElseIf arm == 1
            if isGrab
                return 4.0
            EndIf
            return 3.0
        EndIf
        return 0.0
    ElseIf bp == "face"
        return 4.0
    ElseIf bp == "head"
        if arm <= 1
            return 2.0
        EndIf
    EndIf
    return 0.0
EndFunction

; ================================================================
; Reaction Text
; n = NPC name, p = player name, a = armor/clothing name
; ================================================================
String Function GetReaction(String bp, Bool isGrab, Int arm, String n, String p, String a) Global
    ; --- HEAD ---
    if bp == "head"
        if !isGrab
            if arm <= 1
                return n + " feels " + p + "'s hand patting their head"
            EndIf
            return n + " feels " + p + "'s hand touching their " + a
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand grabbing their hair or head"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand grabbing their hair or hat"
        EndIf
        return n + " feels " + p + "'s hand grabbing their " + a
    EndIf

    ; --- FACE HOLD ---
    if bp == "face_hold"
        if arm == 0
            return n + " feels " + p + "'s hand holding their face"
        EndIf
        return n + " feels " + p + "'s hand holding their " + a
    EndIf

    ; --- FACE ---
    if bp == "face"
        if arm == 0
            return n + " feels " + p + "'s hand sliding along their face"
        EndIf
        return n + " feels " + p + "'s hand sliding along their " + a
    EndIf

    ; --- HANDS ---
    if bp == "hands"
        return p + " grabs " + n + " by the hand"
    EndIf

    ; --- ARMS ---
    if bp == "arms"
        if isGrab
            return n + " feels " + p + "'s hand grabbing them by the arm"
        EndIf
        return n + " feels " + p + "'s hand resting on their arm"
    EndIf

    ; --- FEET ---
    if bp == "feet"
        if isGrab
            if arm == 0
                return n + " feels " + p + "'s hand grabbing their foot"
            EndIf
            return n + " feels " + p + "'s hand grabbing their " + a
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand touching their foot"
        EndIf
        return n + " feels " + p + "'s hand touching their " + a
    EndIf

    ; --- LEGS ---
    if bp == "legs"
        if !isGrab
            if arm == 0
                return n + " feels " + p + "'s hand sliding along their naked leg"
            ElseIf arm == 1
                return n + " feels " + p + "'s hand along their leg over their " + a
            EndIf
            return n + " can see " + p + "'s hand resting on their " + a + " on their leg"
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand grabbing their naked leg"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand grabbing their leg over their " + a
        EndIf
        return n + " feels " + p + "'s hand grabbing their " + a + " on their leg"
    EndIf

    ; --- LEFT BREAST ---
    if bp == "left_breast"
        if !isGrab
            if arm == 0
                return n + " feels " + p + "'s hand resting on their naked left breast"
            ElseIf arm == 1
                return n + " feels " + p + "'s hand resting on their left breast through their clothes"
            ElseIf arm == 2
                return n + " feels " + p + "'s hand resting on their breast over their " + a
            EndIf
            return n + " can see " + p + "'s hand resting on their chest over their " + a
        EndIf
        ; Grab
        if arm == 0
            return n + " feels " + p + "'s hand on their naked left breast and squeezing it"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand grabbing their left breast through their clothes"
        ElseIf arm == 2
            return n + " feels " + p + "'s hand grabbing their breast over their " + a
        EndIf
        return n + " can see " + p + "'s hand grabbing their " + a + " over their chest"
    EndIf

    ; --- RIGHT BREAST ---
    if bp == "right_breast"
        if !isGrab
            if arm == 0
                return n + " feels " + p + "'s hand resting on their naked right breast"
            ElseIf arm == 1
                return n + " feels " + p + "'s hand resting on their right breast through their clothes"
            ElseIf arm == 2
                return n + " feels " + p + "'s hand resting on their breast over their " + a
            EndIf
            return n + " can see " + p + "'s hand resting on their chest over their " + a
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand on their naked right breast and squeezing it"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand grabbing their right breast through their clothes"
        ElseIf arm == 2
            return n + " feels " + p + "'s hand grabbing their breast over their " + a
        EndIf
        return n + " can see " + p + "'s hand grabbing their " + a + " over their chest"
    EndIf

    ; --- CHEST ---
    if bp == "chest"
        if arm == 0
            return n + " feels " + p + "'s hand resting on their naked chest"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand resting on their chest through their clothes"
        EndIf
        return n + " sees " + p + "'s hand resting on their chest over their " + a
    EndIf

    ; --- UPPER BACK ---
    if bp == "upper_back"
        if !isGrab
            if arm == 0
                return n + " feels " + p + "'s hand resting on their naked upper back"
            ElseIf arm == 1
                return n + " feels " + p + "'s hand resting on their upper back through their clothes"
            EndIf
            return n + " feels " + p + "'s hand resting on their upper back over their " + a
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand holding on their naked upper back"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand holding on their upper back through their clothes"
        EndIf
        return n + " feels " + p + "'s hand grabbing their " + a + " on their upper back"
    EndIf

    ; --- BELLY ---
    if bp == "belly"
        if !isGrab
            if arm == 0
                return n + " feels " + p + "'s hand resting on their naked belly"
            ElseIf arm == 1
                return n + " feels " + p + "'s hand resting on their belly through their clothes"
            EndIf
            return n + " feels " + p + "'s hand resting on front of their " + a + " at their navel"
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand holding on their naked belly"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand holding on their belly through their clothes"
        EndIf
        return n + " feels " + p + "'s hand grabbing on front of their " + a + " at their navel"
    EndIf

    ; --- LOWER BACK ---
    if bp == "lower_back"
        if !isGrab
            if arm == 0
                return n + " feels " + p + "'s hand resting on their naked lower back"
            ElseIf arm == 1
                return n + " feels " + p + "'s hand resting on their lower back through their clothes"
            EndIf
            return n + " feels " + p + "'s hand resting on back of their " + a + " at the lower back"
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand holding on their naked lower back"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand holding on their lower back through their clothes"
        EndIf
        return n + " feels " + p + "'s hand grabbing on back of their " + a + " at the lower back"
    EndIf

    ; --- GENITALS ---
    if bp == "genitals"
        if !isGrab
            if arm == 0
                return n + " feels " + p + "'s hand reaching between their legs and touching their private parts"
            ElseIf arm == 1
                return n + " feels " + p + "'s hand reaching between their legs and caressing their private parts over their pants"
            EndIf
            return n + " feels " + p + "'s hand reaching between their legs and caressing their private parts over their " + a
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand reaching between their legs and their finger penetrating their private parts"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand reaching between their legs and rubbing their private parts over their pants"
        EndIf
        return n + " feels " + p + "'s hand reaching between their legs and grabbing their " + a + " over their private parts"
    EndIf

    ; --- BUTT ---
    if bp == "butt"
        if !isGrab
            if arm == 0
                return n + " feels " + p + "'s hand on their naked butt"
            ElseIf arm == 1
                return n + " feels " + p + "'s hand on their butt through their clothes"
            ElseIf arm == 2
                return n + " feels " + p + "'s hand resting on their butt over their " + a
            EndIf
            return n + " can feel " + p + "'s hand resting on their butt over their " + a
        EndIf
        if arm == 0
            return n + " feels " + p + "'s hand grabbing their naked butt cheek"
        ElseIf arm == 1
            return n + " feels " + p + "'s hand grabbing their butt cheek through their clothes"
        EndIf
        return n + " feels " + p + "'s hand grabbing their " + a + " over their butt"
    EndIf

    ; --- TAIL ---
    if bp == "tail_base"
        return n + " feels " + p + "'s hand brushing against the base of their tail"
    EndIf
    if bp == "tail_tip"
        return n + " feels " + p + "'s hand brushing against the tip of their tail"
    EndIf

    return ""
EndFunction

; ================================================================
; Though vs Speak (schema column 7).
;   True  = unvoiced GenerateNPCThought — the NPC just NOTICES internally,
;           no spoken line (light / incidental / over-armor contact).
;   False = voiced reaction (RegisterShortLivedEvent) — the NPC reacts aloud
;           (intimate areas, bare skin, deliberate grabs).
; This mirrors the schema's Though/Speak column row-by-row.  arm: 0=bare,
; 1=clothes, 2=light armor, 3=heavy armor.
; ================================================================
Bool Function IsThought(String bp, Bool isGrab, Int arm) Global
    ; Head: thought only over armor (bare/clothes = speak)
    if bp == "head"
        return arm >= 2
    EndIf
    ; Hands (grab): thought
    if bp == "hands"
        return True
    EndIf
    ; Arms: touch = thought, grab = speak
    if bp == "arms"
        return !isGrab
    EndIf
    ; Feet: touch always thought; grab is thought only over clothes/armor (bare grab = speak)
    if bp == "feet"
        if !isGrab
            return True
        EndIf
        return arm >= 1
    EndIf
    ; Legs: touch bare=speak / clothes+armor=thought;  grab bare=thought / clothes=speak / armor=thought
    if bp == "legs"
        if !isGrab
            return arm >= 1
        EndIf
        return arm != 1
    EndIf
    ; Chest (touch only): bare=speak, clothes/armor=thought
    if bp == "chest"
        return arm >= 1
    EndIf
    ; Upper back: bare=speak, clothes/armor=thought (touch & grab)
    if bp == "upper_back"
        return arm >= 1
    EndIf
    ; Belly: bare/clothes=speak, armor=thought (touch & grab)
    if bp == "belly"
        return arm >= 2
    EndIf
    ; Lower back: touch bare/clothes=speak, armor=thought;  grab bare=thought / clothes=speak / armor=thought
    if bp == "lower_back"
        if !isGrab
            return arm >= 2
        EndIf
        return arm != 1
    EndIf
    ; Everything else (face, face_hold, breasts, genitals, butt, tails) = Speak
    return False
EndFunction
