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

; ################################################################
; ############  V3 (PPB coalescer) additions — APPEND-ONLY  ######
; ################################################################
; The V3 dispatcher (VRTouch_MainScript.OnVRTEContact*) receives the
; C++ coalescer's VRTE_* mod events, resolves each PPB sub-region +
; capsule name to a V3 body-part key, and reads policy from the V3*
; functions below.  Keys NOT owned by the new V3 tables FALL THROUGH
; to the existing V2 functions above, so the V2 data stays the single
; source of truth for the classic parts.
;
; V3-only keys:      clitoris, vaginal, vaginal_deep, uterus, anal,
;                    anal_deep, lips, mouth, mouth_wall, neck, ear,
;                    shoulder, waist, hips
; Fall-through keys: head, face, hands, arms, feet, legs, left_breast,
;                    right_breast, chest, belly, butt, genitals,
;                    tail_base, tail_tip
;
; PPB sub-region names are matched EXACTLY as SubRegionName() emits
; them (PpbApi.cpp SubRegionLabel) — Papyrus String == is case-
; insensitive, so casing drift is harmless.
; ================================================================

; True for the keys the V3 tables own (everything else falls through).
Bool Function V3IsV3Key(String key) Global
    return key == "clitoris" || key == "vaginal" || key == "vaginal_deep" \
        || key == "uterus" || key == "anal" || key == "anal_deep" \
        || key == "lips" || key == "mouth" || key == "mouth_wall" \
        || key == "neck" || key == "ear" || key == "shoulder" \
        || key == "waist" || key == "hips"
EndFunction

; True for the intimate/orifice ladder keys (always Speak + Interrupt).
Bool Function V3IsLadderKey(String key) Global
    return key == "clitoris" || key == "vaginal" || key == "vaginal_deep" \
        || key == "uterus" || key == "anal" || key == "anal_deep" \
        || key == "lips" || key == "mouth" || key == "mouth_wall"
EndFunction

; ================================================================
; V3MapKey — PPB (sub-region name, capsule name) -> V3 body-part key.
; Returns "" for unmapped/hair contacts (caller drops them).
; ================================================================
String Function V3MapKey(String sub, String part) Global
    ; --- Chest ---
    if sub == "Breast"
        if V3PartIsLeft(part)
            return "left_breast"
        EndIf
        return "right_breast"
    EndIf
    if sub == "Rib cage / back"
        return "chest"
    EndIf
    if sub == "Shoulder cap" || sub == "Shoulder"
        return "shoulder"
    EndIf

    ; --- Head / face / mouth ladder ---
    if sub == "Head"
        return "head"
    EndIf
    if sub == "Head (temple / ear)"
        return "ear"
    EndIf
    ; ⚠ "In mouth (deep floor)" is capsule 3.11, the UNDER-JAW — and it is
    ; FACE, not mouth.  It sits under the jawline and is reachable from
    ; OUTSIDE, so PPB can legitimately report it at depth 2 for a hand that
    ; is nowhere near her mouth.  Observed live 2026-08-02 09:33:52: a
    ; src=PALM contact narrated as "sliding into their mouth", which a palm
    ; physically cannot do.  Report 16 §4 specified `face`, and PPB excludes
    ; this same capsule (head C11) from its own mouth priority race for the
    ; identical reason — "promoting it would let a chin scritch outrank the
    ; face".  Authoritative "is something in her mouth" is the PPB_Mouth*
    ; gate stream, never a single capsule verdict.
    ; Keep this in step with V3PartOf, which routes the same sub-region.
    if sub == "Face surface" || sub == "In mouth (deep floor)"
        return "face"
    EndIf
    if sub == "Mouth opening"
        return "lips"
    EndIf
    if sub == "In mouth"
        return "mouth"
    EndIf
    if sub == "Mouth wall"
        return "mouth_wall"
    EndIf
    if sub == "Neck"
        return "neck"
    EndIf

    ; --- Torso ---
    if sub == "Belly / midriff"
        return "belly"
    EndIf
    if sub == "Waist band"
        return "waist"
    EndIf

    ; --- Pelvis ---
    if sub == "Pelvis / hip"
        ; v1 rule (report 14): the pubic mound + groin crease capsules are
        ; genital-adjacent external parts -> "genitals"; the rest of the
        ; pelvis ring is "hips".  Capsule names are lowercase in the PPB
        ; table ("pubic mound", "groin crease R") — Find is exact-case.
        if StringUtil.Find(part, "pubic") >= 0 || StringUtil.Find(part, "groin") >= 0
            return "genitals"
        EndIf
        return "hips"
    EndIf
    if sub == "Pelvis - orifice ring"
        return "genitals"
    EndIf
    if sub == "Glute"
        return "butt"
    EndIf

    ; --- Intimate ladder ---
    if sub == "Intimate - external"
        return "clitoris"
    EndIf
    if sub == "Intimate - vaginal (opening)"
        return "vaginal"
    EndIf
    if sub == "Intimate - vaginal (deep)"
        return "vaginal_deep"
    EndIf
    if sub == "Intimate - vaginal (deepest)"
        return "uterus"
    EndIf
    if sub == "Intimate - anal (opening)"
        return "anal"
    EndIf
    if sub == "Intimate - anal (deep)"
        return "anal_deep"
    EndIf

    ; --- Limbs (V2 keys) ---
    if sub == "Upper arm" || sub == "Forearm"
        return "arms"
    EndIf
    if sub == "Palm"
        return "hands"
    EndIf
    if sub == "Thigh" || sub == "Calf"
        return "legs"
    EndIf
    if sub == "Foot"
        return "feet"
    EndIf

    ; --- Tail ---
    if sub == "Tail - base (root third)" || sub == "Tail - mid (middle third)"
        return "tail_base"
    EndIf
    if sub == "Tail - tip (far third)"
        return "tail_tip"
    EndIf

    ; Hair is gated off at the PPB layer; anything unknown -> no key.
    return ""
EndFunction

; True if the capsule name is a LEFT-side part.  PPB uses both forms:
; trailing side on centreline slots ("BREAST L") and leading side on
; limb slots ("L thigh rod").  String == is case-insensitive.
Bool Function V3PartIsLeft(String part) Global
    Int len = StringUtil.GetLength(part)
    if len >= 2
        if StringUtil.Substring(part, len - 2) == " L"
            return True
        EndIf
        if StringUtil.Substring(part, 0, 2) == "L "
            return True
        EndIf
    EndIf
    return False
EndFunction

; ================================================================
; V3SlotKey — V3 key -> the V2 key whose GetSlotMask/GetArmorState
; bucket covers it (ladder -> genitals bucket incl. the underwear
; fallback slots; mouth/ear -> face slot 44; the rest -> body slot 32
; via GetSlotMask's default).
; ================================================================
String Function V3SlotKey(String key) Global
    if key == "clitoris" || key == "vaginal" || key == "vaginal_deep" \
    || key == "uterus" || key == "anal" || key == "anal_deep"
        return "genitals"
    EndIf
    if key == "lips" || key == "mouth" || key == "mouth_wall" || key == "ear"
        return "face"
    EndIf
    ; neck / shoulder / waist / hips and every fall-through key resolve
    ; themselves (GetSlotMask defaults unknown keys to body slot 32).
    return key
EndFunction

; ================================================================
; ARMOR SLOT CHAINS  (report 18 §2 FIX 1 / FIX 2, report 14 §4.2 C-4)
;
; TriggerLib only CLASSIFIES — MainScript owns V3ArmorState and does the
; GetWornForm probing.  The predicates below are the ONLY definition of
; which keys belong to which family, and V3SlotChain is written purely in
; terms of them, so the key lists cannot drift.  V3ArmorState consumes
; V3SlotChain (not the predicates directly) — one call, one source of
; truth for both "does this key need a chain" and "which masks".
; ================================================================

; The face family reads the WRONG slot on its own: GetSlotMask returns
; 16384 (slot 44) for face/face_hold, and vanilla Skyrim never uses slot
; 44 — helmets and hoods are slot 30 (mask 1).  Probe 44 first (true face
; masks), then 30.  Residual, accepted: slot 30 cannot tell an open helm
; from a closed one (report 14 rejected a 3-state face armor model).
; NOTE: mouth/mouth_wall are NOT in this family — see V3IsMouthKey.
Bool Function V3IsFaceFamily(String key) Global
    return key == "face" || key == "face_hold" || key == "lips" \
        || key == "ear"
EndFunction

; The MOUTH INTERIOR.  Split out of the face family on purpose: these two
; are the only face-side keys listed in V3PlausibilityDrop, so letting a
; slot-30 helmet raise them to arm>=2 would DELETE every in-mouth and
; throat-wall contact — the deepest rung of the ladder, and precisely the
; "real contact killed by a garment" failure the interior fix (D2) exists
; to stop.  A finger that PPB reports as inside the mouth got there; the
; helmet slot cannot tell us whether the visor was open.  So: slot 44
; ONLY, exactly as before the helmet chain was added.
Bool Function V3IsMouthKey(String key) Global
    return key == "mouth" || key == "mouth_wall"
EndFunction

; Interior (inside-an-orifice) keys.  These must NEVER read body slot 32:
; a robe on the body does not block access, but reading it as armor makes
; V3PlausibilityDrop kill a REAL penetration (confirmed live).  Probe the
; pelvis slots ONLY — 49 (524288) then 52 (4194304).  Nothing worn there
; => arm 0 = accessible; only real underwear blocks.
Bool Function V3IsInteriorKey(String key) Global
    return key == "clitoris" || key == "vaginal" || key == "vaginal_deep" \
        || key == "uterus" || key == "anal" || key == "anal_deep"
EndFunction

; The ordered GetWornForm masks for a key, as a 2-entry array.
;   [0] == 0  ->  NO override.  Use the legacy GetArmorState(npc,
;                 V3SlotKey(key)) path — which already chains
;                 32 -> 49 -> 52 for "genitals"/"butt".
;   [1] == 0  ->  the chain has only one step.
; Probe in order; the FIRST non-None worn form wins.
Int[] Function V3SlotChain(String key) Global
    Int[] chain = new Int[2]
    ; Mouth interior FIRST — it is a face-side key but must never chain
    ; to the helmet slot (see V3IsMouthKey).
    if V3IsMouthKey(key)
        chain[0] = 16384        ; slot 44 — true face mask
        chain[1] = 0            ; single-step chain: NO helmet fallback
        return chain
    EndIf
    if V3IsFaceFamily(key)
        chain[0] = 16384        ; slot 44 — true face mask
        chain[1] = 1            ; slot 30 — helmet / hood
        return chain
    EndIf
    if V3IsInteriorKey(key)
        chain[0] = 524288       ; slot 49 — pelvis / underwear
        chain[1] = 4194304      ; slot 52 — pelvis secondary
        return chain
    EndIf
    chain[0] = 0
    chain[1] = 0
    return chain
EndFunction

; ================================================================
; V3ArousalKey — V3 key -> the V2 key MaybeArousal/GetArousal should
; be fed (the existing arousal pipeline only knows V2 keys).
; ================================================================
String Function V3ArousalKey(String key) Global
    if key == "clitoris" || key == "vaginal" || key == "vaginal_deep" || key == "uterus"
        return "genitals"
    EndIf
    if key == "anal" || key == "anal_deep"
        return "butt"
    EndIf
    if key == "lips" || key == "mouth" || key == "mouth_wall" || key == "ear"
        return "face"
    EndIf
    return key
EndFunction

; ================================================================
; V3GetDelay — dwell (seconds) before a V3 contact fires.  Numbers
; from the report-14 schema sheet; ranged entries spread across the
; armor states (0=bare, 1=clothes, 2=light, 3=heavy).  Unknown keys
; fall through to the V2 GetDelay table.
; ================================================================
Float Function V3GetDelay(String key, Bool isGrab, Int arm) Global
    if key == "clitoris"
        return 0.3
    EndIf
    if key == "vaginal"
        return 0.0
    EndIf
    if key == "vaginal_deep"
        return 0.5
    EndIf
    if key == "uterus"
        return 1.0
    EndIf
    if key == "anal"
        return 0.3
    EndIf
    if key == "anal_deep"
        return 1.0
    EndIf
    if key == "lips"
        return 0.5
    EndIf
    if key == "mouth"
        return 0.0
    EndIf
    if key == "mouth_wall"
        return 0.5
    EndIf
    if key == "neck"
        ; 0.5 - 1.5, Suffix3 buckets (L+H armor combined)
        if arm == 0
            return 0.5
        ElseIf arm == 1
            return 1.0
        EndIf
        return 1.5
    EndIf
    if key == "ear"
        return 1.0
    EndIf
    if key == "shoulder"
        ; 1.5 - 3.0
        if arm == 0
            return 1.5
        ElseIf arm == 1
            return 2.0
        ElseIf arm == 2
            return 2.5
        EndIf
        return 3.0
    EndIf
    if key == "waist"
        ; 1.5 - 4.0
        if arm == 0
            return 1.5
        ElseIf arm == 1
            return 2.0
        ElseIf arm == 2
            return 3.0
        EndIf
        return 4.0
    EndIf
    if key == "hips"
        ; 2.0 - 4.5
        if arm == 0
            return 2.0
        ElseIf arm == 1
            return 3.0
        ElseIf arm == 2
            return 4.0
        EndIf
        return 4.5
    EndIf
    return GetDelay(key, isGrab, arm)
EndFunction

; ================================================================
; V3GetArousal — baseline arousal per V3 key (report-14 numbers).
; Unknown keys fall through to the V2 GetArousal table.
; ================================================================
Float Function V3GetArousal(String key, Bool isGrab, Int arm) Global
    if key == "clitoris"
        if arm == 0
            if isGrab
                return 22.0
            EndIf
            return 20.0
        ElseIf arm == 1
            return 12.0
        EndIf
        return 5.0
    EndIf
    if key == "vaginal"
        return 23.0
    EndIf
    if key == "vaginal_deep"
        return 24.0
    EndIf
    if key == "uterus"
        return 25.0
    EndIf
    if key == "anal"
        return 15.0
    EndIf
    if key == "anal_deep"
        return 18.0
    EndIf
    if key == "lips"
        return 6.0
    EndIf
    if key == "mouth"
        return 12.0
    EndIf
    if key == "mouth_wall"
        return 14.0
    EndIf
    if key == "neck"
        return 4.0
    EndIf
    if key == "ear"
        return 5.0
    EndIf
    if key == "shoulder"
        return 1.0
    EndIf
    if key == "waist"
        return 2.0
    EndIf
    if key == "hips"
        return 3.0
    EndIf
    return GetArousal(key, isGrab, arm)
EndFunction

; ================================================================
; V3IsThought — True = unvoiced GenerateNPCThought, False = spoken.
; Ladder keys always SPEAK.  Unknown keys fall through to V2 IsThought
; (isGrab is optional so the (key, arm) call form stays valid).
; ================================================================
Bool Function V3IsThought(String key, Int arm, Bool isGrab = False) Global
    if V3IsLadderKey(key)
        return False
    EndIf
    if key == "neck" || key == "ear" || key == "waist" || key == "hips"
        return arm >= 2
    EndIf
    if key == "shoulder"
        return arm >= 1
    EndIf
    return IsThought(key, isGrab, arm)
EndFunction

; ================================================================
; V3IsInterrupting — bypasses the per-NPC cooldown.  All ladder keys
; interrupt; the other V3 keys never do; unknown keys fall through
; to V2 IsInterrupting.
; ================================================================
Bool Function V3IsInterrupting(String key, Int arm, Bool isGrab = False) Global
    if V3IsLadderKey(key)
        return True
    EndIf
    if key == "neck" || key == "ear" || key == "shoulder" || key == "waist" || key == "hips"
        return False
    EndIf
    return IsInterrupting(key, isGrab, arm)
EndFunction

; ================================================================
; V3IsPrivate — True routes the narration through the PRIVATE YAML
; (audience: target only).  Intimate/ladder keys (incl. genitals)
; always; breasts + butt only bare/clothes.
; ================================================================
Bool Function V3IsPrivate(String key, Int arm) Global
    if V3IsLadderKey(key) || key == "genitals"
        return True
    EndIf
    if key == "left_breast" || key == "right_breast" || key == "butt"
        return arm <= 1
    EndIf
    return False
EndFunction

; ================================================================
; V3PlausibilityDrop — an INTERIOR contact (inside an orifice) while
; the covering gear is light/heavy armor is a detection artefact
; (a finger cannot be inside through plate) -> drop the event.
; ================================================================
Bool Function V3PlausibilityDrop(String key, Int arm) Global
    if arm < 2
        return False
    EndIf
    return key == "vaginal" || key == "vaginal_deep" || key == "uterus" \
        || key == "anal" || key == "anal_deep" \
        || key == "mouth" || key == "mouth_wall"
EndFunction

; ================================================================
; V3JsonEscape — escape '\' and '"' for embedding free text (player /
; armor / weapon / capsule names, narration) in a JSON string value.
; The fast path (no escapable chars, the overwhelming case) is two
; Finds and no allocation loop.
; ================================================================
String Function V3JsonEscape(String s) Global
    if StringUtil.Find(s, "\"") < 0 && StringUtil.Find(s, "\\") < 0
        return s
    EndIf
    String out = ""
    Int i = 0
    Int n = StringUtil.GetLength(s)
    while i < n
        String ch = StringUtil.Substring(s, i, 1)
        if ch == "\"" || ch == "\\"
            out += "\\"
        EndIf
        out += ch
        i += 1
    EndWhile
    return out
EndFunction

; ================================================================
; Narration builder pieces
; ================================================================
; ★★ THE CASING PROBLEM — WHY THERE IS NO `V3Lower` ANY MORE (2026-08-02)
;
; Bethesda documents the mechanism in the shipped StringUtil.psc header:
; every Papyrus string lives in ONE process-global, case-INSENSITIVE cache,
; and "which string is used depends greatly on which version is found
; first".  Any string equal-ignoring-case to one already in the cache comes
; back wearing the OTHER one's casing.
;
; Two runtime-lowercasing attempts were made and BOTH corrupted the output:
;   v1  declared "ABC...Z" and "abc...z" — case-insensitive TWINS that
;       collapse to one cache entry, making the function the identity.
;   v2  broke the twinning with a caseless lead char.  It still failed, and
;       the live log of 2026-08-02 09:33 shows why: PPB sent the LOWERCASE
;       'L forearm (wrist half)' and we printed 'FOREARM WRIST HALF'.
;       The loop's inner `StringUtil.Substring(lo, idx, 1)` returns a
;       ONE-CHARACTER string, and single characters are the most
;       collision-prone entries that can exist in a case-insensitive cache —
;       every letter comes back in whatever case some other mod interned it
;       as.  A per-character mapper can therefore NEVER be made reliable.
;
; So the approach is inverted: **do not transform case at runtime at all.**
;   1. PPB's capsule names are already lowercase except for eight entries,
;      which are handled by an explicit table (V3PreciseOf).
;   2. Our own display words are emitted as LONG, MULTI-WORD literals
;      ("'s belly", "their left palm", " (right breast)") instead of short
;      common ones ("belly", "palm", "breast").  A short literal like "belly"
;      is near-certain to have a twin somewhere in a 2000-mod load order;
;      "'s belly" is near-certain not to.
;   3. Anything genuinely proper-noun — a weapon or object name — is passed
;      through UNCHANGED, because "Village Red Wine" is correct as-is.
;
; Residual, accepted and stated honestly: this makes corruption unlikely, not
; impossible.  Papyrus offers no way to guarantee the case of a string it
; hands back, so an occasional capitalised word may still appear.  It is
; cosmetic and the LLM is unaffected by it.

; ⚠ V3StripParens WAS HERE AND IS DELETED (2026-08-02, second pass).
; It walked the capsule name character by character to remove PPB's own
; brackets — the SAME per-character `StringUtil.Substring(s, i, 1)` pattern
; that got V3Lower deleted, and for the same reason.  It printed
; `(Under-JAW DEEP)` for PPB's lowercase `under-jaw (deep)`.  Removing
; V3Lower while leaving this standing was an oversight; parenthesised
; capsule names are now explicit rows in V3PreciseOf, which preserves the
; detail (the user's rule: this context is worth having) with no runtime
; string surgery at all.
;
; RULE: if you find yourself indexing a Papyrus string one character at a
; time to build another string, stop — the result will be case-corrupted.

; PPB's three tail sub-regions -> the one-word zone the narration uses.
; Returns "" for anything that is not a tail sub-region.
; (Keying is separate and unchanged — see V3MapKey: base+mid -> tail_base,
;  tip -> tail_tip, because V2 only ever had those two trigger families.)
String Function V3TailZone(String sub) Global
    if sub == "Tail - base (root third)"
        return "base"
    EndIf
    if sub == "Tail - mid (middle third)"
        return "middle"
    EndIf
    if sub == "Tail - tip (far third)"
        return "tip"
    EndIf
    return ""
EndFunction

; The MAIN (coarse) body part, returned as a POSSESSIVE SUFFIX so the caller
; can write `npcName + V3PartOf(sub)` -> "Carmella's belly".
;
; Every return value carries the "'s " prefix ON PURPOSE.  It is not a
; convenience: it is what keeps the literal out of the string cache's way.
; A bare "belly" or "anus" is a short common word that other mods in a
; 2000-mod load order have certainly interned (the 2026-08-02 log printed
; `their Belly` and `their Anus` for exactly that reason).  "'s belly" has no
; plausible twin.  See the casing note above.
;
; ⚠ "In mouth (deep floor)" (capsule 3.11, under-jaw) is FACE, not mouth.
;   It sits under the jaw and is reachable from OUTSIDE, so a palm cupped
;   under the chin used to narrate as "sliding into their mouth" — observed
;   live 2026-08-02 09:33:52 with src=PALM, which cannot be inside a mouth.
;   Report 16 §4 specified `face`; PPB excludes the same capsule from its own
;   mouth priority set for the same reason.  Keep these two in step with
;   V3MapKey.
;
; ⚠ Takes the CAPSULE as well as the sub-region, and it must: PPB's
; "Pelvis / hip" sub-region covers both the hip proper and the pubic mound /
; groin creases, and V3MapKey already splits those two apart (the latter
; resolve to the `genitals` key).  Keying the narration on the sub-region
; ALONE made the two halves disagree — the 2026-08-02 22:16 log fired
; `key=Genitals priv=1` (genital delay, genital arousal, private audience)
; while telling the LLM "Carmella's hip".  The split is duplicated here on
; purpose rather than passing the resolved key in: V3PartOf is also called
; for the choke's free-hand thought, which has no key.
String Function V3PartOf(String sub, String part) Global
    if sub == "Breast" || sub == "Rib cage / back"
        return "'s chest"
    EndIf
    if sub == "Shoulder cap" || sub == "Shoulder"
        return "'s shoulder"
    EndIf
    if sub == "Head"
        return "'s head"
    EndIf
    if sub == "Head (temple / ear)"
        return "'s ear"
    EndIf
    ; under-jaw rides with the face — see the banner above
    if sub == "Face surface" || sub == "In mouth (deep floor)"
        return "'s face"
    EndIf
    if sub == "Mouth opening"
        return "'s lips"
    EndIf
    if sub == "In mouth" || sub == "Mouth wall"
        return "'s mouth"
    EndIf
    if sub == "Neck"
        return "'s throat"
    EndIf
    if sub == "Belly / midriff"
        return "'s belly"
    EndIf
    if sub == "Waist band"
        return "'s waist"
    EndIf
    if sub == "Pelvis / hip"
        ; Same split as V3MapKey — keep the two in step.  Capsule names are
        ; lowercase in PPB's table ("pubic mound", "groin crease R").
        if StringUtil.Find(part, "pubic") >= 0 || StringUtil.Find(part, "groin") >= 0
            return "'s groin"
        EndIf
        return "'s hip"
    EndIf
    if sub == "Pelvis - orifice ring"
        return "'s groin"
    EndIf
    if sub == "Glute"
        return "'s backside"
    EndIf
    if sub == "Intimate - external"
        return "'s clitoris"
    EndIf
    if sub == "Intimate - vaginal (opening)" || sub == "Intimate - vaginal (deep)"
        return "'s vagina"
    EndIf
    if sub == "Intimate - vaginal (deepest)"
        return "'s womb"
    EndIf
    if sub == "Intimate - anal (opening)" || sub == "Intimate - anal (deep)"
        return "'s anus"
    EndIf
    if sub == "Upper arm" || sub == "Forearm"
        return "'s arm"
    EndIf
    if sub == "Palm"
        return "'s hand"
    EndIf
    if sub == "Thigh"
        return "'s thigh"
    EndIf
    if sub == "Calf"
        return "'s leg"
    EndIf
    if sub == "Foot"
        return "'s foot"
    EndIf
    if sub == "Tail - base (root third)" || sub == "Tail - mid (middle third)" || sub == "Tail - tip (far third)"
        return "'s tail"
    EndIf
    if sub == "Hair"
        return "'s hair"
    EndIf
    return "'s body"
EndFunction

; ================================================================
; V3PreciseOf — the PRECISE locator, as a COMPLETE parenthetical.
; ================================================================
; Returns " (right breast)" / " (left forearm, wrist end)" / "" — brackets
; included in the literal, deliberately.  The user's rule (2026-08-02) is
; that this detail is VALUABLE — "touched her face (left cheek)" gives the
; LLM context worth having — so nothing here may trade accuracy for safety.
;
; ★ WHY THIS IS A TABLE AND NOT STRING SURGERY
; The 2026-08-02 22:16 log printed `(Under-JAW DEEP)` for PPB's lowercase
; `under-jaw (deep)`.  Cause: V3StripParens walks the name CHARACTER BY
; CHARACTER, and a one-character `StringUtil.Substring` is the most
; collision-prone value that can exist in Papyrus's process-global
; case-insensitive string cache — the exact defect that made V3Lower
; unfixable and got it deleted.  I removed V3Lower and left its twin
; standing; this is that oversight closed.
;
; The table works because of an asymmetry worth remembering:
;   • the LOOKUP is immune — Papyrus `==` is case-INSENSITIVE, so a `part`
;     that the cache already re-cased still matches its row;
;   • only the RETURNED literal reaches the player, and each one is made
;     collision-proof by its own punctuation.  " (chin)" has no plausible
;     twin in any load order; the bare word "chin" certainly does.
; So every entry carries its brackets AND its side word — never assembled
; from pieces at runtime, because each piece would be looked up separately.
;
; Anything NOT tabled falls through to the long-slice path at the bottom,
; which is safe for multi-word names (`cheekbone L` -> `(left cheekbone)`
; was correct in that same log).  That is deliberate: a PPB rename of a long
; name keeps working instead of silently drifting against a hardcoded copy.
; Names are from capsule_api_names.md — generated from PPB's own
; ProposedPartName() and cross-checked against the shipped DLL.
String Function V3PreciseOf(String sub, String part) Global
    String zone = V3TailZone(sub)
    if zone != ""
        return " (" + zone + ")"
    EndIf
    if part == ""
        return ""
    EndIf

    ; --- Redundant with the main word: say nothing rather than
    ;     "Carmella's clitoris (clitoris)". ---
    if part == "CLITORIS" || part == "neck / throat"
        return ""
    EndIf

    ; --- HEAD (slot 3, centreline) ---
    if part == "chin R"
        return " (right side of the chin)"
    EndIf
    if part == "chin L"
        return " (left side of the chin)"
    EndIf
    if part == "cheek R"
        return " (right cheek)"
    EndIf
    if part == "cheek L"
        return " (left cheek)"
    EndIf
    if part == "nose"
        return " (the nose)"
    EndIf
    if part == "palate"
        return " (the palate)"
    EndIf
    if part == "under-jaw (deep)"
        return " (under the jaw)"
    EndIf

    ; --- CHEST / BACK (slot 6) ---
    if part == "BREAST R"
        return " (right breast)"
    EndIf
    if part == "BREAST L"
        return " (left breast)"
    EndIf
    if part == "BACK (upper)"
        return " (upper back)"
    EndIf
    if part == "lat R"
        return " (right lat)"
    EndIf
    if part == "lat L"
        return " (left lat)"
    EndIf

    ; --- BELLY / WAIST (slots 4, 5) ---
    if part == "belly / navel (FRONT)"
        return " (the navel)"
    EndIf
    if part == "BACK (lower)"
        return " (lower back)"
    EndIf
    if part == "flank R"
        return " (right flank)"
    EndIf
    if part == "flank L"
        return " (left flank)"
    EndIf

    ; --- PELVIS / INTIMATE (slot 11) ---
    if part == "BUTT CHEEK R"
        return " (right cheek)"
    EndIf
    if part == "BUTT CHEEK L"
        return " (left cheek)"
    EndIf
    if part == "hip R"
        return " (right hip)"
    EndIf
    if part == "hip L"
        return " (left hip)"
    EndIf
    if part == "orifice ring (base)"
        return " (the base of the opening)"
    EndIf
    if part == "orifice ring (mid)"
        return " (the middle of the opening)"
    EndIf
    if part == "orifice ring (upper)"
        return " (the top of the opening)"
    EndIf
    if part == "rear centreline R (twin)"
        return " (right of the cleft)"
    EndIf
    if part == "anus R"
        return " (right of the opening)"
    EndIf
    if part == "anus L"
        return " (left of the opening)"
    EndIf
    if part == "cervix R"
        return " (right of the cervix)"
    EndIf
    if part == "cervix L"
        return " (left of the cervix)"
    EndIf
    if part == "uterus R"
        return " (right of the womb)"
    EndIf
    if part == "uterus L"
        return " (left of the womb)"
    EndIf
    if part == "rectum R"
        return " (right of the rectum)"
    EndIf
    if part == "rectum L"
        return " (left of the rectum)"
    EndIf

    ; --- ARMS (slots 0, 1, 2 — sided, so PPB prefixes "L "/"R ") ---
    if part == "L forearm (elbow half)"
        return " (left forearm, elbow end)"
    EndIf
    if part == "R forearm (elbow half)"
        return " (right forearm, elbow end)"
    EndIf
    if part == "L forearm (wrist half)"
        return " (left forearm, wrist end)"
    EndIf
    if part == "R forearm (wrist half)"
        return " (right forearm, wrist end)"
    EndIf
    if part == "L upper arm (shoulder half)"
        return " (left upper arm, near the shoulder)"
    EndIf
    if part == "R upper arm (shoulder half)"
        return " (right upper arm, near the shoulder)"
    EndIf
    if part == "L upper arm (elbow half)" || part == "L upper arm (elbow half, inner twin)"
        return " (left upper arm, near the elbow)"
    EndIf
    if part == "R upper arm (elbow half)" || part == "R upper arm (elbow half, inner twin)"
        return " (right upper arm, near the elbow)"
    EndIf
    if part == "L palm centre (1)" || part == "L palm centre (2)"
        return " (centre of the left palm)"
    EndIf
    if part == "R palm centre (1)" || part == "R palm centre (2)"
        return " (centre of the right palm)"
    EndIf

    ; --- LEGS / FEET (slots 8, 9, 10 — sided) ---
    if part == "L knee"
        return " (left knee)"
    EndIf
    if part == "R knee"
        return " (right knee)"
    EndIf
    if part == "L shin (lower)"
        return " (lower left shin)"
    EndIf
    if part == "R shin (lower)"
        return " (lower right shin)"
    EndIf
    if part == "L sole (inner)" || part == "L sole (outer)"
        return " (sole of the left foot)"
    EndIf
    if part == "R sole (inner)" || part == "R sole (outer)"
        return " (sole of the right foot)"
    EndIf
    if part == "L arch"
        return " (left arch)"
    EndIf
    if part == "R arch"
        return " (right arch)"
    EndIf

    ; --- Fallback: multi-word lowercase names, safe via long slices only ---
    ; No per-character work happens here.  `Substring` results are whole
    ; words or longer ("cheekbone", "vaginal opening", "upper glute"), which
    ; are long enough to be effectively collision-free.  Any PPB name that
    ; turns out NOT to be gets a row above.
    Int len = StringUtil.GetLength(part)
    if len >= 3
        String tail2 = StringUtil.Substring(part, len - 2)
        if tail2 == " R"
            return " (right " + StringUtil.Substring(part, 0, len - 2) + ")"
        EndIf
        if tail2 == " L"
            return " (left " + StringUtil.Substring(part, 0, len - 2) + ")"
        EndIf
        String head2 = StringUtil.Substring(part, 0, 2)
        if head2 == "R "
            return " (right " + StringUtil.Substring(part, 2) + ")"
        EndIf
        if head2 == "L "
            return " (left " + StringUtil.Substring(part, 2) + ")"
        EndIf
    EndIf
    return " (" + part + ")"
EndFunction

; WHAT is doing the touching, as a complete phrase ("their left palm").
; wand ∈ "L"/"R"; src ∈ FINGER/PALM/FIST/HAND/GRAB/WEAPON/OBJECT.
;
; Every hand form is a whole three-word literal rather than `side + "palm"`.
; That is the string-cache defence again: the live log of 2026-08-02 printed
; `with their right PALM` because the bare literal "palm" collided with some
; other mod's "PALM".  "their left palm" has no plausible twin.
;
; Weapon and object names are passed through UNCHANGED — they are proper
; nouns and "their Village Red Wine" is already correct.  The old code ran
; them through V3Lower, which is exactly how `with their Doublet` and the
; uppercase mangling got in.
String Function V3SourceOf(String wand, String src, String name) Global
    Bool left = (wand == "L")

    if src == "FINGER"
        if left
            return "their left fingertip"
        EndIf
        return "their right fingertip"
    EndIf
    if src == "PALM"
        if left
            return "their left palm"
        EndIf
        return "their right palm"
    EndIf
    if src == "FIST"
        if left
            return "their left fist"
        EndIf
        return "their right fist"
    EndIf
    if src == "GRAB"
        ; Adjective, not a trailing clause.  "their left hand, gripping"
        ; collided with the ", and" that joins the two-hand form and produced
        ; "...with their left hand, gripping, and resting on..." — three
        ; commas in a row (2026-08-02 22:17 log).
        if left
            return "their gripping left hand"
        EndIf
        return "their gripping right hand"
    EndIf
    if src == "WEAPON"
        if name != ""
            return "their " + name
        EndIf
        return "their drawn weapon"
    EndIf
    if src == "OBJECT"
        if name != ""
            return "the " + name + " they are holding"
        EndIf
        return "an object they are holding"
    EndIf
    ; HAND, and any source class a future PPB revision adds
    if left
        return "their left hand"
    EndIf
    return "their right hand"
EndFunction

; ================================================================
; V3EffectiveDepth — PPB's depth level, corrected for one liar.
; ================================================================
; PPB's depth comes from the SUB-REGION LABEL, not from where the probe
; physically is.  `In mouth (deep floor)` is capsule 3.11, the under-jaw,
; and it carries depth 2 — but it is an OUTSIDE surface reachable under the
; jawline (PPB excludes the same capsule from its own mouth priority race
; for exactly this reason).  So a palm cupped under her chin arrived at
; V3IntensityVerb with depth 2 and narrated as "sliding into Carmella's
; face" (2026-08-02 22:16 log).
;
; Fixing the KEY was only half of it — V3MapKey now routes this sub-region
; to `face`, but the verb reads depth independently, so it needs the same
; correction.  Clamp to 0: whatever is touching that capsule came from
; outside, so it can only ever be a surface contact.
;
; This stays correct even after the reported PPB geometry fix (a hole under
; the jaw allowing real interior reach): the fix removes the *false* interior
; contacts, but the sub-region's depth-2 label is unchanged, so an ordinary
; under-jaw touch would still claim penetration without this.
Int Function V3EffectiveDepth(String sub, Int dep) Global
    if sub == "In mouth (deep floor)"
        return 0
    EndIf
    return dep
EndFunction

; Intensity verb from the deepest surface distance (units; negative =
; inside) and the sub-region depth level (>=2 = inside an orifice).
;   >= 0      hover / brush
;   0 .. -1.0 resting
; -1.0 ..-2.5 pressing
;   < -2.5    pressing firmly / deep
String Function V3IntensityVerb(Float dist, Int depth) Global
    if depth >= 2
        ; Interior contact — phrase as penetration.
        if dist <= -2.5
            return "pushing deep into"
        EndIf
        return "sliding into"
    EndIf
    if dist >= 0.0
        return "brushing against"
    EndIf
    if dist > -1.0
        return "resting on"
    EndIf
    if dist > -2.5
        return "pressing into"
    EndIf
    return "pressing firmly into"
EndFunction

; ================================================================
; V3Narration — a STATEMENT OF FACT, nothing more.
;
;   <Player> is <intensity> <NPC>'s <part> (<precise>) with <source>
;      [, and <intensity2> <NPC>'s <part2> (<precise2>) with <source2> ]
;      [, held for <N> seconds ]
;
; ★ THE RULE (user directive, 2026-08-02): we report the physical act and
;   NOTHING else.  WHO did it, WHERE they touched, WITH WHAT, HOW HARD, and
;   HOW LONG.  We never state or imply how the NPC feels about it, never
;   assign an emotion, never colour the verb, and never call a touch welcome,
;   unwanted, intimate, violating or affectionate.  Whether the act was good
;   or bad is the LLM's judgement to make from that NPC's own personality and
;   their history with the player — it is not ours to prejudge, and a mod
;   that prejudges it makes every NPC react the same way.
;
;   Concretely this is why "<NPC> feels <Player> ..." was dropped: it framed
;   the event as the NPC's sensation.  The new form is a third-party
;   observation of an action, which is all we can honestly claim to know.
;   The intensity verbs are physical descriptors only (brushing / resting /
;   pressing / sliding into) and must stay that way — do not "improve" them
;   into words like teasing, caressing, groping or violating.
;
;   The one place a judgement IS wanted is the arousal query, and that is
;   already correct: vrtouch_arousal.prompt hands the LLM this narration plus
;   the NPC's rapport/trust/loyalty/mood and lets it choose the sign, saying
;   in as many words that an unwelcome touch should go negative.  It reads
;   this string, so this string must stay clean.
;
; Example:
;   "Telord is pressing firmly into Carmella's chest (right breast) with
;    their left palm, and brushing against Carmella's belly (navel) with
;    their right fingertip, held for 4 seconds."
; ================================================================
String Function V3Narration(String npcName, String playerName, \
        String sub1, String part1, String w1, String src1, String name1, Float dist1, Int dep1, \
        String sub2, String part2, String w2, String src2, String name2, Float dist2, Int dep2, \
        Float durS) Global
    String s = playerName + " is " + V3IntensityVerb(dist1, V3EffectiveDepth(sub1, dep1)) + " " \
        + npcName + V3PartOf(sub1, part1) + V3PreciseOf(sub1, part1) \
        + " with " + V3SourceOf(w1, src1, name1)

    if w2 != "" && sub2 != ""
        ; dep2 (payload field 12) is passed for the SAME reason dep1 is:
        ; without it a second hand inside the mouth or vagina narrated as
        ; "pressing firmly into" instead of "sliding into" / "pushing deep
        ; into" — the depth ladder was silently missing from clause two.
        s += ", and " + V3IntensityVerb(dist2, V3EffectiveDepth(sub2, dep2)) + " " \
            + npcName + V3PartOf(sub2, part2) + V3PreciseOf(sub2, part2) \
            + " with " + V3SourceOf(w2, src2, name2)
    EndIf

    ; Duration is part of "what happened" — a 12-second hold and a brush are
    ; different acts.  Only stated once it is long enough to mean something.
    if durS >= 2.0
        return s + ", held for " + (durS as Int) + " seconds."
    EndIf
    return s + "."
EndFunction
