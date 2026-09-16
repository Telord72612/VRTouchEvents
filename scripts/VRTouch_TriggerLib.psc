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
; ★ REWORKED 2026-08-23 (user): "Turn a lot of the lesser interrupt into
; directNarration, except the really intrusive one like intimate touch."
; TriggerInterruptDialogue is GLOBAL (cuts every actor's queue), so every
; demotion here directly reduces collateral.  What still interrupts:
;   - genitals BARE (touch or grab) — reaching between bare legs.
;   - breast GRAB, BARE only — a hand closing on a naked breast.
;   - the intimate ladder (V3IsLadderKey, handled upstream) — unchanged.
; Demoted to plain Speak: breast TOUCH (bare/clothed), breast grab through
; clothes, genitals through clothes/armor, and ALL butt rows.
; ⚠ CORRECTED 2026-09-02: this line used to claim breast interrupts are
; "GRAB, BARE only" and that "isGrab is read again".  The BODY BELOW NEVER
; READS isGrab — a BARE breast TOUCH interrupts too, exactly as the inline
; ladder note a few lines down already says.  Trust the ladder note.
Bool Function IsInterrupting(String bp, Bool isGrab, Int arm) Global
    if bp == "genitals"
        return arm == 0
    EndIf
    ; ★ BREAST LADDER (user, 2026-08-23), stated exactly:
    ;   naked  -> "clearly an interrupt"   (touch OR grab — not grab-only)
    ;   clothes / light armor -> DirectNarration (plain Speak)
    ;   heavy armor -> "just an event"     (Persistent — see V3IsPersistent)
    ; Male chest never reaches here: V3MapKey routes male pecs to "chest".
    if bp == "left_breast" || bp == "right_breast"
        return arm == 0
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
; Though vs Speak (schema column 7).
;   True  = unvoiced GenerateNPCThought — the NPC just NOTICES internally,
;           no spoken line (light / incidental / over-armor contact).
;   False = voiced reaction — the NPC reacts aloud.  ★ CORRECTED 2026-09-02:
;           this said "(RegisterShortLivedEvent)".  VRTE calls that function
;           ZERO times.  A voiced reaction is DirectNarration, a direct API
;           call (the AddOn is the only RegisterShortLivedEvent user here)
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
String Function V3MapKey(String sub, String part, Int isMale = 0) Global
    ; ================================================================
    ; ★ MALE UPDATE (2026-08-23) — male intercepts run FIRST.
    ;
    ; The shaft chords are proof by existence (only TNG males carry the
    ; GEN rig, PPB slot 102), so they need no sex test.  Everything else
    ; DOES: PPB stamps male contacts with the FEMALE (slot,child) sub-
    ; region map (StampClass has no isMale — PpbApi.cpp:464), so a male
    ; anal capsule arrives labelled "Intimate - vaginal (opening)" and a
    ; male pec arrives as sub "Breast".  Only the capsule NAME is sex-
    ; correct on male COM (MalePartNameOverride).  The PPB handoff
    ; request (report 24) asks for the stamp fix; until then the NAME is
    ; the truth on males and the sub label is a lie.
    ; ================================================================
    if part == "shaft (base)" || part == "shaft (lower)" \
        || part == "shaft (upper)" || part == "shaft (tip)" || part == "shaft"
        return "male_genitals"
    EndIf
    if isMale
        ; Male pecs report "BREAST R/L" under sub "Breast" (shared spine2
        ; table).  On a man that is CHEST — never the breast keys, which
        ; interrupt and arouse.  This single mapping IS the user's "male
        ; chest is never an interrupt, whatever dress state" rule: the
        ; chest key has no interrupt row at any armor state.
        if sub == "Breast"
            return "chest"
        EndIf
        ; Male COM capsules, matched by their sex-correct NAMES:
        if part == "anus R" || part == "anus L"
            return "anal"
        EndIf
        if part == "rectum R" || part == "rectum L"
            return "anal_deep"
        EndIf
        if part == "anal cover R" || part == "anal cover L"
            return "butt"
        EndIf
        ; ⚠ Male COM C0-C2 stamp kSubOrificeRing ("Pelvis - orifice ring") just
        ; like a female's — but on him that is the groin, and the female path
        ; below would send it to the "genitals" key, which INTERRUPTS when bare.
        ; The user's rule is that male genital contact is never an interrupt, so
        ; it routes to male_genitals instead (never interrupts, private).
        if sub == "Pelvis - orifice ring"
            return "male_genitals"
        EndIf
        ; Any remaining female-ladder label on a male IS the mis-stamp —
        ; males have no clitoris and no vaginal chain.  Drop, never
        ; mis-narrate.
        if sub == "Intimate - external" || sub == "Intimate - vaginal (opening)" \
            || sub == "Intimate - vaginal (deep)" || sub == "Intimate - vaginal (deepest)"
            return ""
        EndIf
    EndIf
    ; --- Chest ---
    if sub == "Breast"
        if V3PartIsLeft(part)
            return "left_breast"
        EndIf
        return "right_breast"
    EndIf
    ; ⚠ "Rib cage / back" covers BOTH the front ribs and the upper back.
    ; PPB names exactly one capsule there for the back (spine2 C17,
    ; "BACK (upper)"), so the capsule name is the whole discriminator.
    ; Without this split a hand on her spine narrated as "chest".
    ; Find is case-SENSITIVE and PPB spells this one in caps.
    if sub == "Rib cage / back"
        if StringUtil.Find(part, "BACK") >= 0
            return "upper_back"
        EndIf
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
    ; Same split one segment down: spine1 C9 is "BACK (lower)".
    if sub == "Belly / midriff"
        if StringUtil.Find(part, "BACK") >= 0
            return "lower_back"
        EndIf
        return "belly"
    EndIf
    ; And spine0 C5/C6 are literally named "lower back R"/"lower back L" —
    ; lowercase this time, and in the Waist band sub-region rather than the
    ; belly one. They were reporting as "waist"; they are the lower back.
    if sub == "Waist band"
        if StringUtil.Find(part, "lower back") >= 0
            return "lower_back"
        EndIf
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
    if key == "male_genitals"
        return "genitals"
    EndIf
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
; Which PLUGGABLE ORIFICE a key belongs to - "" when it is not one.
;
; ⚠ DELIBERATELY NOT V3IsInteriorKey.  That predicate includes `clitoris`
; because it exists to pick the pelvis armor SLOT CHAIN, not to describe
; penetration.  The clitoris is external: a plug does not occupy it, and the
; user's rule is about "a finger entering that orifice".  Reusing the interior
; predicate here would silence external contact on a plugged NPC, which is
; wrong - and V3SlotChain depends on it, so it must not be edited to suit this.
String Function V3PlugSiteOfKey(String key) Global
    if key == "vaginal" || key == "vaginal_deep" || key == "uterus"
        return "vaginal"
    EndIf
    if key == "anal" || key == "anal_deep"
        return "anal"
    EndIf
    return ""
EndFunction

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
    if key == "male_genitals"
        return "genitals"
    EndIf
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
    ; Male genitals: deliberate but responsive bare (0.5s), slower as layers
    ; mute it — same shape as the female external-genital rows.
    if key == "male_genitals"
        if arm >= 2
            return 2.0
        ElseIf arm == 1
            return 1.0
        EndIf
        return 0.5
    EndIf
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
    ; Male genitals mirror the female external-genital ladder, one notch
    ; lower (the schema's genitals rows are 20/25 bare): 15 touch / 20 grab
    ; bare, 10 through clothes, 5 over armor.
    if key == "male_genitals"
        if arm == 0
            if isGrab
                return 20.0
            EndIf
            return 15.0
        ElseIf arm == 1
            return 10.0
        EndIf
        return 5.0
    EndIf
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
    if key == "male_genitals"
        return False    ; Speak when felt; the armored case goes PERSISTENT
    EndIf
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
Bool Function V3IsInterrupting(String key, Int arm, Bool isGrab = False, String src = "") Global
    ; ★ THE GEAR RULE (user, 2026-08-26): "only a finger can do a interupt at
    ; the lips, no other gears.  if an apple or other gears is put there, the
    ; eating or equipping event will fire.  this include all the 'interupt'
    ; location too."
    ;
    ; The contrast the user drew is FINGER vs GEARS, so what is blocked here is
    ; the two INANIMATE source classes - a held object and an equipped weapon.
    ; The other hand classes (FINGER, PALM, FIST, HAND, GRAB) and GENITAL are a
    ; person making contact and keep every tier they have today.
    ;
    ; ⚠ Reading it as literally-FINGER-only would ALSO stop a palm, a fist and a
    ; whole hand from interrupting at the bare breast and genitals rows, which is
    ; a far wider change than the one asked for.  If that IS wanted, this is the
    ; one line to change.
    ;
    ; `src` defaults to "" so the predicate keeps working for any caller that
    ; does not know the source class.
    if src == "OBJECT" || src == "WEAPON"
        return False
    EndIf
    ; ★ MALE RULE (user, 2026-08-23): touching a male's genitals is NEVER an
    ; interrupt, whatever the dress state — reported, not imposed.  Same for
    ; his chest, which arrives as the plain "chest" key via V3MapKey.
    if key == "male_genitals"
        return False
    EndIf
    if V3IsLadderKey(key)
        return True
    EndIf
    if key == "neck" || key == "ear" || key == "shoulder" || key == "waist" || key == "hips"
        return False
    EndIf
    return IsInterrupting(key, isGrab, arm)
EndFunction

; ================================================================
; V3IsPrivate — True makes the narration PRIVATE (audience: the player only).
; ★ CORRECTED 2026-09-02: this said "through the PRIVATE YAML".  There are no
; YAMLs — V3 ships zero.  The audience is DirectNarration's own targetActor:
;   private = DirectNarration(narr, npc, playerRef)  → she answers the player
;   public  = DirectNarration(narr, npc, None)       → she addresses the room  Intimate/ladder keys (incl. genitals)
; always; breasts + butt only bare/clothes.
; ================================================================
Bool Function V3IsPrivate(String key, Int arm) Global
    if V3IsLadderKey(key) || key == "genitals" || key == "male_genitals"
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
    ; Mirrors V3MapKey's back split — keep the two in step, or the key and
    ; the narration will disagree about the same touch (the bug that had
    ; "key=Genitals" narrating as "hip", report 21 §3.2).
    if sub == "Rib cage / back" && StringUtil.Find(part, "BACK") >= 0
        return "'s upper back"
    EndIf
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
        ; ★ 2026-08-23: PPB's neck is now TWO capsules — child 1 "front neck"
        ; (the throat, ~2.5u proud so grabs land on it) and child 0
        ; "neck / throat" (the main/nape).  A grab from behind is a NECK
        ; hold, not a throat hold — say so.
        if part == "front neck"
            return "'s throat"
        EndIf
        return "'s neck"
    EndIf
    if sub == "Belly / midriff"
        if StringUtil.Find(part, "BACK") >= 0
            return "'s lower back"
        EndIf
        return "'s belly"
    EndIf
    if sub == "Waist band"
        if StringUtil.Find(part, "lower back") >= 0
            return "'s lower back"
        EndIf
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
    ; ⛔ FIXED 2026-09-13 (user: "fix that, that's not good"): PPB labels a MALE's COM C21/C22 "anal cover R/L"
    ; with the same sub-region as a female's clitoris, so this said "Torvald's clitoris (right anal cover)".
    ; V3MapKey already sends those capsules to `butt` by NAME - the wording now follows the key.
    if part == "anal cover R" || part == "anal cover L"
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
    if part == "CLITORIS" || part == "neck / throat" || part == "front neck"
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
    ; Main word is now "upper back" - a parenthetical repeating it is noise.
    if part == "BACK (upper)"
        return ""
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
    ; Main word is now "lower back" - see the note on BACK (upper).
    if part == "BACK (lower)"
        return ""
    EndIf
    ; spine0's pair DO add something: which side of the spine.
    if part == "lower back R"
        return " (right side)"
    EndIf
    if part == "lower back L"
        return " (left side)"
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
    ; The male COM C21/C22 capsules (2026-09-13 fix - see V3PartOf).
    if part == "anal cover R"
        return " (right of the cleft)"
    EndIf
    if part == "anal cover L"
        return " (left of the cleft)"
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
    ; 2026-09-15: PPB sends "<slot>.C<n>" when its name table has no name for that
    ; capsule (a custom skeleton with more capsules than PPB names) - Sofia's head has
    ; 25. An id is not a body part, so drop the parenthetical and let the line read
    ; "...against Sofia's face..."; the id still goes to the log. A real PPB capsule
    ; name is one or more words and never contains a dot, so ".C" with no space is an
    ; unambiguous id. Whole-token Find, never per-character work.
    if StringUtil.Find(part, ".C") > 0 && StringUtil.Find(part, " ") < 0
        return ""
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
    ; ★ Player genital source — SHIPPED in PPB 2.0.0. No left/right: it is not
    ; a hand, and PPB sends wand 0 for it. `name` carries WHICH part of him made
    ; contact ("shaft" / "tip"), the same way a weapon carries its own name, so
    ; the sentence can say it. Statement-of-fact wording only.
    ; PPB gates these on its own exposure test, so they arrive only when he is
    ; actually exposed — VRTE adds no gate.
    if src == "GENITAL"
        if name == "tip"
            return "the tip of their own cock"
        EndIf
        if name == "shaft"
            return "the shaft of their own cock"
        EndIf
        return "their own cock"
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
    ; ★ HEAD (PPB >= 20102). The player leaned in until the head box stopped him.
    ; PPB labels which END of the box won the contact and hands it over in `name`:
    ; "face" = the front, "head" = the back of the skull. That is the kiss-vs-headbutt
    ; discriminator ALREADY DECIDED by the sensor — never re-derive it here.
    ; ⚠ `wand` is MEANINGLESS on this source (it arrives as "H"), so never say left/right.
    ; Statement of fact only: WHICH part of him made contact, never what it meant.
    ; A kiss is "their face" on her `lips` capsule — the LADDER key already makes that
    ; private and interrupting, so no new tier is needed and none was added.
    ; ★ PPB build 20103 added a THIRD label, "mouth" (the small mouth probe across the bottom front
    ; of the head box) - it used to fall through to "their head". The KISS itself is not narrated
    ; here: it is PPB_MouthLips ...|HEAD, voiced by MainScript's KissSpeak, and HEAD contacts on
    ; the kissed NPC are muted while it holds.
    ; ★ 2026-09-12: the clause composers no longer print this row for the mouth - a mouth
    ; contact anywhere on her narrates as "kissing <part>". Kept as the fallback wording.
    if src == "HEAD"
        if name == "face"
            return "their face"
        EndIf
        if name == "mouth"
            return "their mouth"
        EndIf
        return "their head"
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
; ★★ V3NarrationMulti — ONE LINE FOR EVERYTHING TOUCHING HER (2026-09-13, the user's ruling)
; ================================================================
; "if both hand, genital and head all touch at the same time ... VRTE simply see all four and publish
; that information" - as ONE combined line per NPC. Up to four clauses, one per source lane (right hand,
; left hand, the player's head, the player's genital), in the bridge's priority order:
;   1 clause   "Telord is A."
;   2 clauses  "Telord is A, and B."
;   3+ clauses "Telord is A, B, and C."
; A clause on `male_genitals` uses the male composer's wording (V3MaleGenClause). The duration is the
; DECIDING clause's own hold (durIdx), stated right AFTER that clause so it is never read as the last
; clause's (review 2026-09-13): "Telord is sliding into ... with their right fingertip, held for 8 seconds,
; and kissing Carmella's neck."
; ⚠ Every lead that carries a verb is a LONG literal (" is kissing ", ", and kissing ") - see V3Clause.
String Function V3NarrationMulti(String npcName, String playerName, String[] w, String[] src, String[] name, \
        String[] part, String[] sub, Int[] dep, Float[] dist, String[] key, Int[] arm, String[] cloth, \
        Bool[] use, Int erectLevel, Int durIdx, Float durS) Global
    Int count = 0
    Int i = 0
    while i < use.Length
        if use[i]
            count += 1
        EndIf
        i += 1
    EndWhile
    if count == 0
        return ""
    EndIf
    String s = playerName
    Int k = 0
    i = 0
    while i < use.Length
        if use[i]
            Int pos = 1                  ; 0 first, 1 middle, 2 last
            if k == 0
                pos = 0
            ElseIf k == count - 1
                pos = 2
            EndIf
            if key[i] == "male_genitals"
                s += V3MaleGenClause(pos, npcName, part[i], w[i], src[i], name[i], dist[i], erectLevel, arm[i], cloth[i])
            Else
                s += V3ClauseAt(pos, npcName, sub[i], part[i], w[i], src[i], name[i], dist[i], dep[i])
            EndIf
            if i == durIdx && durS >= 2.0
                s += ", held for " + (durS as Int) + " seconds"
            EndIf
            k += 1
        EndIf
        i += 1
    EndWhile
    return s + "."
EndFunction

; One clause with its lead for position pos (0 first " is ", 1 middle ", ", 2 last ", and ").
String Function V3ClauseAt(Int pos, String npcName, String sub, String part, String w, String src, String name, \
        Float dist, Int dep) Global
    if V3MouthSource(src, name)
        if pos == 0
            return " is kissing " + npcName + V3PartOf(sub, part) + V3PreciseOf(sub, part)
        ElseIf pos == 2
            return ", and kissing " + npcName + V3PartOf(sub, part) + V3PreciseOf(sub, part)
        EndIf
        return ", kissing " + npcName + V3PartOf(sub, part) + V3PreciseOf(sub, part)
    EndIf
    String lead = ", "
    if pos == 0
        lead = " is "
    ElseIf pos == 2
        lead = ", and "
    EndIf
    return lead + V3IntensityVerb(dist, V3EffectiveDepth(sub, dep)) + " " + npcName + V3PartOf(sub, part) \
        + V3PreciseOf(sub, part) + " with " + V3SourceOf(w, src, name)
EndFunction

; The male composer as a clause (the wording of the old V3MaleGenNarration, removed 2026-09-13, without the player's name, the
; period or the duration).
String Function V3MaleGenClause(Int pos, String npcName, String part, String w1, String src1, String name1, \
        Float dist1, Int erectLevel, Int arm, String clothName) Global
    String adj = ""
    if erectLevel >= 5
        adj = " erect"
    ElseIf erectLevel >= 2
        adj = " semi-hard"
    ElseIf erectLevel >= 0
        adj = " soft"
    EndIf
    String posW = ""
    if part == "shaft (tip)"
        posW = " at the tip"
    ElseIf part == "shaft (base)"
        posW = " at the base"
    ElseIf part == "shaft (lower)" || part == "shaft (upper)"
        posW = " at the middle"
    EndIf
    String cloth = clothName
    if cloth == ""
        cloth = "clothes"
    EndIf
    String lead = ", "
    if pos == 0
        lead = " is "
    ElseIf pos == 2
        lead = ", and "
    EndIf
    String head = lead + V3IntensityVerb(dist1, 0)
    String withSrc = ", with " + V3SourceOf(w1, src1, name1)
    String withBare = " with " + V3SourceOf(w1, src1, name1)
    if V3MouthSource(src1, name1)
        head = " is kissing"
        if pos == 1
            head = ", kissing"
        ElseIf pos == 2
            head = ", and kissing"
        EndIf
        withSrc = ""
        withBare = ""
    EndIf
    if arm >= 2
        return head + " the front of " + npcName + "'s " + cloth + ", over their crotch" + withSrc
    ElseIf arm == 1
        return head + " " + npcName + "'s" + adj + " penis" + posW + ", through their " + cloth + withSrc
    EndIf
    return head + " " + npcName + "'s" + adj + " penis" + posW + withBare
EndFunction

; ================================================================
; ★★ THE PUSH LINE (PPB build 20104 - the user's 2026-09-13 rulings)
; ================================================================
; "there can't be a push without a contact, we just need to look at that. be mindful that only core
; contact can do push/shove/stumble, and leg sweep is always at the leg" + "it should always be from thigh,
; pelvis, belly, chest, back or head, a NPC can't be pushed by their hand or forearm". VRTouchEvents.dll hands
; over the contact that did it (TakePushContact: her head / belly / chest / back / thigh / pelvis for
; push/shove/dropped, her legs for sweeped) and
; stops that contact from being narrated on its own - "we prevent the contact event and add it to the
; push/shove event". `how` = 8 fields W|SRC|NAME|PART|SUB|DEP|DIST|DUR, or "" when none was found.
; Fact only, no pronouns - the subject is the player's own hand, so no "their" is needed.
String Function V3PushLine(String kind, String playerName, String npcName, String how, Bool isMale = False) Global
    String[] h = V3Split8(how)
    Bool hasHow = (h[1] != "")
    String doer = playerName
    String target = npcName
    if hasHow
        doer = V3SourcePossessive(playerName, h[0], h[1], h[2])
        if isMale && h[4] == "Breast"
            ; A male's spine2 C11/C12 are CHEST capsules that keep the name "BREAST R/L" - never "(right breast)".
            target = npcName + "'s chest"
        Else
            target = npcName + V3PartOf(h[4], h[3]) + V3PreciseOf(h[4], h[3])
        EndIf
    EndIf
    if kind == "push"
        return doer + " gently pushed " + target + ", and " + npcName + " stepped away from " + playerName + "."
    ElseIf kind == "shove"
        return doer + " shoved " + target + ", and " + npcName + " stumbled away from " + playerName + "."
    ElseIf kind == "dropped"
        return doer + " shoved " + target + " hard enough that " + npcName + " tripped and fell to the ground."
    ElseIf kind == "sweeped"
        return doer + " swept " + npcName + "'s legs out, lifting both feet off the floor, and " + npcName + " fell to the ground."
    EndIf
    return ""
EndFunction

; The player's own contact source as a possessive subject: "Telord's right palm". No pronouns.
String Function V3SourcePossessive(String playerName, String wand, String src, String name) Global
    Bool left = (wand == "L")
    if src == "FINGER"
        if left
            return playerName + "'s left fingertip"
        EndIf
        return playerName + "'s right fingertip"
    ElseIf src == "PALM"
        if left
            return playerName + "'s left palm"
        EndIf
        return playerName + "'s right palm"
    ElseIf src == "FIST"
        if left
            return playerName + "'s left fist"
        EndIf
        return playerName + "'s right fist"
    ElseIf src == "GRAB"
        if left
            return playerName + "'s gripping left hand"
        EndIf
        return playerName + "'s gripping right hand"
    ElseIf src == "WEAPON"
        if name != ""
            return playerName + "'s " + name
        EndIf
        return playerName + "'s drawn weapon"
    ElseIf src == "OBJECT"
        ; ⚠ Long literals only (a sentence-start "The " is a case-twin of "the " in Papyrus's shared string cache).
        if name != ""
            return playerName + "'s hand holding the " + name
        EndIf
        return playerName + "'s hand holding an object"
    ElseIf src == "GENITAL"
        return playerName + "'s penis"
    ElseIf src == "HEAD"
        if name == "mouth"
            return playerName + "'s mouth"
        ElseIf name == "face"
            return playerName + "'s face"
        EndIf
        return playerName + "'s head"
    EndIf
    if left
        return playerName + "'s left hand"
    EndIf
    return playerName + "'s right hand"
EndFunction

; Split an 8-field clause ("W|SRC|NAME|PART|SUB|DEP|DIST|DUR") preserving empty fields. "" -> all empty.
String[] Function V3Split8(String s) Global
    String[] out = new String[8]
    Int idx = 0
    Int start = 0
    Int slen = StringUtil.GetLength(s)
    while idx < 7
        Int p = StringUtil.Find(s, "|", start)
        if p < 0
            if start < slen
                out[idx] = StringUtil.Substring(s, start)
            EndIf
            return out
        EndIf
        if p > start
            out[idx] = StringUtil.Substring(s, start, p - start)
        EndIf
        start = p + 1
        idx += 1
    EndWhile
    if start < slen
        out[7] = StringUtil.Substring(s, start)
    EndIf
    return out
EndFunction

; ★ The player's MOUTH as a contact source (PPB >= 20103): HEAD source, sourceName "mouth" - the
; small mouth probe across the bottom front of PPB's head box. PPB decides it; never re-derive it.
Bool Function V3MouthSource(String src, String name) Global
    return src == "HEAD" && name == "mouth"
EndFunction


; ================================================================
; ★ 2026-08-23 — MALE UPDATE + DELIVERY REWORK additions
; ================================================================

; The choke's arming filter (user, 2026-08-23): "the choke will now use the
; neck front for detection — the main neck worked when grabbed, but someone
; was getting choked while grabbed from behind, which makes no sense."
; PPB v2.0 ships slot 7 child 1 = "front neck" on all seven skeletons,
; sitting ~2.5u proud of the main capsule precisely so a frontal grab lands
; on it; a grab from behind lands on child 0 ("neck / throat") and now
; narrates as an ordinary neck hold instead of arming the choke.
Bool Function V3IsNeckFrontPart(String part) Global
    return part == "front neck"
EndFunction

; ★ THE FOURTH DELIVERY TIER (user, 2026-08-23): armored-state contacts the
; NPC cannot FEEL — they only know about them — become SkyrimNet PERSISTENT
; EVENTS: context the LLM sees on the NPC's next line, with reactions
; disabled, no thought budget spent (GenerateNPCThought is throttled to one
; per NPC per 60s by SkyrimNet itself), and no forced reply.
;
; The rule is mechanical, not a hand-picked row list: exactly the rows that
; were "Though" AT ARMOR STATES (arm >= 2) become persistent.  Clothes-state
; thoughts stay thoughts — a touch through cloth is felt.  Bare stays Speak.
; The intimate set keeps its own rules (ladder always speaks; armored
; interior contact is already dropped by V3PlausibilityDrop).
Bool Function V3IsPersistent(String key, Bool isGrab, Int arm) Global
    if arm < 2
        return False
    EndIf
    ; ★ BREAST at HEAVY armor only -> "just an event" (user, 2026-08-23).
    ; Needs an explicit row: breasts are never a Though (V2 IsThought sends them
    ; straight to Speak), so the mechanical "was-a-Though-at-armor" rule below
    ; would never have caught them. Light armor (2) deliberately stays Speak.
    if key == "left_breast" || key == "right_breast"
        return arm >= 3
    EndIf
    if key == "male_genitals"
        return True     ; armored male crotch: seen, not felt
    EndIf
    return V3IsThought(key, arm, isGrab)
EndFunction


; ================================================================
; ★ PLAYER-GENITAL SOURCE OVERRIDES (user, 2026-08-23)
; ================================================================
; > "we will [need] to reduce that delay, as it is hard AND any type of touch
; >  with the genitals will make any female react, wearing heavy armor or not."
;
; Measured proof of the problem, 2026-08-23 18:29:50: a genital-source contact
; landed on Carmella's HIP, inherited the hips row's 4.0s dwell, ran 3.08s and
; expired without ever narrating. Lining the contact up at all is difficult in
; VR, so the ONE thing that must not happen is a hard-won contact dying on a
; dwell timer meant for an idle hand resting on a hip.
;
; So the SOURCE overrides the body part on both axes:
;   * DWELL — a flat short dwell wherever it lands. Still non-zero: a brush in
;     passing is not a press, and zero would fire on every walk-past.
;   * ARMOR — armor mutes a HAND because padding and plate genuinely deaden it.
;     It does not mute this: someone pressing their genitals against you is not
;     something heavy armor makes unremarkable. So the armor state stops
;     lowering the tier for these contacts (the genital/mouth floor in V3Dispatch).
; The BODY PART still decides the wording and the arousal — only the pacing and
; the tier floor are overridden.
; ================================================================

; Flat dwell for a genital-source contact, whatever part it lands on.
Float Function V3GenSourceDelay() Global
    return 0.5
EndFunction


; ================================================================
; ★ INTERIOR KEYS REQUIRE ACTUAL PENETRATION (user, 2026-08-23)
; ================================================================
; > "it was on the side of the mouth, not in the mouth, so we need to make sure
; >  that 'in the mouth' is recorded as such, finger need to go thru the front
; >  hole first."
;
; Measured 2026-08-23 20:23:55: a fingertip beside the mouth reported
; Face(palate) at d=+0.86u, +0.94u, +0.63u — every reading POSITIVE, i.e.
; OUTSIDE the capsule surface — while bouncing between upper lip, cheek L and
; cheekbone L. VRTE narrated "sliding into Prisoner's mouth (the palate)".
; It was never in his mouth.
;
; PPB's INTEGRATION.md states the cause and the cure outright:
;   "Hover counts as contact. The default threshold is 1.0 unit (~1 cm), so a
;    near-miss registers briefly. If you want presses only, filter on distU < 0."
; The palate capsule sits about a centimetre behind the cheek, so a finger ON
; the cheek is legitimately within hover range of it. Hover is fine for a
; SURFACE part — brushing a lip is a real touch — but a key that CLAIMS
; interiority has to be earned by actually being inside.
;
; Scope is deliberately narrow: the two keys whose narration asserts the finger
; is inside the head. The lips (the "front hole") stay hover-permitted, which is
; exactly the user's rule — you may touch the mouth from outside, but you are
; only IN it once you are through. The intimate ladder is NOT included: PPB
; guards those with its own between-the-twins ellipse gate, and they tested
; clean at 19:51.
; ================================================================
Bool Function V3RequiresPenetration(String key) Global
    return key == "mouth" || key == "mouth_wall"
EndFunction


; ================================================================
; ★ DEVIOUS DEVICES — the device dictionary (2026-08-23)
; ================================================================
; The AddOn reports FACTS about a device that just went on:
;   "<name>|<classSuffix>|<locked>|<quest>|<siteMask>|<slotMask>"
; Every WORD the LLM sees is chosen here, so the phrasing can be retuned by
; editing a script instead of rebuilding a DLL.
;
; The user's shape:
;   "(player) just put a (device name), a (device type) that (what it does).
;    (locked?) (where on the body) (luxurious / fetish / torture)"
;
; ⚠ STATEMENT OF FACT ONLY (report 19 §1). These lines describe MECHANISM and
; SENSATION — what the thing physically does to the body wearing it. They never
; say pain, fear, shame, arousal or humiliation. The user was explicit:
; "never implying emotion, like pain or fear, always neutral to keep the
;  NPC/LLM to roleplay themself properly."
;
; Class suffixes come from DD's own keyword after "Devious", so zad_, zadNG_ and
; any content mod's prefix all land on the same row (matching the AddOn's DdMask).
; ================================================================

; --- WHAT KIND OF THING IS IT ------------------------------------------------
; True for the DD device classes that are SEATED INSIDE a body.
;
; ⚠ Butterfly is NOT one, and the temptation to add it should be resisted: the
; AddOn's own device dictionary describes it as "strapped against the intimate
; flesh", i.e. external. Narrating it as inside the body would be factually
; wrong. Prefix match on "Plug" covers Plug / PlugVaginal / PlugAnal, which is
; the same test the AddOn's own cast scanner uses.
Bool Function V3IsPlugClass(String cls) Global
    if cls == ""
        return False
    EndIf
    return StringUtil.Find(cls, "Plug") == 0
EndFunction

String Function V3DDType(String cls) Global
    ; ★ 2026-08-23: the class list below is no longer guessed. The 48 real
    ; zad_Devious* EditorIDs were read out of "Devious Devices - Integration.esm"
    ; itself, and the AddOn now sends DD's OWN answer (the suffix of the
    ; zad_DeviousDevice property) rather than the first keyword it happens to
    ; find. Everything added here previously fell through to "restraint".
    if cls == "Gag" || cls == "GagLarge" || cls == "GagPanel" || cls == "GagInflatable"
        return "gag"
    EndIf
    if cls == "GagBit"
        return "bit gag"
    EndIf
    if cls == "GagRing"
        return "ring gag"
    EndIf
    if cls == "GagTape"
        return "strip of gag tape"
    EndIf
    if cls == "Blindfold"
        return "blindfold"
    EndIf
    if cls == "Collar"
        return "collar"
    EndIf
    if cls == "ArmCuffs"
        ; ★ ARM cuffs, not WRIST cuffs (the user, 2026-08-30). Measured: all 33
        ; are named "... Arm Cuffs" and sit on biped slot 59 (the arm), while
        ; the wrist-BINDING kind is a different class, CuffsFront (slot 46),
        ; which keeps the "locked together" language below.
        return "set of arm cuffs"
    EndIf
    if cls == "LegCuffs" || cls == "CuffsLegs"
        ; ★ SPLIT FROM AnkleShackles 2026-08-30 (the user): "everything that say
        ; 'arm cuff' and 'leg cuff' are of the more decorative/fetish kind, they
        ; are cuff that goes around the mid upper and lower arms, so those can be
        ; on with shackles." Measured: LegCuffs carries NO restraint keyword -
        ; it is absent from the legs registry row, which holds AnkleShackles - so
        ; describing it as shackles that shorten the stride was wrong on the
        ; mechanism as well as the place.
        return "set of leg cuffs"
    EndIf
    if cls == "AnkleShackles"
        return "set of ankle shackles"
    EndIf
    if cls == "Yoke" || cls == "YokeBB"
        return "yoke"
    EndIf
    ; zadNG_DeviousYokeFront (Expansion.esm). Added 2026-08-26 - it was the one
    ; DD class token with no entry anywhere, and the AddOn dropped such a device
    ; from the worn-device block entirely rather than merely under-describing it.
    if cls == "YokeFront"
        return "front yoke"
    EndIf
    if cls == "HeavyBondage" || cls == "Boxbinder" || cls == "Armbinder"
        return "armbinder"
    EndIf
    if cls == "ArmbinderElbow"
        return "elbow armbinder"
    EndIf
    if cls == "StraitJacket"
        return "straitjacket"
    EndIf
    if cls == "ElbowTie"
        return "elbow tie"
    EndIf
    if cls == "BondageMittens"
        return "pair of bondage mittens"
    EndIf
    if cls == "CuffsFront"
        return "pair of wrist cuffs locked together"
    EndIf
    if cls == "CuffsArms"
        ; ⚠ ALIGNED WITH ArmCuffs 2026-08-30, on the token's own meaning
        ; ("Cuffs, ARMS") and to match the AddOn's ClassLine, which groups the
        ; two. ⚠ INFERRED, not measured: ZERO devices in this load order resolve
        ; to CuffsArms, so there is nothing to check it against - but leaving it
        ; as "wrist" while the AddOn says "arms" would be a guaranteed
        ; contradiction the moment one appeared.
        return "set of arm cuffs"
    EndIf
    if cls == "HobbleSkirt" || cls == "HobbleSkirtRelaxed"
        return "hobble skirt"
    EndIf
    if cls == "PetSuit"
        return "pet suit"
    EndIf
    if cls == "PonyGear"
        return "set of pony gear"
    EndIf
    if cls == "Clamps"
        return "pair of clamps"
    EndIf
    if cls == "Belt"
        return "chastity belt"
    EndIf
    if cls == "Bra"
        return "chastity bra"
    EndIf
    if cls == "Corset"
        return "corset"
    EndIf
    if cls == "Harness"
        return "body harness"
    EndIf
    if cls == "Suit"
        return "full body suit"
    EndIf
    if cls == "Hood"
        return "hood"
    EndIf
    if cls == "Gloves"
        return "pair of bondage gloves"
    EndIf
    if cls == "Boots"
        return "pair of bondage boots"
    EndIf
    if cls == "PlugVaginal"
        return "vaginal plug"
    EndIf
    if cls == "PlugAnal"
        return "anal plug"
    EndIf
    if cls == "Plug" || cls == "Butterfly"
        return "plug"
    EndIf
    if cls == "PiercingsNipple"
        return "set of nipple piercings"
    EndIf
    if cls == "PiercingsVaginal"
        return "intimate piercing"
    EndIf
    return "restraint"
EndFunction

; --- A REFUSED EQUIP: the body part PPB names (2026-09-13) --------------------
; PPB_GestureEquipRefused field 6 = PPB's own zone word (DeviceGesture ZoneName): where the item was aimed or held.
; Returns "<NPC>'s <part>" - name + possessive, no pronoun (the V3PartOf form) - or the bare NPC name when PPB gave
; no zone ("" for a verify refusal, "none"). An unknown future zone word is used as it comes.
String Function V3GearZoneOf(String zone, String npcName) Global
    if zone == "" || zone == "none"
        return npcName
    ElseIf zone == "vaginal"
        return npcName + "'s vagina"
    ElseIf zone == "anal"
        return npcName + "'s anus"
    ElseIf zone == "mouth"
        return npcName + "'s mouth"
    ElseIf zone == "wrist"
        return npcName + "'s wrists"
    ElseIf zone == "ankle"
        return npcName + "'s ankles"
    ElseIf zone == "neck"
        return npcName + "'s neck"
    ElseIf zone == "head"
        return npcName + "'s head"
    ElseIf zone == "eyes"
        return npcName + "'s eyes"
    ElseIf zone == "chest"
        return npcName + "'s chest"
    ElseIf zone == "nipple"
        return npcName + "'s nipples"
    ElseIf zone == "waist"
        return npcName + "'s waist"
    ElseIf zone == "hand"
        return npcName + "'s hands"
    ElseIf zone == "finger"
        return npcName + "'s finger"
    ElseIf zone == "foot"
        return npcName + "'s feet"
    ElseIf zone == "torso"
        return npcName + "'s torso"
    EndIf
    return npcName + "'s " + zone
EndFunction

; --- WHERE A PIECE WENT ON, pronoun-free (2026-09-13) -----------------------
; The equip line "<P> <gently/firmly/forcefully> put <item> <this>." - the old V3GearWhere's slot order and rows (body first, vanilla before the
; DD/ZaZ custom slots), but "<NPC>'s" instead of "their", so one sentence never carries a pronoun that could mean either
; person. A mask it cannot place gives "on <NPC>".
String Function V3GearOnNamed(Int slotMask, String npcName) Global
    if Math.LogicalAnd(slotMask, 4) == 4                   ; 32 body
        return "over the body of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 128) == 128               ; 37 feet
        return "on the feet of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 8) == 8                   ; 33 hands
        return "on the hands of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 16) == 16                 ; 34 forearms
        return "on the forearms of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 256) == 256               ; 38 calves
        return "on the lower legs of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 32) == 32                 ; 35 amulet
        return "around the neck of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 64) == 64                 ; 36 ring
        return "on the finger of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 8192) == 8192             ; 43 ears
        return "at the ears of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 4097) != 0                ; 30 head / 42 circlet
        return "on the head of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 2050) != 0                ; 31 hair / 41 long hair
        return "over the hair of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 4194304) == 4194304       ; 52 pelvis
        return "over the hips of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 16384) == 16384           ; 44 gag
        return "over the mouth of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 33554432) == 33554432     ; 55 blindfold
        return "across the eyes of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 32768) == 32768           ; 45 collar
        return "around the neck of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 65536) == 65536           ; 46 armbinder
        return "on the arms of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 536870912) == 536870912   ; 59 wrist cuffs
        return "at the wrists of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 8388608) == 8388608       ; 53 ankle cuffs
        return "at the ankles of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 524288) == 524288         ; 49 belt / underwear
        return "over the hips of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 262144) == 262144         ; 48 anal plug
        return "between the legs of " + npcName
    EndIf
    if Math.LogicalAnd(slotMask, 134217728) == 134217728   ; 57 vaginal plug
        return "between the legs of " + npcName
    EndIf
    return "somewhere on " + npcName
EndFunction

