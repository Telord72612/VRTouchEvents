; VRTouch_MainScript.psc
; VR touch & grab detection -> SkyrimNet YAML trigger system.
;
; 73-trigger system with:
;   - Armor-state detection (bare / clothes / light armor / heavy armor)
;   - Configurable delays per trigger
;   - Cross-node temporal correlation (back, breast, belly, butt, face)
;   - Per-NPC cooldown with interrupting-grab bypass
;   - Grab supersedes pending touch in same region
;   - CBPC collision + HIGGS grab/release
;   - Neck choke mechanic (CME Neck CBPC + Spine2 grab -> choke state machine)
;
Scriptname VRTouch_MainScript extends Quest

Actor playerRef
Keyword kwArmorHeavy
Keyword kwArmorLight
Keyword kwMagicRestoreHealth    ; Skyrim.esm:01CEB0 — tags Restoration heal-spell MGEFs

; ================================================================
; Properties (configurable via console: setpqv VRTouchEvents_MainQuest PropertyName Value)
; ================================================================
Bool  Property EnableDebug     = False Auto
Bool  Property EnableDebugGrab = False Auto
Float Property GlobalCooldown  = 10.0  Auto   ; ★ 2026-09-13 user: 15 -> 10 s ("15 can be really long"); Setup migrates saves
Float Property DelayMultiplier = 1.0   Auto

; Optional: set via CK to a SNDR record pointing to a choking sound WAV.
; Leave None to skip sound playback. Null-safe throughout.
Sound Property ChokingSound Auto

; ================================================================
; Arousal facial expression — the ONLY survivor of the old correlation
; marker block.  Every other marker (back/breast/belly/butt/face) existed
; to reassemble a body part out of CBPC node hits; PPB names the capsule
; outright, so the whole correlation subsystem is gone (2026-08-02).
; ================================================================
Actor  faceExprActor             ; NPC whose arousal facial expression is currently set
Float  faceExprClearAt = 0.0     ; realtime at which to auto-clear it (15s after apply)

; ================================================================
; Scene-suppression state (SexLab / OStim)
; ================================================================
Bool   sceneActive  = False  ; cached SexLab/OStim scene state (scene-suppression)
Float  sceneCheckAt = 0.0    ; realtime the scene state was last re-tested
Bool   modOff       = False  ; TRUE while the mod is fully unregistered for a scene
Actor  sceneActor            ; the in-scene actor that triggered the shutdown
Race   manakinRace           ; cached by CanWitness - a mannequin never witnesses anything (2026-09-10)
Int    sceneEndGrace = 0     ; consecutive "scene ended" polls before re-arming

; (The V2 per-NPC cooldown ring, cdActor/cdTime, was deleted with
;  FireTrigger.  V3 owns pacing through v3CdActor + the two clocks below.)

; ================================================================
; Cached armor form from last GetArmorState call
; ================================================================
Armor lastArmor

; ================================================================
; Choke mechanic state
; ================================================================
; ⚠ The choke NO LONGER has a CBPC neck marker to arm from.  Arming is
; V3Dispatch's `sub="Neck" && src="GRAB"` branch, which is PPB reporting a
; HIGGS grip on her throat as a single in-band fact.  neckActor/neckTime and
; IsGrabbingChest (the old 5-second chest-grab <-> neck-marker correlation)
; are gone with the rest of the marker system.
Keyword kwPlugVaginal               ; DD zad_DeviousPlugVaginal, None if DD absent
Keyword kwPlugAnal                  ; DD zad_DeviousPlugAnal
Keyword kwPlugAny                   ; DD zad_DeviousPlug (bare)
Bool   chokeActive          = False  ; choke state machine running
Actor  chokeActor           = None   ; NPC being choked
Float  chokeStartTime       = 0.0    ; realtime when choke began
; ★ THE SECOND LIVENESS WITNESS (report 16 §7.3).  Refreshed by V3ChokeStamp
; from any PPB src=GRAB contact on the victim — i.e. HIGGS is holding her,
; read out of the physics frame rather than through HIGGS's Papyrus API.
; It REPLACES the deleted grabActor_L/R pair, which is load-bearing: §7.3
; warns that removing those two without a substitute silently halves the
; watchdog and lets the multi-fire bug return.  Actor-level on purpose — she
; ragdolls at the 15s passout and the hand leaves the neck capsule, so a
; neck-specific test would false-end the choke exactly when the 25s kill
; needs it alive.  It can only ever EXTEND a hold, never invent one.
Float  chokeLastContact     = 0.0    ; realtime of the last PPB src=GRAB contact on the victim
Int    chokeSoundHandle     = -1     ; Sound.Play() handle, -1 = not playing
Bool   chokePassedOut       = False  ; has the NPC hit the 15s passout?
Float  chokeNextTick        = 0.0    ; realtime of next TickChoke call
Bool   chokeFiredSustained  = False  ; have we fired the 5s sustained event?
Bool   chokeFiredWitnessed  = False  ; 7s public-witness trigger fired?
Bool   chokeWarnedNoSound   = False  ; warned once that ChokingSound property is unset?
Bool   chokeIsKillRun       = False  ; choke target is already KO'd — count toward kill, not passout
Bool   chokeIsLeft          = False  ; which hand's controller grip holds the throat (liveness poll)
; ★ THE CHOKE PROMPT BLOCK (2026-09-12, the user's design) - see ChokeBlockFor / ChokeRecoveryFor.
Bool   chokeFired3          = False  ; the 3s milestone fired: the choke has LANDED and the choke block is up
; (chokeRecActor/Left/Stamp/Severity are GONE, 2026-09-12: the recovery countdown now lives in
;  VRTouchEvents.dll beside the native decorator that serves it - VRTouchEvents_Native.SetChokeRecovery.)
Float  chokeEndTime         = 0.0    ; realtime a choke last ENDED — re-arm lockout
Actor  chokeLastRelActor    = None   ; last actor a release-tier fired for — debounce
Float  chokeLastRelTime     = 0.0    ; realtime of that release — debounce

; ================================================================
; KO slot registry — quest-level state that SURVIVES cell
; transitions (unlike AMEs, which get terminated when the target's
; 3D unloads even for persistent followers).  Parallel arrays, 10
; slots.  koActor[i]==None = slot free.
; ================================================================
Actor[] koActor
Float[] koWakeHour       ; absolute game-time hour when slot i auto-wakes
Float[] koHealRate       ; saved HealRate to restore on wake
Float[] koHpAtKO         ; ★ 2026-09-12: -2.0 = STILL SETTLING (no wake test yet); otherwise the Health she settled
                         ; at, kept for the receipts only. The wake is ABSOLUTE now: Health >= 50% (down at 25%)
Float[] koAtReal         ; ★ 2026-09-12 realtime of the knockout - the settle clock and the receipts only. WIPED every load
Float   koNextTick = 0.0 ; ★ 2026-09-12 realtime the next TickKO may run (a real 5s cadence). WIPED every load
Int[]   koPotionMask     ; ★ 2026-09-12 which Smart NPC Potions abilities this slot's NPC lost at KO (bit0 base,
                         ;   bit1 Mage, bit2 Assassin) - given back on wake. PERSISTS with the slot, unlike the stamps
Spell   spNpcPotion         ; Smart_NPC_Potions.esp 0xD62 NPCpotions_Spell         (None when the mod is absent)
Spell   spNpcPotionMage     ; Smart_NPC_Potions.esp 0x80A NPCpotions_SpellMage
Spell   spNpcPotionAssassin ; Smart_NPC_Potions.esp 0x80B NPCpotions_SpellAssassin

; ★★ THE MARKER FACTION (2026-09-12, third design) - VRTouchEvents.esp 0x804 VRTE_ChokeStateFaction.
; The prompt blocks read it with SkyrimNet's BUILT-IN get_faction_rank, which reads the actor at render
; time: rank 1 = being choked (0796) · 2 = recovery moderate · 3 = recovery severe (0797) · 4 = just woke
; (0798). Not a member = no block. See VRTEMark.
Faction vrteStateFaction
; ★★ THE KISS (PPB build 20103, VR-verified by PPB 2026-09-12). ONE mod event is the kiss:
; PPB_MouthLips, strArg "R|LIPS|HEAD" (field 3 HEAD = the player's MOUTH on her upper lip), numArg 1
; started / 0 ended, sender = her. One ON + one OFF per kiss (PPB hysteresis 2.2 / 3.2 u), no dwell.
; PPB tracks ONE NPC at a time, so one slot is enough. Realtime stamps - WIPED every load.
Actor kissActor     = None   ; who is being kissed right now
Float kissStartAt   = 0.0    ; realtime the kiss started
Bool  kissSaid      = False  ; the kiss narration has gone out for this kiss
Actor kissLastActor = None   ; who the last kiss was on
Float kissMuteUntil = 0.0    ; realtime: HEAD-source touch narration on kissLastActor stays muted until then
; ★ THE KISS TRAIL (2026-09-13): the NPC whose mouth clause the kiss mute last dropped, and until when that
; still counts. Her next mouth line passes the clocks KissSpeak stamped, once. Realtime - WIPED every load.
Actor kissTrailActor = None
Float kissTrailUntil = 0.0
; ★ THE KISS RING (fix list 41 V5, 2026-09-13): the NPC whose kiss was last SPOKEN, and until when a new kiss on her
; stays quiet (5 s after that kiss chain's last END). PPB's lips gate has 1 u of hysteresis, so a head bobbing at the
; exit gate re-arms the kiss every ~1 s, and each one was a GLOBAL interrupt. The first kiss always speaks; a quiet one
; that ends extends the chain. Realtime - WIPED every load.
Actor kissRingActor = None
Float kissRingUntil = 0.0
; ★★ THE PUSH REACTIONS (PPB build 20104). PPB_PushReaction, strArg "<kind>|<NPC name>", sender = her.
; The user's 2026-09-13 rulings: a "push" is HELD 3 s in case it turns into a shove or a fall (one event per
; interaction), and after a push or shove line goes out on her the next one waits 5 s. dropped / sweeped go
; out at once, always. Realtime - WIPED every load.
Actor[]  pushCdActor    ; last push/shove LINE sent on her (the shared 5 s)
Float[]  pushCdAt
Actor[]  pushHoldActor  ; a push waiting out its 3 s
Float[]  pushHoldAt
String[] pushHoldHow    ; the contact that made it (TakePushContact), "" if none
Int[]    pushHoldState  ; 0 held · 1 being sent · 2 replaced while being sent (that send aborts)
String[] pushHoldKind   ; ★ V9 (fix list 41): "push" (held 3 s) or "shove" (held 0.5 s) - see PushHoldSecs

; Who currently holds a rank, so a load can take every one back off (faction membership persists in the
; save; a choke and its after-states do not). vmUntil is a REALTIME deadline - WIPED every load.
Actor[] vmActor
Int[]   vmRank
Float[] vmUntil
Float   vmTraceAt = 0.0   ; ★ realtime of the next "MARK tick" receipt (<= one per 30 s) - WIPED every load
Bool    koTicking = False ; true if OnUpdate is re-arming for KO tick

; ================================================================
; Arousal feature (OPTIONAL) — needs OSL Aroused (or SLA) + Mfg Fix.
; Self-disables (arousalEnabled=False) if no arousal backend is installed, so
; the base mod never depends on it.  One LLM arousal query in flight at a time
; (arousalPendingActor); a per-NPC cooldown stops a sustained grope from
; spamming the LLM.  The LLM returns {arousal_delta (±), expression}; we apply
; the delta via OSLArousedNative and map the expression to an MFG face.
; ================================================================
Bool    arousalEnabled      = False
Actor   arousalPendingActor = None
Float   arousalPendingTime  = 0.0
Actor[] arousalCdActor
Float[] arousalCdTime
Float   ArousalCooldown     = 12.0

; ================================================================
; V3 (PPB coalescer) dispatcher state.
; The C++ side polls PPB's RAW contact snapshot, coalesces per-actor
; sessions and emits VRTE_Contact / VRTE_ContactUpdate /
; VRTE_ContactEnd (strArg = 16 pipe-separated fields).  This block is
; the Papyrus policy side: a per-NPC cooldown ring + a delay-wait
; pending ring + the cutover switch.
; ================================================================
; DEPRECATED — DO NOT READ.  V3Live was the parallel-run switch, but an
; Auto Property's value lives IN THE SAVE: changing its declared default
; does nothing on an existing game, so it could never be used to go live.
; It stays DECLARED (removing a property that exists in live saves is
; risky) but nothing reads it any more.  V3LogOnly below replaces it.
Bool Property V3Live = False Auto

; ================================================================
; ★ THE CUTOVER SWITCH ★
; A NEWLY declared property has no stored value in an existing save, so
; it DOES take its declared default — which is why the cutover keys on
; this one and not on V3Live.
;   V3LogOnly = False (default) = V3 IS LIVE.  The PPB coalescer owns
;       every touch reaction; V2's CBPC touch dispatch and V2's weapon
;       dwell are suppressed (their cheap bookkeeping still runs), and
;       the choke ARMS from PPB's Neck/GRAB contact.
;   V3LogOnly = True = the old parallel-run behaviour.  V3 only writes
;       "[V3] WOULD FIRE ..." to the log and never arms a choke; V2
;       drives every reaction exactly as it did before the cutover.
; ONE flag flips the whole cutover, both directions, at runtime:
;   setpqv VRTouchEvents_MainQuest V3LogOnly True     ; back to shadow mode
;   setpqv VRTouchEvents_MainQuest V3LogOnly False    ; live again
; ================================================================
Bool Property V3LogOnly = False Auto

; ================================================================
; ★ B3 REVERT SWITCH ★
; The 25s continuous-hold kill (PART B3) is a CHOKE change, not part of
; the PPB cutover — so V3LogOnly cannot revert it.  This property can:
;   ChokeKillAt25 = True  (default) — 15s passout, choke KEEPS running
;       while the grip holds, 25s total = Kill.
;   ChokeKillAt25 = False — the pre-B3 behaviour: the 15s passout ENDS
;       the choke (silently, KO slot owns the victim), no 25s kill.
;       The secondary re-grab kill-run (10s on an already-KO'd NPC) is
;       unaffected either way.
;   setpqv VRTouchEvents_MainQuest ChokeKillAt25 False
; ================================================================
Bool Property ChokeKillAt25 = True Auto

; ================================================================
; ★ TWO-TIER PER-NPC COOLDOWN (user spec, 2026-08-08)
; ================================================================
; One actor ring, TWO independent clocks, because "interrupting" has to
; mean two different things at once:
;
;   v3CdTime         the NORMAL gate.  An intimate/interrupt contact
;                    IGNORES it — that is the whole point of the tier: a
;                    hand on a bare breast must land even if she reacted to
;                    something ordinary two seconds ago.
;   v3CdIntimateTime the INTIMATE gate.  An interrupt contact respects its
;                    OWN clock.  Without this, hammering one breast queues
;                    a request per second, the LLM never gets to finish an
;                    answer, and the net result is NO reaction at all —
;                    the exact spam failure the tier was meant to avoid.
;
; So: interrupts break the normal gate, never their own.
; A firing interrupt stamps BOTH clocks (she just reacted, so an ordinary
; touch should not pile on top); an ordinary fire stamps only the normal
; clock, leaving intimate contact free to cut in immediately.
Actor[] v3CdActor                    ; V3 per-NPC cooldown ring (16 slots)
Float[] v3CdTime                     ; last fire of ANY kind
Float[] v3CdIntimateTime             ; last fire of an INTERRUPT-tier contact
Actor[] v3PendActor                  ; delay-wait ring: contact seen, dwell not yet met
; ★ THE SUSTAIN RING (2026-09-12, the user's design). A contact that fired QUIETLY -
; persistent or thought - is remembered here; if the same hold is still on the same part at 2x its dwell (cap 6s) it
; upgrades ONCE to a plain DirectNarration. Kept apart from the pending ring on purpose:
; pending = "dwell not met yet", sustain = "already fired quietly and still being held".
Actor[]  v3SusActor
String[] v3SusKey
Float[]  v3SusAt                     ; the held CLAUSE's own duration at which the upgrade fires
String[] v3SusW                      ; ★ 2026-09-13: which source lane held it (R / L / H / G)
; ★★ THE VOICED-LANES RING (2026-09-13). Bits of the source lanes (R 1 · L 2 · H 4 · G 8) that already went
; out in this NPC's current bridge session. A combined line names every clause, but only a lane that has NOT
; been voiced decides its dwell, its tier and its cooldown - a lane that joins late is judged on its own, and a
; hand that was already narrated is never re-sent just because another source arrived (review 2026-09-13).
; ★ THE ONE-LINE WAIT (2026-09-13): the NPC whose ready line waits one update so a contact about to ripen joins it,
; the payload it would have sent, and when. WaitTick re-sends it past 1.2 s; her session End re-sends it too.
Actor    waitActor  = None
String[] waitF
Float    waitArgDur = 0.0
Float    waitAt     = 0.0
Actor[] v3VoicedActor
Int[]   v3VoicedMask
Float[] v3VoicedAt      ; realtime of the last write per slot (the oldest is reused when full)

; ================================================================
; DEPRECATED — the per-actor coverage ring.
; ================================================================
; V3Covers / V3RecordSeen / v3SeenActor / V3CoverageWindow existed only to
; decide, per actor, whether the PPB path or the CBPC path should narrate
; her.  With CBPC removed outright (2026-08-02, user directive) there is no
; second path left to arbitrate, so the whole ring is gone.
;
; The consequence is deliberate and accepted: PPB drives FEMALES of mapped
; races only (PpbApi.cpp SkeletonOf: `if (!base->IsFemale()) return nullptr;`
; then `if (!has("\\ppb\\")) return nullptr;`), so males, children, creatures
; and unmapped-race females now produce NO touch reactions at all.  They come
; back as PPB's own coverage grows — that is the trade the user chose, and it
; is why nothing here tries to be clever about detecting them.
;
; V3CoverageWindow stays DECLARED but unread, for the same reason V3Live
; does: an Auto Property's value lives in the save, and dropping the
; declaration entirely on an existing game is a needless risk for zero gain.
Float Property V3CoverageWindow = 120.0 Auto

; ================================================================
; ★ SESSION REPORT COUNTERS — the user-facing diagnostic.
; ================================================================
; Every outcome V3Dispatch can reach gets a counter, and V3ReportMaybe
; prints the whole set to the user log at most once a minute (and once more
; at the end of a burst).  The point is that "the mod felt quiet" becomes a
; readable line instead of a code read: a run with contacts=40 spoken=0
; cooldown=38 is a pacing problem, contacts=40 unmapped=40 is a PPB naming
; change, and contacts=0 is the bridge or PPB itself.
Int   v3nContacts     = 0            ; VRTE_Contact events received
Int   v3nSpoken       = 0            ; dispatched to SkyrimNet as a spoken event
Int   v3nThought      = 0            ; dispatched as an unvoiced thought
Int   v3nPending      = 0            ; parked waiting on a dwell delay
Int   v3nUnmapped     = 0            ; PPB sub-region we have no key for
Int   v3nPlausibility = 0            ; interior contact dropped through armor
Int   v3nCooldown     = 0            ; blocked by the per-NPC cooldown
Int   v3nSceneGate    = 0            ; blocked by a SexLab / OStim scene
Int   v3nChokeGag     = 0            ; blocked because the actor is being choked
Int   v3nGrabGate     = 0            ; blocked by the optional grab-suppression patch
Int   v3nCombatHit    = 0            ; weapon contact that was a real combat hit
Int   v3nChokeArm     = 0            ; chokes armed from PPB Neck+GRAB
Int   v3nPersistent   = 0            ; dispatched as a persistent event (4th tier)
Int   v3nSustain      = 0            ; persistent holds upgraded to a DirectNarration (the sustain ring)
Int   v3nGenSource    = 0            ; contacts sourced from the player's genitals (PPB gates them)
Int   v3nMouthSource  = 0            ; contacts sourced from the player's mouth (HEAD:mouth - narrated as a kiss)
Int   v3nHoverDrop    = 0            ; interior key claimed while HOVERING outside the capsule
Int   v3nUndressArm   = 0            ; AddOn said an undress armed
Int   v3nUndressGate  = 0            ; grab narration suppressed because an undress is running
Int   v3nUndressFire  = 0            ; undress narrated (the piece actually came off)
Int   v3nMasturbation = 0            ; PPB_PlayerMasturbation events received (VRTE's own since 2026-09-13)
Float mastLastAt      = 0.0          ; realtime of the last masturbation line (30 s cooldown) - WIPED every load
Int   v3nGearEquip    = 0            ; ordinary gear equipped on an NPC by hand
Int   v3nGearOff      = 0            ; ordinary gear pulled off by hand and narrated (2026-09-13)
Int   v3nGearNaked    = 0            ; ...of which the body piece left her naked
Int   v3nGearOffCd    = 0            ; a removal line dropped: another removal line on her under the cooldown
Int   v3nGearStayed   = 0            ; PPB announced a removal but the piece was still worn - nothing narrated
Int   v3nGearHeld     = 0            ; a held piece of armour touching her - dropped, never narrated as a touch
Int   v3nGearRefused  = 0            ; PPB_GestureEquipRefused received (a hand equip that did not happen)
Int   v3nDeviceEffect = 0            ; a worn device fired (vibration / shock)
Int   v3nDevice       = 0            ; DD/ZaZ devices equipped and narrated
Int   v3nPlugGate     = 0            ; interior contact dropped: that orifice is plugged
Int   v3nPlugOut      = 0            ; a plug was drawn out and narrated
Int   v3nAftermath    = 0            ; short-lived after-effect states registered
Int   v3nPlugIn       = 0            ; a plug was installed and narrated
Int   v3nMenuOn       = 0            ; DD device equipped off-hand (menu, key, script)
Int   v3nMenuOff      = 0            ; DD device removed off-hand
Float v3ReportAt      = 0.0          ; realtime the next report may print
; Ring of PPB sub-region names already reported as unmapped, so a name PPB
; renames or adds is shouted ONCE rather than every 0.25s.
String[] v3UnmappedSeen

; ================================================================
; Lifecycle
; ================================================================
Event OnInit()
    Setup()
EndEvent

; ================================================================
; OnGameReload — per-load re-arm, called from VRTouch_PlayerAlias.
; ================================================================
; The engine NEVER dispatches OnPlayerLoadGame to a script that extends
; Quest, so the old "Event OnPlayerLoadGame()" that used to live here
; never fired — and HIGGS (whose grab/drop subscriptions are SKSE
; session-scoped, wiped on every game launch) went dead on every reload
; after the install session.  This is now a PUBLIC function invoked from
; VRTouch_PlayerAlias.OnPlayerLoadGame() — a ReferenceAlias filled with
; the player, which DOES receive the load-game event.  Body is unchanged
; from the old event: 2s settle, full Setup() (which re-registers HIGGS),
; then stuck-choke recovery.
Function OnGameReload()
    ; ★ 2026-09-13: a push held across a save must not be sent by a saved OnUpdate during the wait below (its
    ; realtime stamp is meaningless after a load). Setup re-allocates the rings anyway.
    if pushHoldActor.Length >= 4
        Int ph = 0
        while ph < 4
            pushHoldActor[ph] = None
            ph += 1
        EndWhile
    EndIf
    ; The same for a removal waiting to be confirmed (gear): the piece and its stamp belong to the old session.
    if gearOffActor.Length >= 4
        Int gq = 0
        while gq < 4
            gearOffActor[gq] = None
            gq += 1
        EndWhile
    EndIf
    Utility.Wait(2.0)
    Setup()

    ; Safety: if the player saved mid-choke, script variables persist
    ; but wall-clock timers are stale.  EndChokeEx removes the mute
    ; faction, unblocks activation, resets every chokeXxx flag.
    ; silentCleanup=True suppresses the "released throat" LLM narration
    ; (the choke happened in a previous session, no live context).
    if chokeActive
        if EnableDebugGrab
            Debug.Notification("VRTouch: recovering stuck choke state from save")
        EndIf
        EndChokeEx(True, True)
    EndIf
EndFunction

Function Setup()
    playerRef = Game.GetPlayer()

    ; Cache armor keywords
    kwArmorHeavy = Game.GetFormFromFile(0x0006BBD2, "Skyrim.esm") as Keyword
    ; ⛔ DD PLUG KEYWORDS - the plugged-orifice gate is UNSAFE without them.
    ; That gate reads biped slot 57 / 48, and those slots are NOT plug-exclusive
    ; in a real load order: of the first 40 armors on slot 57 here, 39 are plugs
    ; and one is `aaaDDShoulder` (Dark Dreams.esl), a shoulder piece. An NPC in
    ; that armor would have her intimate ladder silenced permanently, with
    ; nothing anywhere to say why. The slot must be confirmed by a keyword.
    ;
    ; Soft dependency: GetFormFromFile returns None when DD is absent, every use
    ; below is None-guarded, and a None keyword simply disables the gate - which
    ; is correct, because without DD there are no plugs to gate on.
    ; FormIDs verified against the live load order; identical in DD 5.2 and NG.
    kwPlugVaginal = Game.GetFormFromFile(0x01DD7C, "Devious Devices - Assets.esm") as Keyword
    kwPlugAnal    = Game.GetFormFromFile(0x01DD7D, "Devious Devices - Assets.esm") as Keyword
    kwPlugAny     = Game.GetFormFromFile(0x003331, "Devious Devices - Assets.esm") as Keyword
    ; Vanilla Restoration heal-spell keyword (tags Healing, Healing
    ; Hands, Grand Healing, Close Wounds, etc. MGEFs).
    ; ★ 2026-09-12: RECEIPTS ONLY now. It used to wake a KO'd NPC by its mere presence;
    ; the user's rule is "wake at 50% HP", which a real heal reaches on its own.
    kwMagicRestoreHealth = Game.GetFormFromFile(0x0001CEB0, "Skyrim.esm") as Keyword
    ; VRTouch_ChokingSound SNDR (VRTouchEvents.esp:000801) — points at
    ; sound/choking.wav via SoundOutputModel 000802.  Loaded here so the
    ; CK Sound property binding is optional; if the property is None we
    ; fall back to this runtime lookup.
    if ChokingSound == None
        ; 000803 is the SOUN wrapper that casts as Sound in Papyrus.
        ; SNDR 000801 is the descriptor the SOUN points to — Papyrus can't
        ; play SNDR directly (it maps to SoundDescriptor, not Sound).
        ChokingSound = Game.GetFormFromFile(0x000803, "VRTouchEvents.esp") as Sound
    EndIf
    kwArmorLight = Game.GetFormFromFile(0x0006BBD4, "Skyrim.esm") as Keyword

    ; Initialize KO slot arrays if not already sized.  Preserves
    ; existing slot contents on OnPlayerLoadGame so in-flight KOs
    ; survive save/load.
    if koActor.Length < 10
        koActor    = new Actor[10]
        koWakeHour = new Float[10]
        koHealRate = new Float[10]
        Int ki = 0
        while ki < 10
            koHealRate[ki] = -1.0
            ki += 1
        EndWhile
        koTicking = False
    EndIf
    ; koHpAtKO is a newer array — allocate independently so an existing save
    ; (koActor already sized, koHpAtKO None) gets it.  (Since 2026-09-12 the wake
    ; test is absolute - Health >= 50% - so this value is only the settle marker
    ; and a receipt; -1 on an old slot changes nothing.)
    if koHpAtKO.Length < 10
        koHpAtKO = new Float[10]
        Int kh = 0
        while kh < 10
            koHpAtKO[kh] = -1.0
            kh += 1
        EndWhile
    EndIf
    ; ★ 2026-09-12 THE SETTLE CLOCK, and the KO cadence. Both are REALTIME, and
    ; Utility.GetCurrentRealTime() restarts at zero on every game launch - a stamp carried in
    ; from a save made later in a longer session reads as a moment in the FUTURE. So both are
    ; wiped on every load, never merely sized. A slot restored from a save is long settled:
    ; koAtReal 0.0 makes the next TickKO take its baseline at once.
    koAtReal   = new Float[10]
    koNextTick = 0.0
    ; Which Smart NPC Potions abilities each KO slot's NPC lost: persists WITH the slot (a KO survives
    ; a save), so it is sized, never wiped.
    if koPotionMask.Length < 10
        koPotionMask = new Int[10]
    EndIf
    ; ★ 2026-09-12 the user's ruling: a knocked-out NPC must not wake herself on her OWN potion. Smart
    ; NPC Potions gives NPCs an ability and the AI drinks when hurt - measured in VR, both Carmella and
    ; Sofia "cast an unknown spell" ~1 s after StartKOSlot dropped them to 25%, then climbed ~4.8 HP/s
    ; (CACO potions heal over time) to the 50% wake. Soft dependency: all three None without the mod.
    spNpcPotion         = Game.GetFormFromFile(0x000D62, "Smart_NPC_Potions.esp") as Spell
    spNpcPotionMage     = Game.GetFormFromFile(0x00080A, "Smart_NPC_Potions.esp") as Spell
    spNpcPotionAssassin = Game.GetFormFromFile(0x00080B, "Smart_NPC_Potions.esp") as Spell

    ; ★★ THE MARKER FACTION. Every rank still on an actor from before this load comes OFF: a choke never
    ; survives a load, so neither do its prompt states. (The ring is the list of who holds one; its
    ; realtime deadlines are meaningless after a relaunch, so the ring is wiped once they are removed.)
    vrteStateFaction = Game.GetFormFromFile(0x000804, "VRTouchEvents.esp") as Faction
    if vmActor.Length == 8 && vrteStateFaction
        Int vmi = 0
        while vmi < 8
            if vmActor[vmi] != None
                vmActor[vmi].RemoveFromFaction(vrteStateFaction)
                Debug.Trace("[V3] MARK cleared on load: " + vmActor[vmi].GetDisplayName())
            EndIf
            vmi += 1
        EndWhile
    EndIf
    vmActor = new Actor[8]
    vmRank  = new Int[8]
    vmUntil = new Float[8]
    vmTraceAt = 0.0
    ; ★ V19: a KO slot DOES survive a load, so its rank 5 is put back (the loop above may have taken it off with a
    ; choke state, and a save from before V19 never had it).
    if vrteStateFaction && koActor.Length >= 10
        Int kr = 0
        while kr < 10
            if koActor[kr] != None && !koActor[kr].IsDead()
                KOMarkOn(koActor[kr])
            EndIf
            kr += 1
        EndWhile
    EndIf
    Debug.Trace("[V3] marker faction " + vrteStateFaction + " | Smart NPC Potions abilities: " + spNpcPotion + " " + spNpcPotionMage + " " + spNpcPotionAssassin)
    if !vrteStateFaction
        Debug.Trace("[V3] !! VRTE_ChokeStateFaction NOT FOUND in VRTouchEvents.esp - the choke / recovery / wake prompt blocks cannot show")
    EndIf
    RegisterForModEvent("VRTE_RepliesDone", "OnVRTERepliesDone")

    ; ★★ THE KISS (PPB build 20103). A kiss never survives a load (PPB sends no mouth event across
    ; one), and every kiss stamp is realtime - all wiped. Registered here, not in SetTouchSinks: PPB
    ; itself never raises a kiss inside an OStim/SexLab scene, and OnPPBMouthLips checks modOff anyway.
    kissActor     = None
    kissStartAt   = 0.0
    kissSaid      = False
    kissLastActor = None
    kissMuteUntil = 0.0
    RegisterForModEvent("PPB_MouthLips", "OnPPBMouthLips")
    ; ★★ THE PUSH REACTIONS (PPB build 20104). Registered here, not in SetTouchSinks: PPB's push system
    ; never runs on scene bodies, and OnPPBPushReaction checks modOff / the scene gate anyway.
    pushCdActor   = new Actor[4]
    pushCdAt      = new Float[4]
    pushHoldActor = new Actor[4]
    pushHoldAt    = new Float[4]
    pushHoldHow   = new String[4]
    pushHoldState = new Int[4]
    pushHoldKind  = new String[4]
    kissTrailActor = None
    kissTrailUntil = 0.0
    kissRingActor  = None
    kissRingUntil  = 0.0
    mastLastAt     = 0.0
    waitActor      = None
    waitAt         = 0.0
    ; ★ THE TOUCH COOLDOWN 15 -> 10 s (user, 2026-09-13: "let's bring it down to 10 second instead. 15 can be
    ; really long"). GlobalCooldown is an Auto Property, so an existing save keeps the OLD 15.0 whatever the
    ; script default says - migrate that exact value once. A value someone set by hand (setpqv) is left alone.
    if GlobalCooldown == 15.0
        GlobalCooldown = 10.0
        Debug.Trace("[V3] touch cooldown migrated 15 -> 10 s (user ruling 2026-09-13)")
    EndIf
    RegisterForModEvent("PPB_PushReaction", "OnPPBPushReaction")
    ; ★★ MASTURBATION (2026-09-13, the user: "it's a VRTE by product ... the AddOn will be DD specific action and
    ; VR integration"). PPB's own event, consumed directly - the DD SN side no longer relays or narrates it.
    RegisterForModEvent("PPB_PlayerMasturbation", "OnPPBPlayerMasturbation")
    ; If saved with any KO slots active, re-arm the tick loop.
    Int kj = 0
    Bool hasKO = False
    while kj < 10
        if koActor[kj] != None
            hasKO = True
        EndIf
        kj += 1
    EndWhile
    if hasKO && !koTicking
        koTicking = True
        RegisterForSingleUpdate(5.0)
    EndIf

    lastArmor = None

    ; Arousal feature: active only if (a) an arousal backend (OSL Aroused / SLA)
    ; is present, AND (b) the optional Arousal module is installed.  The Base mod
    ; ships a VRTouch_ArousalGate STUB whose IsEnabled() returns False, so arousal
    ; is OFF by default (it costs LLM tokens per touch).  The FOMOD "Arousal"
    ; option installs a patch whose IsEnabled() returns True.  Same stub-override
    ; pattern as the SexLab/OStim/GrabGate gates.
    ; ★ 2026-09-11 DIAGNOSTIC — arousal has fired ZERO times across 6 measured sessions
    ; (5x SkyrimNet 0.23.1 + Beta 25 RC7: no SendCustomPromptToLLM for vrtouch_arousal).
    ; The three inputs are split out and traced UNCONDITIONALLY (one line per load) so the
    ; next VR session says which one is false instead of us guessing. Behaviour unchanged.
    Int  arOsl  = Game.GetModByName("OSLAroused.esp")
    Int  arSla  = Game.GetModByName("SexLabAroused.esm")
    Bool arGate = VRTouch_ArousalGate.IsEnabled()
    arousalEnabled = ((arOsl != 255) || (arSla != 255)) && arGate
    Debug.Trace("[V3] arousal init: OSLAroused.esp=" + arOsl + " SexLabAroused.esm=" + arSla + " gate=" + arGate + " -> arousalEnabled=" + arousalEnabled)
    ; ⛔⛔ THE AROUSAL BUG (found 2026-09-12, after zero queries across every measured session).
    ; This ring used to be sized once and then PRESERVED across loads. Its stamps are
    ; Utility.GetCurrentRealTime(), a stopwatch that restarts at zero on EVERY GAME LAUNCH. A
    ; stamp saved late in a long earlier session therefore loads as a moment in the future:
    ; (now - stamp) is negative, negative is always < 12s, and that NPC sat on "12s per-actor
    ; cooldown" until this launch's stopwatch overtook the old one - hours. Measured: 7 cooldown
    ; skips in 13 minutes with not one query sent that session to have started a cooldown.
    ; WIPED on every load now, and IsOnArousalCd also treats a negative age as expired.
    arousalCdActor = new Actor[16]
    arousalCdTime  = new Float[16]
    arousalPendingActor = None
    arousalPendingTime  = 0.0

    ; --- Choke cleanup on reload ---
    ; Release activation block and clear all choke state.
    ; Paralysis actor value persists through save/load intentionally —
    ; if the NPC was paralyzed when the game saved, they stay paralyzed.
    if chokeActive && chokeActor != None
        chokeActor.BlockActivation(False)
    EndIf
    ; Stop orphaned sound handle (invalid after load)
    chokeSoundHandle    = -1
    chokeActive         = False
    chokeActor          = None
    chokePassedOut      = False
    chokeNextTick       = 0.0
    chokeFiredSustained = False
    chokeFiredWitnessed = False
    chokeFired3         = False
    chokeLastContact    = 0.0
    ; ★ 2026-09-12 THE REALTIME SWEEP - the arousal bug's whole class, not just that one ring.
    ; Every stamp below is Utility.GetCurrentRealTime(), which restarts at zero each launch, so
    ; each one read "in the future" after loading a save from a longer session:
    ;   chokeEndTime     the 1s re-arm lockout -> (now - stamp) < 1.0 blocked EVERY choke
    ;   chokeLastRelTime the 3s release debounce -> that NPC's release line never fired
    ;   ddzUndressAt     the 20s stale guard -> a lost undress-arm muted her grab narration
    ;   v3SceneAt        the 20-min scene backstop -> a saved-mid-scene flag muted ALL touches;
    ;                    its own comment names "a save-load" as the case it protects, and that
    ;                    was the exact case it could not survive
    ;   faceExprClearAt  the 15s face clear -> a saved face never cleared
    chokeEndTime        = 0.0
    chokeLastRelActor   = None
    chokeLastRelTime    = 0.0
    ddzUndressActor     = None
    ddzUndressAt        = 0.0
    ddzUndressUntil     = 0.0
    gearOffActor        = new Actor[4]
    gearOffDue          = new Float[4]
    gearOffName         = new String[4]
    gearOffShow         = new String[4]
    gearOffMask         = new Int[4]
    gearOffTries        = new Int[4]
    gearCdActor         = new Actor[8]
    gearCdAt            = new Float[8]
    ; Plugs stay with the AddOn's plug events while it is loaded (OnPPBUndressEnd / OnPPBDeviceEquipped).
    ddAddOnLoaded       = (Game.GetModByName("DD SN AddOn.esp") != 255)
    ddDatabaseLoaded    = (Game.GetModByName("DD SN Database.esp") != 255)
    v3SceneFlag         = False
    v3SceneAt           = 0.0
    faceExprClearAt     = 0.0
    v3DevNarrActor      = new Actor[16]
    v3DevNarrAt         = new Float[16]
    ; Scene-shutdown state — clear it on every load.  modOff persists in the
    ; save; if the game was saved DURING a scene, this Setup re-registers all
    ; sinks below, so the mod IS on again and modOff must be False to match.
    ; (Otherwise the next scene's EnterSceneOff would no-op and the full-off
    ; optimization would be silently disabled for the rest of the session.)
    modOff              = False
    sceneActor          = None
    sceneEndGrace       = 0
    sceneActive         = False
    sceneCheckAt        = 0.0
    ; Also clear the C++-side suppress flag.  Unlike Papyrus vars it lives in the
    ; DLL, which PERSISTS across in-session save loads — so a save made mid-scene
    ; would reload with the hook still suppressed.  Re-assert OFF to match modOff.
    VRTouchEvents_Native.SetScenePaused(False)

    ; ★ CBPC IS GONE (2026-08-02).  The four CBPCPlayerCollision* sinks, the
    ; VRTouchEvents_CBPCTouch weapon sink and the four CBPC collision config
    ; files are all removed — PPB is the sole sensor.  Nothing registers here
    ; but the PPB bridge below.
    ;
    ; V3 — PPB coalescer bridge (VRTouchEvents.dll -> VRTE_* mod events).
    ; If the DLL (or PPB itself) is absent these simply never fire.
    RegisterForModEvent("VRTE_Contact",       "OnVRTEContact")
    RegisterForModEvent("VRTE_ContactUpdate", "OnVRTEContactUpdate")
    RegisterForModEvent("VRTE_ContactEnd",    "OnVRTEContactEnd")
    ; ★ THE ADDON BUS (2026-08-23). The VRTE DD-ZaZ AddOn pushes what its own
    ; DLL did in game, exactly as PPB pushes contacts; VRTE only exposes it to
    ; the LLM. VRTE never re-derives the gesture — the AddOn owns the two-hand
    ; undress state machine and is the single source of truth for it.
    ; Registered in Setup ONLY, not in SetTouchSinks: the AddOn is deliberately
    ; un-gated during scenes (its own design call), so VRTE keeps listening.
    ; ★★ THE NARRATION RE-HOME (2026-08-29, the user's ruling): the AddOn now
    ; composes and sends EVERY event its own sinks generate - plug in/out,
    ; menu on/off, device effects. (Masturbation came BACK to VRTE on 2026-09-13 - OnPPBPlayerMasturbation,
    ; straight from PPB, no AddOn relay.) VRTE keeps only the
    ; player's GESTURE equip/undress narration (it overrides the normal-gear
    ; equip line) - and a pacing-only ear on the plug events, below.
    ; ★★ ALL GEAR IS VRTE's, DEVICES INCLUDED (2026-09-13, the user's rulings, in order: "gears equip/unequip event will
    ; be handled by VRTE for normal gears" -> "VRTE will narrate [a refused equip], it's not different from normal gears" ->
    ; "for the DD and ZaZ equip, they still need to be narrated if equip without the AddOn ... do narrate them like normal
    ; gears and all 'specific' stuff will come from the AddOn if it's in the modlist").
    ; PPB's OWN gesture events are consumed directly, so every hand equip, undress and refused equip is narrated with or
    ; without DD SN AddOn.esp. The AddOn's relays of the same events come OFF (their co-save registrations too) - they
    ; would narrate twice. Its UndressEnd relay stays, read only for a DD device's real name and a refused DD unlock.
    ; (The grip grace and the undress Arm's hand take are the DLL's: it hears PPB's events itself, same frame.)
    UnregisterForModEvent("VRTE_DDZaZ_UndressArm")
    UnregisterForModEvent("VRTE_DDZaZ_GearEquipped")
    UnregisterForModEvent("VRTE_DDZaZ_DeviceEquipped")
    UnregisterForModEvent("PPB_GestureUndressGrip")
    RegisterForModEvent("PPB_GestureUndressArm",     "OnPPBUndressArm")
    RegisterForModEvent("PPB_GestureUndressEnd",     "OnPPBUndressEnd")
    RegisterForModEvent("PPB_GestureGearEquipped",   "OnPPBGearEquipped")
    RegisterForModEvent("PPB_GestureDeviceEquipped", "OnPPBDeviceEquipped")
    RegisterForModEvent("PPB_GestureEquipRefused",   "OnPPBEquipRefused")
    RegisterForModEvent("VRTE_DDZaZ_UndressEnd",     "OnDDZUndressEnd")
    RegisterForModEvent("VRTE_DDZaZ_PlugRemoved",    "OnDDZPlugRemoved")
    RegisterForModEvent("VRTE_DDZaZ_PlugInserted",   "OnDDZPlugInserted")
    ; ★ 2026-09-14: PPB's own plug edge, for the pacing stamp at the instant of the act (OnPPBGesturePlug).
    RegisterForModEvent("PPB_GesturePlug",           "OnPPBGesturePlug")

    ; ★★ THE SCENE EDGES (2026-08-24). PPB found the reliable signal and this
    ; matches it: OStim and SexLab both announce a scene as SKSE mod events, and
    ; those edges are trustworthy in a way the membership tests are not.
    ; See V3SceneOn for why the old tests were not enough on their own.
    RegisterForModEvent("ostim_start",            "OnV3SceneStart")
    RegisterForModEvent("ostim_end",              "OnV3SceneEnd")
    RegisterForModEvent("StartSexLabAnimation",   "OnV3SceneStart")
    RegisterForModEvent("EndSexLabAnimation",     "OnV3SceneEnd")
    RegisterForModEvent("AnimationStart",         "OnV3SceneStart")
    RegisterForModEvent("AnimationEnd",           "OnV3SceneEnd")

    ; V3 dispatcher rings.
    ; ★ 2026-09-12: the COOLDOWN rings are WIPED on every load, no longer "preserved across
    ; loads". They carry realtime stamps and share the arousal ring's bug exactly: a stamp from a
    ; longer earlier session loaded as a future moment and would have silenced every touch on
    ; that NPC. (Allocating both unconditionally also retires the old trap where a save made
    ; before the two-tier cooldown left v3CdIntimateTime None behind a sized v3CdActor.)
    v3CdActor        = new Actor[16]
    v3CdTime         = new Float[16]
    v3CdIntimateTime = new Float[16]
    if v3PendActor.Length < 16
        v3PendActor = new Actor[16]
    EndIf
    ; ★ THE SUSTAIN RING (2026-09-12). WIPED on every load, not just sized: the C++ bridge
    ; drops every touch session at a load boundary, so an entry from before it could only
    ; ever fire on somebody else's hold.
    v3SusActor = new Actor[16]
    v3SusKey   = new String[16]
    v3SusAt    = new Float[16]
    v3SusW     = new String[16]
    ; ★ THE VOICED-LANES RING (2026-09-13): which source lanes already went out this session. A bridge
    ; session never survives a load, so neither does this.
    v3VoicedActor = new Actor[16]
    v3VoicedMask  = new Int[16]
    v3VoicedAt    = new Float[16]
    ; The choke recovery block does not outlive a load either: a choke never survives one
    ; (OnGameReload ends it), so neither does the after-state it left behind. That state now
    ; lives in VRTouchEvents.dll, which clears it itself at kPreLoadGame / kNewGame.
    ; Unmapped-name ring: allocated once, wiped every load so a PPB update
    ; that renames a sub-region is shouted again in the new session rather
    ; than staying silent because the old session already warned.
    v3UnmappedSeen = new String[8]

    ; ★ NO HIGGS SUBSCRIPTION ANY MORE.  OnObjectGrabbed / OnObjectDropped are
    ; deleted: a grab arrives from PPB as src=GRAB, in-band and already
    ; carrying the capsule it landed on, which is strictly more than
    ; GetGrabbedNodeName ever gave.  That also removes the 2s Utility.Wait
    ; this function used to stall on during every single load.
    ;
    ; HIGGS remains a HARD DEPENDENCY and is still POLLED:
    ;   - PpbApi::OnFrame() is driven from HIGGS's PostVrikPostHiggs callback,
    ;     so no HIGGS means no PPB tick, no contacts, and NO ERROR.
    ;   - TickChoke polls HiggsVR.GetGrabbedObject on both hands for choke
    ;     liveness (witness 1 of 2; witness 2 is chokeLastContact from PPB).

    ; (No SkyrimNet event schema any more - 2026-09-13. vrtouch_contact was registered on every Setup and never raised
    ;  since the 2026-08-08 trigger cutover; RegisterV3Schema is removed with it.)

    ; ★ THE CHOKE / RECOVERY / WAKE DECORATORS ARE REGISTERED NATIVELY (2026-09-12), by
    ; VRTouchEvents.dll at kDataLoaded - NOT here. The first version called
    ; VRTouch_Decorators.Register() from this spot; measured in VR, SkyrimNet refreshed those
    ; Papyrus decorators 2-3 s AFTER each render, so the block ran a turn late. Do not restore
    ; the call: a native decorator of the same name wins, and the Papyrus one would only fail.

    ; Open the dedicated Papyrus user log -> Documents\My Games\Skyrim VR\Logs\Script\User\VRTouchEvents.0.log
    ; (NOT the Steam/base-game folder — that must stay pristine.)
    Debug.OpenUserLog("VRTouchEvents")
    VTLog("===== VRTouchEvents V3 ready — PPB is the sole touch sensor (CBPC removed) =====")
    V3ReportReset()

    if EnableDebug || EnableDebugGrab
        Debug.Notification("VRTouch V3: Ready (PPB touch + choke)")
    EndIf
EndFunction







; ================================================================
; Schedule the next OnUpdate to fire at whichever is sooner:
; the pending event deadline or the next choke tick.
; Always call this instead of RegisterForSingleUpdate directly
; so that the two timers never shadow each other.
; ================================================================
Function ScheduleNextUpdate()
    Float now     = Utility.GetCurrentRealTime()
    Float nextWake = 999999.0

    ; ★ The V2 pending-touch, per-hand grab-dwell and weapon-dwell deadlines
    ; are all gone with CBPC.  V3's dwell is not a timer at all: a contact
    ; that has not met its delay sits in v3PendActor and is re-tested by the
    ; next VRTE_ContactUpdate, which the C++ coalescer emits ~1/s for as long
    ; as the touch lives.  That is strictly better than a Papyrus timer —
    ; the re-test carries a fresh measured duration instead of guessing from
    ; a deadline, and it costs no OnUpdate wakeups when nobody is touching.
    ; Only the choke and the face-clear still need real deadlines.

    if chokeActive
        Float w = chokeNextTick - now
        if w < 0.05
            w = 0.05
        EndIf
        if w < nextWake
            nextWake = w
        EndIf
    EndIf

    ; Facial-expression auto-clear deadline
    if faceExprActor != None
        Float w = faceExprClearAt - now
        if w < 0.05
            w = 0.05
        EndIf
        if w < nextWake
            nextWake = w
        EndIf
    EndIf

    ; ★ 2026-09-12: RegisterForSingleUpdate is last-call-wins, so this function must know every
    ; deadline or it can push one out. It knew neither the KO ticker (a face-clear scheduled while an
    ; NPC was knocked out could delay her 5 s TickKO) nor the marker faction's time limits.
    if koTicking
        Float w = koNextTick - now
        if w < 0.05
            w = 0.05
        EndIf
        if w < nextWake
            nextWake = w
        EndIf
    EndIf
    Float mw = VRTEMarkTick(now)
    if mw < nextWake
        nextWake = mw
    EndIf
    Float kw2 = KissWait(now)
    if kw2 < nextWake
        nextWake = kw2
    EndIf
    ; ★ 2026-09-13: a push held 3 s in case it becomes a shove or a fall.
    Float pw2 = PushWait(now)
    if pw2 < nextWake
        nextWake = pw2
    EndIf
    ; ★ 2026-09-13: a touch line waiting one update to combine with another contact.
    Float ww2 = WaitWait(now)
    if ww2 < nextWake
        nextWake = ww2
    EndIf
    ; ★ 2026-09-13: a gear removal waiting for the piece to actually come off.
    Float gw2 = GearOffWait(now)
    if gw2 < nextWake
        nextWake = gw2
    EndIf

    ; While OFF for a scene, force a <=1s heartbeat so the scene-end poll keeps
    ; firing even when no ticker is active, and so a late arousal callback's
    ; ~15s face-clear schedule can't push the heartbeat out (last-call-wins).
    if modOff && nextWake > 1.0
        nextWake = 1.0
    EndIf

    if nextWake < 999998.0
        RegisterForSingleUpdate(nextWake)
    EndIf
EndFunction

Event OnUpdate()
    Float now     = Utility.GetCurrentRealTime()
    Float nextWake = 999999.0

    ; --- Scene shutdown heartbeat ---------------------------------------
    ; While the mod is OFF for a scene, this 1s tick is the ONLY thing running.
    ; Its sole job is to notice the scene ended and re-arm.  Stays off (and just
    ; re-polls) while still in a scene; on end, re-arms and falls through to
    ; resume normal updates.
    ; --- Scene shutdown heartbeat ---------------------------------------
    ; While OFF for a scene, only the per-collision INTAKE is suppressed (its
    ; event sinks are unregistered).  We deliberately do NOT return here: the
    ; internal state-machine tickers below (KO wake polling, an already-active
    ; choke's progression, pending cleanup, face-clear) MUST keep running, or a
    ; KO'd NPC could stay unconscious for the whole scene and a live choke would
    ; freeze then fire all its tiers at once on scene end.  ScheduleNextUpdate()
    ; clamps the next wake to <=1s while modOff, so the scene-end poll keeps
    ; firing even when no ticker is active.  A 2-poll grace avoids re-arming on a
    ; transient (e.g. sceneActor briefly unloaded) false "scene ended".
    if modOff
        if V3InScene(sceneActor)
            sceneEndGrace = 0
        Else
            sceneEndGrace += 1
            if sceneEndGrace >= 2
                ExitSceneOff()
            EndIf
        EndIf
    EndIf

    ; --- KO slot ticker ---
    ; Fires every 5s while any NPC is in KO state.  Independent of
    ; chokeActive — outlives the active choke by hours of game time.
    ; ⛔ FIXED 2026-09-12 — "every 5s" was only ever this comment. TickKO ran on EVERY
    ; OnUpdate, and during a choke OnUpdate fires every 0.5 s (the choke ticker), so the
    ; heal-detector checked a freshly knocked-out NPC HALF A SECOND after StartKOSlot and
    ; every half second after. Measured in VR: Carmella passed out at 15 s and was on her
    ; feet at once; the next grab ran as a normal choke, not the kill-run, which proves the
    ; KO slot had already been released. koNextTick makes the cadence real.
    if koTicking
        if now >= koNextTick
            TickKO()
            koNextTick = Utility.GetCurrentRealTime() + 5.0
        EndIf
        if koTicking
            Float kw = koNextTick - now
            if kw < 0.05
                kw = 0.05
            EndIf
            if kw < nextWake
                nextWake = kw
            EndIf
        EndIf
    EndIf

    ; --- Choke ticker ---
    if chokeActive
        if now >= (chokeNextTick - 0.05)
            TickChoke()
            ; After TickChoke the choke may have ended; only schedule if still active
            if chokeActive
                Float w = chokeNextTick - Utility.GetCurrentRealTime()
                if w < 0.05
                    w = 0.05
                EndIf
                if w < nextWake
                    nextWake = w
                EndIf
            EndIf
        Else
            Float w = chokeNextTick - now
            if w < nextWake
                nextWake = w
            EndIf
        EndIf
    EndIf

    ; --- Facial-expression auto-clear (15s after a touch set it) ---
    ; MFG/expression overrides are sticky — they never fade on their own — so we
    ; wipe the face 15s after it was applied (a newer touch re-arms the timer).
    if faceExprActor != None
        if now >= faceExprClearAt
            faceExprActor.ClearExpressionOverride()
            MfgConsoleFunc.ResetPhonemeModifier(faceExprActor)
            faceExprActor = None
        Else
            Float w = faceExprClearAt - now
            if w < nextWake
                nextWake = w
            EndIf
        EndIf
    EndIf

    ; ★ 2026-09-12: the marker faction's time limits (recovery 180 s backstop, wake 60 s). Checked
    ; LAST, after TickKO and TickChoke, so a marker one of them just set is counted in nextWake.
    Float markW = VRTEMarkTick(now)
    if markW < nextWake
        nextWake = markW
    EndIf
    ; ★ THE KISS: speak it once the 0.5 s dwell has passed with the kiss still up.
    KissTick(now)
    Float kissW = KissWait(now)
    if kissW < nextWake
        nextWake = kissW
    EndIf
    ; ★ THE PUSH HOLD (2026-09-13): send a push that stayed a push for 3 s.
    PushTick(now)
    Float pushW = PushWait(now)
    if pushW < nextWake
        nextWake = pushW
    EndIf
    ; ★ THE ONE-LINE WAIT's deadline (2026-09-13).
    WaitTick(now)
    Float waitW = WaitWait(now)
    if waitW < nextWake
        nextWake = waitW
    EndIf
    ; ★ THE GEAR REMOVAL CHECK (2026-09-13): narrate a pulled piece once it is really off.
    GearOffTick(now)
    Float gearW = GearOffWait(now)
    if gearW < nextWake
        nextWake = gearW
    EndIf

    ; While OFF for a scene, force a <=1s heartbeat so the scene-end poll keeps
    ; firing even when no internal ticker is active (otherwise nextWake stays
    ; 999999, nothing re-arms, and modOff sticks until reload).
    if modOff && nextWake > 1.0
        nextWake = 1.0
    EndIf

    ; Re-arm for next wake
    if nextWake < 999998.0
        RegisterForSingleUpdate(nextWake)
    EndIf
EndEvent


; ================================================================
; Throttled scene-suppression check.  During a SexLab/OStim scene CBPC fires
; continuously, so testing the gate (4 native lookups) on every collision would
; itself be a cost — cache the result and re-test at most ~2x/sec.  Used to bail
; out of the high-frequency entry points (OnCBPC, OnVRTouchEvent) and the arousal
; LLM call, so VRTouchEvents does essentially nothing during a scene (the fix for
; scene lag).  The fire points (FireTrigger/FireWeaponTrigger) keep their own
; exact per-fire gate for correctness at the moment of firing.
; ================================================================
Bool Function ScenesSuppress(Actor akActor)
    Float now = Utility.GetCurrentRealTime()
    if (now - sceneCheckAt) >= 0.5
        sceneCheckAt = now
        sceneActive = V3InScene(akActor)
    EndIf
    return sceneActive
EndFunction

; ================================================================
; SCENE SHUTDOWN — register / unregister ALL of the mod's event sinks at once.
; on=True re-arms; on=False fully UNREGISTERS, so no handler is even invoked.
; This is the "mod completely off during a scene" path: the C++/CBPC/HIGGS
; sources still emit their events, but with nothing registered they dispatch
; to nobody — far cheaper than firing a handler that then bails.  Setup() keeps
; its own first-time HIGGS register (with the load-reliability wait); this is
; the lightweight runtime toggle.
; ================================================================
Function SetTouchSinks(Bool on)
    if on
        RegisterForModEvent("VRTE_Contact",       "OnVRTEContact")
        RegisterForModEvent("VRTE_ContactUpdate", "OnVRTEContactUpdate")
        RegisterForModEvent("VRTE_ContactEnd",    "OnVRTEContactEnd")
    Else
        UnregisterForModEvent("VRTE_Contact")
        UnregisterForModEvent("VRTE_ContactUpdate")
        UnregisterForModEvent("VRTE_ContactEnd")
    EndIf
EndFunction

; Enter "mod off": unregister every sink, remember the in-scene actor, and start
; a 1s heartbeat (the only thing left running) to detect when the scene ends.
; Idempotent — safe to call from whichever entry point detects the scene first.
Function EnterSceneOff(Actor a)
    if modOff
        return
    EndIf
    modOff       = True
    sceneActor   = a
    sceneEndGrace = 0
    SetTouchSinks(False)
    ; Also silence the C++ CBPC hook (kills the residual per-touch task-post +
    ; event dispatch).  VRTouchEvents-only — cbp.dll collision/physics/haptic and
    ; any chained hook keep running.  Harmless no-op if the DLL lacks this native.
    VRTouchEvents_Native.SetScenePaused(True)
    ; ★ 2026-09-12: a scene that starts mid-choke takes the choke block down (the old Papyrus
    ; ChokeBlockFor tested !modOff on every read; the native decorator is told instead).
    if chokeActive && chokeActor != None && VRTEStateRank(chokeActor) == 1
        VRTEMark(chokeActor, 0, 0, 0.0)
    EndIf
    VTLog("SCENE OFF — mod fully unregistered for scene on " + a.GetDisplayName())
    RegisterForSingleUpdate(1.0)
EndFunction

; Leave "mod off": re-arm every event sink and resume normal operation.
Function ExitSceneOff()
    modOff       = False
    sceneActor   = None
    sceneEndGrace = 0
    SetTouchSinks(True)
    VRTouchEvents_Native.SetScenePaused(False)   ; resume the C++ hook
    ; ★ 2026-09-12: ...and a scene that ends while that choke is STILL landed puts it back up -
    ; exactly the condition the old Papyrus ChokeBlockFor evaluated on every render.
    if chokeActive && chokeActor != None && chokeFired3 && !chokePassedOut && !chokeIsKillRun
        VRTEMark(chokeActor, 1, 0, 0.0)
    EndIf
    ScheduleNextUpdate()   ; resurrect any internal timer that was pending pre-scene
    VTLog("SCENE ON — mod re-armed (scene ended)")
EndFunction




; ================================================================
; Arousal feature (optional)
; ================================================================
; Called when a touch/grab reaction fires.  For intimate body parts (baseline
; arousal > 0) it asks the LLM, via the vrtouch_arousal prompt, for a
; personality/relationship-adjusted arousal delta + a facial expression, then
; the callback applies them.  Cooldown-gated + single-in-flight so it never
; spams.  No-op entirely if the arousal backend isn't installed.
; baselineOverride >= 0 replaces the V2 GetArousal lookup (V3 feeds the
; report-14 per-key baselines through here; V2 call sites omit it).
Function MaybeArousal(Actor akActor, String bp, Bool isGrab, Int arm, String narration, Float baselineOverride = -1.0)
    if !arousalEnabled || akActor == None || akActor == playerRef
        Debug.Trace("[V3] AROUSAL SKIP: gate off (arousalEnabled=" + arousalEnabled + ")")
        return
    EndIf
    ; No arousal LLM call during a SexLab/OStim scene — it was the missing gate:
    ; FireTrigger/FireWeaponTrigger checked the scene, but MaybeArousal did not,
    ; so it fired an LLM prompt per intimate touch AND changed the NPC's face
    ; mid-scene.  (OnCBPC now bails earlier too; this also covers the grab path.)
    if ScenesSuppress(akActor)
        Debug.Trace("[V3] AROUSAL SKIP: scene gate")
        return
    EndIf
    ; No arousal LLM call while this NPC is being choked — a strangled NPC
    ; isn't getting aroused, and no other event should fire during a choke.
    if chokeActive && akActor == chokeActor
        Debug.Trace("[V3] AROUSAL SKIP: choke active")
        return
    EndIf
    ; (fix list 41 V1) no LLM query, arousal change or face on a dead or knocked-out NPC.
    if V3OutCold(akActor)
        Debug.Trace("[V3] AROUSAL SKIP: dead or unconscious")
        return
    EndIf
    Float baseline = baselineOverride
    if baseline < 0.0
        baseline = VRTouch_TriggerLib.GetArousal(bp, isGrab, arm)
    EndIf
    if baseline <= 0.0
        Debug.Trace("[V3] AROUSAL SKIP: baseline 0 for bp=" + bp)
        return
    EndIf
    Float now = Utility.GetCurrentRealTime()
    ; One LLM query in flight at a time (recover if a prior one never returned).
    if arousalPendingActor != None
        if (now - arousalPendingTime) > 20.0
            arousalPendingActor = None
        Else
            Debug.Trace("[V3] AROUSAL SKIP: a query is still in flight")
            return
        EndIf
    EndIf
    if IsOnArousalCd(akActor, now)
        Debug.Trace("[V3] AROUSAL SKIP: 12s per-actor cooldown")
        return
    EndIf
    arousalPendingActor = akActor
    arousalPendingTime  = now
    RecordArousalCd(akActor, now)

    ; ⛔⛔ 2026-09-12 — THE NPC IS PASSED AS A FORMID NUMBER, NOT A UUID STRING.
    ; Measured in VR the first time arousal actually fired: the prompt rendered with 8 missing
    ; variables and printed "NPC: {{ npc.name }}" raw - decnpc() and render_character_profile()
    ; do not resolve GetEntityUUID's quoted string, so the LLM judged the touch knowing neither
    ; who she is nor how she feels about the player. SeverActions' working custom prompts pass
    ; "npcFormId": <number> and call formid_to_uuid() in the template; this does the same.
    ; FormIDDec (DLL) gives the UNSIGNED decimal - Papyrus's GetFormID() goes negative for load
    ; slot 0x80+ (Sofia is 0xDC001827).
    String fidDec = VRTouchEvents_Native.FormIDDec(akActor)
    if fidDec == ""
        fidDec = "0"
    EndIf
    ; ⛔ 2026-09-02 — narration MUST be JSON-escaped before it is concatenated in.
    ; It carries free text from four sources that mods control: the NPC's name, a
    ; weapon name, a held object's name and a device name. One '"' or '\' in any of
    ; them produced malformed context JSON and the arousal call for that contact
    ; silently misbehaved. V3JsonEscape had existed since the V3 cutover with ZERO
    ; call sites — the escaper was written and then never wired. Its fast path is
    ; two Finds and no allocation, so this costs nothing on the overwhelming case.
    String ctx  = "{\"npcFormId\":" + fidDec + ",\"narration\":\"" + VRTouch_TriggerLib.V3JsonEscape(narration) + "\",\"baseline\":" + (baseline as Int) + "}"
    SkyrimNetApi.SendCustomPromptToLLM("vrtouch_arousal", "", ctx, Self as Quest, "VRTouch_MainScript", "OnArousalResponse")
    Debug.Trace("[V3] AROUSAL query bp=" + bp + " grab=" + isGrab + " base=" + baseline + " on " + akActor.GetDisplayName())
EndFunction

; SendCustomPromptToLLM callback — apply the LLM's arousal decision + face.
Function OnArousalResponse(String response, Int success)
    Actor a = arousalPendingActor
    arousalPendingActor = None
    if a == None
        return
    EndIf
    if success != 1
        VTLog("AROUSAL response FAILED: " + response)
        return
    EndIf
    Int    delta = ParseArousalDelta(response)
    String expr  = ParseExpression(response)
    if delta != 0
        OSLArousedNative.ModifyArousal(a, delta as Float)
    EndIf
    ApplyFace(a, expr)
    VTLog("AROUSAL applied delta=" + delta + " expr=" + expr + " on " + a.GetDisplayName())
EndFunction

; Map the LLM's expression word to an MFG face.  v1: the aroused/pleased look
; (ABT's confirmed half-lidded-eyes + parted-lips combo, scaled); other words
; reset to neutral for now (negative-emotion morphs are a planned follow-up).
; Mfg calls no-op harmlessly if Mfg Fix isn't installed.
; Map the LLM's expression word to a face and arm a 15s auto-clear.
; Matching is CASE-INSENSITIVE (the LLM often capitalises: "Aroused", "Shy").
; Emotions use the vanilla Actor.SetExpressionOverride moods (the set MFG Fix
; manages) — persistent "Mood" archetypes 8-14; "aroused" has no vanilla mood
; so it's built from MFG morphs (half-lidded eyes + parted lips).  The face is
; sticky (MFG/expression overrides never decay on their own), so we record the
; actor + a clear-time and OnUpdate wipes it after 15s.
Function ApplyFace(Actor a, String expr)
    if a == None
        return
    EndIf
    ; If a scene started while an arousal query was in flight, its callback lands
    ; here during modOff.  Don't stamp a (stale) expression on an NPC mid-scene —
    ; the scene owns their face — and skipping the reschedule below keeps the
    ; 1s scene-end heartbeat from being pushed out to ~15s.
    if modOff
        return
    EndIf
    String e = ToLower(expr)
    Bool applied = True
    if e == "aroused"
        ; No vanilla "aroused" mood — morph it: half-lidded eyes + parted lips.
        MfgConsoleFunc.SetModifier(a, 0, 60)
        MfgConsoleFunc.SetModifier(a, 1, 60)
        MfgConsoleFunc.SetModifier(a, 3, 70)
        MfgConsoleFunc.SetPhoneme(a, 3, 70)
    ElseIf e == "happy" || e == "pleased"
        a.SetExpressionOverride(10, 75)      ; Mood Happy
    ElseIf e == "shy"
        a.SetExpressionOverride(10, 35)      ; a gentle, bashful smile
    ElseIf e == "sad"
        a.SetExpressionOverride(11, 75)      ; Mood Sad
    ElseIf e == "angry" || e == "annoyed"
        a.SetExpressionOverride(8, 80)       ; Mood Anger
    ElseIf e == "afraid" || e == "fearful" || e == "fear" || e == "scared"
        a.SetExpressionOverride(9, 85)       ; Mood Fear
    ElseIf e == "surprised" || e == "surprise" || e == "shocked"
        a.SetExpressionOverride(12, 85)      ; Mood Surprise
    ElseIf e == "puzzled" || e == "confused" || e == "uncomfortable"
        a.SetExpressionOverride(13, 70)      ; Mood Puzzled
    ElseIf e == "disgusted" || e == "disgust"
        a.SetExpressionOverride(14, 85)      ; Mood Disgusted
    Else
        ; neutral / unrecognised -> clear any face we set and don't arm a timer.
        a.ClearExpressionOverride()
        MfgConsoleFunc.ResetPhonemeModifier(a)
        applied = False
    EndIf
    ; Arm (or cancel) the 15s auto-clear so a face never sticks forever.
    if applied
        faceExprActor   = a
        faceExprClearAt = Utility.GetCurrentRealTime() + 15.0
        ScheduleNextUpdate()
    ElseIf faceExprActor == a
        faceExprActor = None
    EndIf
EndFunction

; Lowercase a string (Papyrus has no native ToLower) — so the LLM returning
; "Aroused"/"Shy" still matches the lowercase checks above.
String Function ToLower(String s)
    String up = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    String lo = "abcdefghijklmnopqrstuvwxyz"
    String out = ""
    Int i = 0
    Int n = StringUtil.GetLength(s)
    while i < n
        String ch = StringUtil.Substring(s, i, 1)
        Int idx = StringUtil.Find(up, ch)
        if idx >= 0
            out += StringUtil.Substring(lo, idx, 1)
        Else
            out += ch
        EndIf
        i += 1
    EndWhile
    return out
EndFunction

; --- tiny parsers (the LLM returns "<delta>|<expression>", e.g. "-8|annoyed") ---
Int Function ParseArousalDelta(String resp)
    Int p = StringUtil.Find(resp, "|")
    if p < 0
        return StrToInt(resp)
    EndIf
    return StrToInt(StringUtil.Substring(resp, 0, p))
EndFunction

String Function ParseExpression(String resp)
    Int p = StringUtil.Find(resp, "|")
    if p < 0
        return ExtractWord(resp)
    EndIf
    return ExtractWord(StringUtil.Substring(resp, p + 1))
EndFunction

; First signed integer found in s ("  -8, ..." -> -8).
Int Function StrToInt(String s)
    Int i = 0
    Int len = StringUtil.GetLength(s)
    String num = ""
    Bool started = False
    while i < len
        String ch = StringUtil.Substring(s, i, 1)
        if ch == "-" && !started
            num = num + ch
            started = True
        ElseIf StringUtil.Find("0123456789", ch) >= 0
            num = num + ch
            started = True
        ElseIf started
            i = len
        EndIf
        i += 1
    EndWhile
    if num == "" || num == "-"
        return 0
    EndIf
    return num as Int
EndFunction

; First run of letters in s.
String Function ExtractWord(String s)
    Int i = 0
    Int len = StringUtil.GetLength(s)
    String w = ""
    Bool started = False
    while i < len
        String ch = StringUtil.Substring(s, i, 1)
        if StringUtil.Find("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", ch) >= 0
            w = w + ch
            started = True
        ElseIf started
            i = len
        EndIf
        i += 1
    EndWhile
    return w
EndFunction

Bool Function IsOnArousalCd(Actor a, Float now)
    Int i = 0
    while i < 16
        if arousalCdActor[i] == a
            ; A NEGATIVE age is a stamp from an earlier game launch (realtime restarts at 0) -
            ; expired, never "on cooldown". See the arousal bug note in Setup().
            Float age = now - arousalCdTime[i]
            return age >= 0.0 && age < ArousalCooldown
        EndIf
        i += 1
    EndWhile
    return False
EndFunction

Function RecordArousalCd(Actor a, Float now)
    Int i = 0
    Int oldest = 0
    Float oldestTime = now
    while i < 16
        if arousalCdActor[i] == a
            arousalCdTime[i] = now
            return
        EndIf
        if arousalCdActor[i] == None
            arousalCdActor[i] = a
            arousalCdTime[i] = now
            return
        EndIf
        if arousalCdTime[i] < oldestTime
            oldestTime = arousalCdTime[i]
            oldest = i
        EndIf
        i += 1
    EndWhile
    arousalCdActor[oldest] = a
    arousalCdTime[oldest]  = now
EndFunction

; ================================================================
; Dedicated VRTouchEvents logging → <SkyrimVR root>\VRTouchEvents.log
; ================================================================
; Independent of the on-screen EnableDebug/EnableDebugGrab toggles, so a
; persistent record exists for debugging without spamming the HUD.  Uses
; PapyrusUtil (MiscUtil.WriteToFile) — already present via the SkyrimNet
; dependency chain.  append=true accumulates across sessions (delete the
; file to reset); timestamp=true stamps each line with the game time.
Function VTLog(String msg)
    ; Always-on for this debug build (no property gate — a newly-added Auto
    ; property may not take its default on an existing save).  Low volume:
    ; only fires on actual touch/grab/fire/suppress events.  For a public
    ; release, gate this behind an MCM/property toggle.
    ; Dedicated Papyrus user log -> Documents\My Games\Skyrim VR\Logs\Script\User\VRTouchEvents.0.log
    ; (NOT the Steam folder).  Debug.TraceUser auto-stamps + line-breaks each entry.
    Debug.TraceUser("VRTouchEvents", msg)
EndFunction



; ================================================================
; Armor State Detection
; Returns: 0=bare, 1=clothes, 2=light armor, 3=heavy armor
; ================================================================
Int Function GetArmorState(Actor akActor, String bodyPart)
    Int mask = VRTouch_TriggerLib.GetSlotMask(bodyPart)
    Armor gear = akActor.GetWornForm(mask) as Armor

    if !gear && (bodyPart == "genitals" || bodyPart == "butt")
        gear = akActor.GetWornForm(524288) as Armor
        if !gear
            gear = akActor.GetWornForm(4194304) as Armor
        EndIf
    EndIf

    return ClassifyWornArmor(gear)
EndFunction

; ----------------------------------------------------------------
; ClassifyWornArmor — the shared tail of EVERY armor probe: cache the
; found form (so GetLastArmorName keeps reporting it, including the
; None case, exactly as before) and bucket it 0=bare / 1=clothes /
; 2=light / 3=heavy.  Extracted verbatim out of GetArmorState so the
; V3 slot chains below classify through the SAME keyword logic — one
; source of truth, no duplicated keyword tests.
; ----------------------------------------------------------------
Int Function ClassifyWornArmor(Armor gear)
    lastArmor = gear

    if !gear
        return 0
    EndIf
    if kwArmorHeavy && gear.HasKeyword(kwArmorHeavy)
        return 3
    EndIf
    if kwArmorLight && gear.HasKeyword(kwArmorLight)
        return 2
    EndIf
    return 1
EndFunction

; ----------------------------------------------------------------
; V3ArmorState — armor probe for a V3 (PPB) key.  V2's single-mask
; GetSlotMask lookup is WRONG for two whole families of V3 keys, both
; confirmed live in report 18:
;
;   D1 — FACE reads BARE through a helmet.  GetSlotMask maps the face
;        family to 16384 = slot 44, which VANILLA SKYRIM NEVER USES;
;        helmets are slot 30 (mask 1).  A fully-dressed NPC therefore
;        logged "key=face arm=0 cloth=".  Fixed with an ordered chain:
;        44 first (mod-added face gear / masks genuinely live there),
;        then 30.  First non-None wins.
;
;   D2 — INTERIOR contacts were DROPPED through robes.  V3SlotKey folds
;        the interior ladder onto "genitals", whose mask is body slot
;        32 — so a robe made arm=2 and V3PlausibilityDrop killed a real
;        PPB "vaginal opening" contact.  Interiors must probe the
;        PELVIS slots ONLY: 49 (524288) then 52 (4194304).  Nothing worn
;        there => arm=0 (accessible); only genuine underwear blocks.
;        Report 14 §4.2 C-4.
;
; The MOUTH INTERIOR (mouth / mouth_wall) is deliberately its OWN chain
; of slot 44 alone — see V3SlotChain.  Chaining it to 30 like the rest of
; the face family would let any helmet drive it to arm>=2, and
; V3PlausibilityDrop then DELETES every in-mouth and throat-wall contact
; — reintroducing D2's exact failure mode through D1's fix.
;
; Every other key falls through to the unchanged V2 path, so nothing
; outside these families changes behaviour.  All branches end in
; ClassifyWornArmor, so lastArmor / GetLastArmorName are maintained
; identically whichever chain ran.
;
; The chains themselves live in ONE place — VRTouch_TriggerLib.V3SlotChain
; — so the key lists cannot drift between the predicate and the masks.
; ----------------------------------------------------------------
Int Function V3ArmorState(Actor npc, String key)
    if npc == None
        return ClassifyWornArmor(None)
    EndIf

    Int[] chain = VRTouch_TriggerLib.V3SlotChain(key)
    if chain[0] == 0
        ; No override for this key: unchanged V2 behaviour (which already
        ; chains 32 -> 49 -> 52 for "genitals"/"butt").
        return GetArmorState(npc, VRTouch_TriggerLib.V3SlotKey(key))
    EndIf

    Armor gear = npc.GetWornForm(chain[0]) as Armor
    if !gear && chain[1] != 0
        gear = npc.GetWornForm(chain[1]) as Armor
    EndIf
    return ClassifyWornArmor(gear)
EndFunction

String Function GetLastArmorName()
    if lastArmor
        return lastArmor.GetName()
    EndIf
    return ""
EndFunction


; ================================================================
; ============================================================
; CHOKE MECHANIC
; ============================================================
;
; Timeline:
;   0s  — StartChoke: immediate interrupt (VRTouch_Neck_Choke_Short),
;          BlockActivation(true), first tick at +1s
;   2s  — play ChokingSound (if property is set)
;   5s  — fire VRTouch_Neck_Choke_Sustained; StartCombat (rel<=1) or
;          FleeFrom (rel>1)
;   15s — passout: ForceActorValue Paralysis 1, stop sound,
;          BlockActivation(false), fire VRTouch_Neck_Choke_Passout,
;          set random dispel timer (1800-5400s)
;   25s — kill if still holding Spine2
;   post-passout: HP polling (heal > 10 pts → dispel paralysis);
;          OnObjectDropped(Spine2) → EndChoke(keep paralysis)
; ================================================================

; ================================================================
; ★ THE CHOKE PROMPT BLOCK - the state side (2026-09-12)
; ================================================================
; The user's design, modelled on the DD AddOn's gag system, which works:
;   * from the moment the choke LANDS (3s), every LLM render for her carries a block
;     saying her throat is held shut and every sound she makes is choked
;     (0796_vrte_choke.prompt, reading the vrte_choke decorator)
;   * after a 3-7s release, two renders of recovery; after 7-15s, three, more severe
;     (0797_vrte_choke_recovery.prompt, reading vrte_choke_recovery)
;
; WHY THE RECOVERY IS NOT OPTIONAL. StartChoke deliberately avoids a "cannot speak" event
; because one "lingered in her context and swallowed the RELEASE reaction too, leaving her
; silent even after letting go". That is exactly the failure the gag's release block was
; built to fix: withdrawing a constraint does not delete the choked turns it produced.
;
; ★★ 2026-09-12 — THE DECORATORS ARE NATIVE NOW. ChokeBlockFor / ChokeRecoveryFor (and the
; VRTouch_Decorators.psc that registered them from Papyrus) are GONE. Measured in VR the same
; day: SkyrimNet refreshes a Papyrus decorator in an async pre-pass 2-3 s AFTER the render that
; needs it, so the block was right on only 2 of 5 replies and the recovery block never rendered.
; VRTouchEvents.dll now registers vrte_choke / vrte_choke_recovery / vrte_ko_wake through
; SkyrimNet's C++ API; the prompt engine calls them synchronously. This script PUSHES state at
; the moment it changes, always BEFORE the DirectNarration that follows:
;   block UP    3s landing (TickChoke)                 SetChokeBlock(a, playerName)
;   block DOWN  passout (TickChoke), every EndChokeEx, SetChokeBlock(a, "")
;               a scene starting (EnterSceneOff)
;   block UP    a scene ending mid-choke (ExitSceneOff)
;   recovery    3-7s / 7-15s release (EndChokeEx)      SetChokeRecovery(a, sev, 2 | 3)
;   wake        a KO slot waking (WakeKOSlot)          SetKOWake(a, 2)
; The render counting (5 s floor, the AddOn Recovery() clock) moved into the DLL unchanged.

; ----------------------------------------------------------------
; StartChoke — called when Spine2 is grabbed with recent neck contact
; ----------------------------------------------------------------
Function StartChoke(Actor akActor)
    if chokeActive
        return
    EndIf
    ; Re-arm lockout: a choke that JUST ended must not be instantly re-armed
    ; by the OnCBPC neck reverse-trigger while the same physical grab is still
    ; live (grabActor_*/chest node still set).  Without this, one hold could
    ; end + re-arm repeatedly, firing a release tier each cycle.  A real
    ; release-and-re-grab is always >> 1s apart, so this never blocks a
    ; genuine second choke.
    if chokeEndTime > 0.0 && (Utility.GetCurrentRealTime() - chokeEndTime) < 1.0
        return
    EndIf

    ; --- Re-choke detection: target already in a KO slot ---
    ; If the player grabs the throat of an already-passed-out NPC,
    ; we enter "kill run" mode: no passout (they're already down),
    ; no 5/7/10s narration events (they can't react), just count to
    ; 25s while held → Kill.  Release before 25s is silent (slot
    ; remains intact).
    Bool isKillRun = (FindKOSlot(akActor) >= 0)

    chokeActive         = True
    chokeActor          = akActor
    chokeStartTime      = Utility.GetCurrentRealTime()
    chokeLastContact    = chokeStartTime
    ; ★ tell the AddOn (2026-08-29): plug/effect narration lives there now and
    ; must downgrade to the persistent tier while this NPC is being strangled.
    SendModEvent("VRTE_ChokeState", (akActor.GetFormID() as String), 1.0)
    if chokeSoundHandle >= 0
        Sound.StopInstance(chokeSoundHandle)   ; defensive: clear any orphaned choke-sound handle
    EndIf
    chokeSoundHandle    = -1
    chokePassedOut      = False
    chokeNextTick       = chokeStartTime + 1.0
    chokeFiredSustained = False
    chokeFiredWitnessed = False
    chokeFired3         = False
    chokeWarnedNoSound  = False
    chokeIsKillRun      = isKillRun

    ; Which hand's controller grip is on the throat?  Recorded for logging and
    ; for the "free hand" branches; liveness itself polls BOTH hands, never
    ; this single latch (see TickChoke — a VR mis-latch where HIGGS resolved
    ; the throat grab to the other hand used to false-end the choke every
    ; tick and let it re-arm, which was the multi-fire bug).
    ; The old third branch fell back to grabActor_L, which no longer exists;
    ; if neither HIGGS hand reports her the arming contact's own wand is the
    ; better answer anyway, and V3Dispatch has already stamped it.
    if HiggsVR.GetGrabbedObject(True) == akActor
        chokeIsLeft = True
    ElseIf HiggsVR.GetGrabbedObject(False) == akActor
        chokeIsLeft = False
    EndIf

    if isKillRun
        ; Skip the LLM / narration setup below — the NPC is already
        ; KO'd, voice silenced, and in the mute faction.  Just arm
        ; the tick loop so we can count to 10s → kill.
        RegisterForSingleUpdate(0.5)
        return
    EndIf

    ; Block NPC activation (prevents dialogue menu while being choked)
    akActor.BlockActivation(True)

    ; ★ V8 (fix list 41, 2026-09-13): the PurgeDialogue(False) that stood here MOVED to the 3 s landing (TickChoke,
    ; `elapsed >= 3.0 && !chokeFired3`). It is GLOBAL and BLOCKING, and it ran on every arm, so a hand fumbling at the
    ; throat (grab, release, grab) cut every actor's dialogue once a second. Before 3 s a hand on the throat is still
    ; just a grab (the user's design, 2026-09-12), so nothing is cut until the choke lands.

    ; Silence vanilla Skyrim voice barks (combat shouts, greetings,
    ; hit reactions, idle lines) for the duration of the choke.
    ; SetVoiceRecoveryTime is the delay-before-next-voice-line timer;
    ; setting it to a very large number means "next line is effectively
    ; never allowed until we reset it".  Reset to 0 in EndChokeEx.
    ; SkyrimNet has no per-actor mute API, but this covers the engine side —
    ; suppresses the choked NPC's vanilla barks.  15s (was 999s): long enough to
    ; span a typical choke, short enough that it never leaves the actor in a
    ; long-lived "can't speak" state that a perception filter could treat as absent.
    akActor.SetVoiceRecoveryTime(15.0)

    ; --- SkyrimNet soft-gag (a strangled NPC can't talk) ----------------
    ; (We do NOT register a persistent "cannot speak" event — that lingered in her
    ; context and swallowed the RELEASE reaction too, leaving her silent even after
    ; letting go.)  The no-mid-choke-event change + the FireTrigger gag gate keep her
    ; quiet during the choke; the release reaction is forced via DirectNarration in EndChokeEx.
    ; ★ V8: the TriggerInterruptDialogue(false) that cut her line HERE is now the 3 s landing's own (it was
    ; already there) - the arm cuts nothing. See the note above.

    ; Cancel any V3 contact still waiting on its dwell delay for the choked
    ; actor (V3Dispatch's choke gag catches anything still in flight, but
    ; dropping it here avoids the SUPPRESSED spam at fire time).
    V3PendClear(akActor)

    ; The choke does NOT touch SkyrimNet's blacklist faction.  Muting via that
    ; faction was tried twice (RemoveFromFaction rank -1, then SetFactionRank -2)
    ; and neither cleanly un-blacklisted the NPC in SkyrimNet's C++ ActorFilter,
    ; so it's left alone.  SetVoiceRecoveryTime (above) silences vanilla barks; the
    ; choke narration makes SkyrimNet produce gasping/strangled lines on its own.

    ; NOTE: we intentionally do NOT FireTrigger here.  Firing an LLM
    ; event would generate a spoken line, but a person being strangled
    ; can't talk.  StartChoke is silent to SkyrimNet; only the Passout
    ; trigger fires (for witness/memory purposes after paralysis).
    String npcName    = akActor.GetDisplayName()
    String playerName = playerRef.GetDisplayName()

    ScheduleNextUpdate()

    if EnableDebugGrab
        Debug.Notification("VRTouch: CHOKE START [" + npcName + "]")
    EndIf
EndFunction

; ----------------------------------------------------------------
; EndChoke — stop the choke state machine
;   dispelParalysis = True  → remove paralysis (healed / random dispel)
;   dispelParalysis = False → leave paralysis (player released, NPC stays down)
;
; Release-event logic:
;   If the choke ends while the NPC is still conscious (not passed out,
;   not dead), we fire ONE LLM trigger based on how long the choke ran.
;   Narrative is past-tense — NPC describes what they just felt.
;     0.0 –  3.0s  →  Short     (brief squeeze)
;     3.0 –  7.0s  →  Sustained (hard, couldn't talk)
;     7.0 – 15.0s  →  Severe    (almost passed out, gasping)
;   Post-passout or dead → no release event (Passout trigger fired at 15s).
; ----------------------------------------------------------------
; ----------------------------------------------------------------
; IsAssaultWitnessed — visual-cue gate for SendAssaultAlarm.
;
; Scans nearby actors (excluding the victim and the player) within a
; 2000-unit radius of the victim and returns True if ANY of them has
; line-of-sight to the player AND has the player detected (respecting
; sneak, lighting, distance — vanilla perception math).
;
; Probe sampling: we call FindRandomActorFromRef in a short loop.
; That function samples the reference cache, so 12 tries in a busy
; cell almost always cover everyone in range; in sparse exteriors a
; far-off witness might be missed.  Accept that as fog-of-war.
;
; The victim is excluded because the victim ALWAYS detects whoever
; is choking them (direct contact) — including them would make
; stealth impossible by construction.
; ----------------------------------------------------------------
; ----------------------------------------------------------------
; CanWitness - is this actor a PERSON who can have seen something?
;
; ★ MANNEQUINS ARE NEVER WITNESSES (the user, 2026-09-10: "Mannequin must always be
; excluded"). A HearthFires mannequin is a real Actor: it passes IsDead / IsDisabled /
; IsChild and can have line of sight. In the 2026-09-10 key test this script handed one
; the "fitted ... onto" onlooker line (SkyrimNet: "Could not determine name for actor
; 0x30009AC" = BYOHHouse1InteriorRoom02Part125Mannequin2ndFloor). ManakinRace
; (10760A:Skyrim.esm) catches every vanilla-race mannequin whatever a mod calls it; an
; empty name catches the rest, and SkyrimNet cannot address a nameless actor anyway.
; ----------------------------------------------------------------
Bool Function CanWitness(Actor p)
    if p == None
        return False
    EndIf
    if !manakinRace
        manakinRace = Game.GetFormFromFile(0x0010760A, "Skyrim.esm") as Race
    EndIf
    if manakinRace && p.GetRace() == manakinRace
        return False
    EndIf
    return p.GetDisplayName() != ""
EndFunction

Bool Function IsAssaultWitnessed(Actor victim)
    if victim == None
        return False
    EndIf
    Int tries = 0
    while tries < 12
        Actor probe = Game.FindRandomActorFromRef(victim, 2000.0)
        if probe != None && probe != victim && probe != playerRef && !probe.IsDead() && !probe.IsDisabled() && CanWitness(probe)
            if probe.HasLOS(playerRef) && playerRef.IsDetectedBy(probe)
                return True
            EndIf
        EndIf
        tries += 1
    EndWhile
    return False
EndFunction

; ----------------------------------------------------------------
; FindChokeWitness — like IsAssaultWitnessed, but RETURNS the witness
; actor (or None) so it can be used as the DirectNarration speaker.
; Same fog-of-war sampling: a far-off witness in a sparse exterior may
; be missed, but in any populated area a real onlooker is found.
; ----------------------------------------------------------------
; (FindChokeWitness is GONE, 2026-09-12: FindOnlookers replaces it for both the 7s beat and the
;  passout - its random sample + HasLOS + IsDetectedBy found 0 onlookers in VR test 2.)

Function EndChoke(Bool dispelParalysis)
    EndChokeEx(dispelParalysis, False)
EndFunction

; Internal variant with a silentCleanup flag for save-reload recovery.
; When silentCleanup=True we skip the SkyrimNet release-trigger (no
; spurious "released throat" narration for a choke that happened in a
; previous session) but still run every persistent-state cleanup:
; HealRate restore, faction removal, paralysis dispel, flag reset.
Function EndChokeEx(Bool dispelParalysis, Bool silentCleanup)
    if !chokeActive
        return
    EndIf

    Actor a            = chokeActor
    Float chokeElapsed = Utility.GetCurrentRealTime() - chokeStartTime
    chokeEndTime       = Utility.GetCurrentRealTime()   ; arm the re-arm lockout (StartChoke)
    ; ★ the choke bridge, off edge (see StartChoke).
    SendModEvent("VRTE_ChokeState", "0", 0.0)
    ; ★ 2026-09-12: the choke block comes down on EVERY end - release, passout hand-off,
    ; kill, reload - and before the release narration below is sent. (A no-op if it never
    ; went up, or already came down at passout; the DLL logs only real transitions.)
    if a != None && VRTEStateRank(a) == 1
        VRTEMark(a, 0, 0, 0.0)
    EndIf

    ; --- KO-SLOT-RESIDENT short-circuit (kill-run OR post-passout) ---
    ; Both of these states mean the SAME thing: the victim is already a
    ; KO-slot resident.  The slot — not the choke state machine — owns
    ; their voice silence (SetVoiceRecoveryTime 999), activation state,
    ; HealRate, HP snapshot and wake timer.  On release or death we must
    ; therefore NOT touch NPC state and must NOT narrate: just reset the
    ; choke flags.  Slot cleanup on death is handled by TickKO's IsDead
    ; branch on the next 5s poll.
    ;
    ; chokePassedOut is NEW here (PART B3).  Before the 25s-kill change
    ; the 15s passout reset chokeActive inline, so EndChokeEx could only
    ; ever see a pre-passout cancel.  Now the choke KEEPS RUNNING past
    ; passout while the grip holds, so a release in the 15-25s window
    ; lands here — and without this guard it would fall through to the
    ; blocks below and (a) fire a spurious "Severe" release tier
    ; (chokeElapsed >= 7.0 is trivially true at 15s+), (b) raise an
    ; assault alarm the V2 passout path never raised, and (c) call
    ; SetVoiceRecoveryTime(0.0), UNDOING the KO slot's bark silencing.
    ; Short-circuiting is exactly the behaviour V2's passout had.
    if chokeIsKillRun || chokePassedOut
        if chokeSoundHandle >= 0
            Sound.StopInstance(chokeSoundHandle)
            chokeSoundHandle = -1
        EndIf
        chokeActive         = False
        chokeActor          = None
        chokePassedOut      = False
        chokeFiredSustained = False
        chokeFiredWitnessed = False
        chokeWarnedNoSound  = False
        chokeIsKillRun      = False
        if EnableDebugGrab
            Debug.Notification("VRTouch: CHOKE END (KO-slot resident)")
        EndIf
        return
    EndIf

    ; Note: from here down EndChokeEx only ever runs for a PRE-passout
    ; cancel — the KO-slot short-circuit above has already claimed both
    ; the kill-run and the post-passout cases.

    ; (No blacklist-faction handling — the choke never adds to it; see StartChoke.)

    ; Stop any playing sound
    if chokeSoundHandle >= 0
        Sound.StopInstance(chokeSoundHandle)
        chokeSoundHandle = -1
    EndIf

    ; Release activation block (set at StartChoke)
    if a != None
        a.BlockActivation(False)
    EndIf

    ; Restore voice — StartChoke set this to 999s to silence vanilla
    ; Skyrim barks during the choke.  Reset on pre-passout cancel.
    if a != None
        a.SetVoiceRecoveryTime(0.0)
    EndIf

    ; --- Public assault alarm (pre-passout release, Severe tier) ---
    ; Only chokes that reached the 7s Severe threshold broadcast an
    ; assault alarm.  Local hostility is already handled at the 5s
    ; TickChoke milestone (the victim starts combat with the player
    ; directly) — this block is strictly the PUBLIC response: guards,
    ; faction allies, followers of the victim.
    ;
    ; Witness gate: if the player was never detected by any nearby
    ; actor other than the victim, the alarm is suppressed — simulates
    ; a stealth assault where no one saw what happened.  Combat with
    ; the victim still happens (they know who choked them), but no
    ; bounty, no guard response, no faction-wide hostility.
    ; Relationship gate: friends/allies/lovers (rank >= 2) never raise
    ; the alarm even if witnessed — a spouse or close ally choked in
    ; public doesn't trigger guard response.  Acquaintances, strangers,
    ; rivals and enemies (rank <= 1) alarm normally.
    ; !modOff: SendAssaultAlarm makes guards/faction go hostile and start combat —
    ; a release during a scene must NOT raise it (it would shatter the scene). Same
    ; class as the StartCombat guards in TickChoke; FireTrigger doesn't funnel this.
    if chokeElapsed >= 7.0 && !modOff && a != None && !a.IsDead()
        Int relA = a.GetRelationshipRank(playerRef)
        if relA <= 1 && IsAssaultWitnessed(a)
            a.SendAssaultAlarm()
        EndIf
    EndIf

    ; --- Release LLM trigger (phase-based, single event) ---
    ; Only fires if NPC was conscious and alive when released.
    ; <1s choke: suppress entirely — forgives accidental brushes or
    ; mis-grabs so the player can let go without spawning narration.
    ; Idempotent guard: at most ONE release event per hold.  Belt-and-suspenders
    ; against any double-dispatch / rapid end+re-arm (the duplicate-Severe bug).
    Bool recentlyReleased = (a == chokeLastRelActor && (Utility.GetCurrentRealTime() - chokeLastRelTime) < 3.0)
    ; !modOff: a choke released DURING a scene must not leak its release reaction —
    ; FireTrigger is scene-gated, but the DirectNarration below is a DIRECT call, so
    ; skip the whole reaction (like silentCleanup).  The state cleanup below still runs.
    if !silentCleanup && !modOff && chokeElapsed >= 1.0 && a != None && !a.IsDead() && !recentlyReleased
        chokeLastRelActor = a
        chokeLastRelTime  = Utility.GetCurrentRealTime()
        String releaseTrigger = ""
        String releaseNarr    = ""
        String npcName2       = a.GetDisplayName()
        String playerName2    = playerRef.GetDisplayName()
        String recSeverity    = ""
        Int    recRenders     = 0

        ; ★ 2026-09-12: the three release lines rewritten to the user's standing rules - ENFORCE,
        ; DO NOT NEGATE (no "couldn't", no "can still ... but") and NO PRONOUNS (names, never
        ; they/their) - and stripped of interpretation ("the warning was unmistakable" was a
        ; judgement). Each is the physical after-state only; how she takes it is the LLM's.
        ; The 3-7s and 7-15s releases also ARM the recovery block (0797): the choke block was up,
        ; so its choked turns are sitting in her context and she has to be told her voice is back.
        if chokeElapsed < 3.0
            releaseTrigger = "VRTouch_Neck_Choke_Short"
            releaseNarr    = playerName2 + "'s hand closed briefly around " + npcName2 + \
                "'s throat, a short squeeze and a flash of pressure, then let go."
        ElseIf chokeElapsed < 7.0
            releaseTrigger = "VRTouch_Neck_Choke_Sustained"
            releaseNarr    = playerName2 + " held " + npcName2 + \
                "'s throat crushed shut for several seconds before letting go. " + npcName2 + \
                "'s throat throbs with bruising pressure, and each breath rasps through it."
            recSeverity = "moderate"
            recRenders  = 2
        Else
            ; 7.0 - 15.0s window (15s+ would have passed out and taken the Passout path)
            releaseTrigger = "VRTouch_Neck_Choke_Severe"
            releaseNarr    = playerName2 + " released " + npcName2 + \
                "'s throat seconds before " + npcName2 + " would have passed out. " + npcName2 + \
                "'s lungs burn, black spots flicker at the edge of " + npcName2 + \
                "'s vision, and each breath is a harsh wheeze through a raw throat."
            recSeverity = "severe"
            recRenders  = 3
        EndIf
        if recRenders > 0
            ; ★ 2026-09-12: pushed to the native decorator BEFORE the release narration below, so
            ; the reply to that narration is the first render to carry the recovery block. (The
            ; Papyrus-counted version never rendered at all in the VR test.)
            ; rank 2 moderate / 3 severe, off after her 2 / 3 spoken replies, with a 180 s backstop.
            Int recRank = 2
            if recSeverity == "severe"
                recRank = 3
            EndIf
            VRTEMark(a, recRank, recRenders, 180.0)
            Debug.Trace("[V3] CHOKE RECOVERY armed: " + recSeverity + " x" + recRenders + " after " + chokeElapsed + "s on " + npcName2)
        EndIf

        ; ================================================================
        ; THE RELEASE IS AN INTERRUPT + DIRECT NARRATION (user spec).
        ; ================================================================
        ; Everything from arming to release is a thought — she is being
        ; strangled and cannot speak.  The release is the moment she CAN,
        ; and it must land: cut whatever is playing, then force the reply.
        ;
        ; It deliberately IGNORES the 15s gate.  A 9-second choke released
        ; two seconds after some other reaction still gets its gasping
        ; answer; being choked is not something to be paced out by a
        ; cooldown.  DirectNarration is a direct call, so no gate is even
        ; consulted — this comment exists so nobody "fixes" that later.
        ;
        ; PurgeDialogue(False) is the blocking interrupt.  It clears the queue AND cuts
        ; audio mid-playback, which is what makes this an interrupt tier.
        ; ★ 2026-09-15 (the interrupt rule): only when SHE is the one talking - V3CutIfTalking.
        V3CutIfTalking(a, "choke release")
        SkyrimNetApi.DirectNarration(releaseNarr, a, playerRef)
        ; Stamp BOTH clocks: she has just given a big reaction, so neither
        ; an ordinary touch nor another intimate one should pile straight on
        ; top of it.  (Replaces the old FireTrigger(asThought=True) call,
        ; which recorded the cooldown but ALSO burned her one-per-60s
        ; SkyrimNet thought budget on text the DirectNarration was already
        ; speaking — a duplicate that could silence a later fear-thought.)
        V3RecordFire(a, True)
        VTLog("CHOKE RELEASE (" + releaseTrigger + ") after " + chokeElapsed + "s on " + npcName2)
    EndIf

    chokeActive         = False
    chokeActor          = None
    chokePassedOut      = False
    chokeFiredSustained = False
    chokeFiredWitnessed = False
    chokeWarnedNoSound  = False
    chokeIsKillRun      = False

    if EnableDebugGrab
        Debug.Notification("VRTouch: CHOKE END (dispel=" + dispelParalysis + ")")
    EndIf
EndFunction

; ================================================================
; KO slot management — quest-level replacement for the AME.
;
; Rationale: AMEs get terminated by the engine when the target's 3D
; unloads, even for persistent followers during cell transitions.
; Quest-level state is immune — the quest never unloads.
;
; Each passed-out NPC gets a slot (0-9).  A real-time poll tick
; (5s interval via OnUpdate) checks all occupied slots for:
;   - death (silent slot release, no wake animation)
;   - Restoration heal magic effect (wake immediately)
;   - game-time wake deadline (2-4 game hours from passout)
; ================================================================
; Returns the KO slot index holding akActor, or -1 if not tracked.
Int Function FindKOSlot(Actor akActor)
    if akActor == None
        return -1
    EndIf
    Int i = 0
    while i < 10
        if koActor[i] == akActor
            return i
        EndIf
        i += 1
    EndWhile
    return -1
EndFunction

; ★ 2026-09-13 (fix list 41 V1/V7): True when she cannot answer anything - dead, in one of VRTE's KO slots, or unconscious
; for any other reason. The same ladder KissSpeak and PushSend already used; now shared by every sender.
Bool Function V3OutCold(Actor a)
    if a == None
        return True
    EndIf
    return a.IsDead() || FindKOSlot(a) >= 0 || a.IsUnconscious()
EndFunction

Function StartKOSlot(Actor a)
    if a == None || a.IsDead()
        return
    EndIf
    ; Dedup: if this actor is already in a slot, don't add again.
    ; Prevents double-tracking when the player re-chokes a KO'd NPC
    ; (kill-run path should bypass passout entirely, but defensive).
    if FindKOSlot(a) >= 0
        return
    EndIf
    ; Find free slot
    Int idx = -1
    Int i = 0
    while i < 10 && idx < 0
        if koActor[i] == None
            idx = i
        EndIf
        i += 1
    EndWhile
    if idx < 0
        return
    EndIf

    ; --- Knockout mod's ragdoll recipe ---
    a.ForceActorValue("Paralysis", 1)
    a.PushActorAway(a, 0.001)
    a.SetNotShowOnStealthMeter(True)
    a.SetUnconscious(True)
    Utility.Wait(0.1)
    a.StopCombat()

    ; ★ 2026-09-12 (the user's ruling "b"): her drink-potions ability goes BEFORE the HP drop below -
    ; the drop is what makes the AI drink. Given back in WakeKOSlot.
    koPotionMask[idx] = KOPotionsOff(a)

    ; --- Disarm R hand ---
    Weapon wR = a.GetEquippedWeapon(0)
    if wR != None
        a.UnequipItem(wR)
    Else
        Spell sR = a.GetEquippedSpell(1)
        if sR != None
            a.UnequipSpell(sR, 1)
        EndIf
    EndIf
    ; --- Disarm L hand / shield ---
    Weapon wL = a.GetEquippedWeapon(1)
    if wL != None
        a.UnequipItem(wL)
    Else
        Spell sL = a.GetEquippedSpell(0)
        if sL != None
            a.UnequipSpell(sL, 0)
        Else
            Armor shield = a.GetEquippedShield()
            if shield != None
                a.UnequipItem(shield)
            EndIf
        EndIf
    EndIf

    ; --- ★★ DOWN TO 25%, WAKE AT 50% (the user's ruling, 2026-09-12) + zero regen ---
    ; "regain consciousness at 50% hp, and reduce it to 25% on choke passout - so if some regen
    ; happens, we are still good to go." The wake is an ABSOLUTE threshold with a 25-point gap:
    ; stray regen or a small drift cannot wake her, a real heal (potion, spell, feed) can.
    ; It REPLACES both old wake tests - "health rose 5 above a snapshot" (woke Carmella at once
    ; in the 09-12 VR test) and "any restore-health effect is on her" (a lingering food buff
    ; would have done the same).
    ; ⚠ Measured against her REAL maximum via GetActorValuePercentage. The old code took 50% of
    ; GetBaseActorValue("Health") - the base value without her buffs - so its "50%" was never
    ; really half of what she had. (GetActorValueMax is UNBOUND in Skyrim VR - logged 09-12.)
    Float curHp = a.GetActorValue("Health")
    Float pct0  = a.GetActorValuePercentage("Health")
    if pct0 > 0.25
        a.DamageActorValue("Health", curHp - (curHp * (0.25 / pct0)))
    EndIf
    koHealRate[idx] = a.GetActorValue("HealRate")
    a.ForceActorValue("HealRate", 0.0)   ; kept: belt-and-braces under the 25-point gap
    ; ★ SETTLING (2026-09-12): -2.0 = no wake test runs yet. TickKO waits until the knockout is
    ; >= 4.5 s old, then pushes her back down to 25% if Health drifted up while the ragdoll and
    ; SetUnconscious settled, and only then starts testing for 50%. (-1.0 is the old-save marker.)
    koHpAtKO[idx] = -2.0
    koAtReal[idx] = Utility.GetCurrentRealTime()
    ; UNCONDITIONAL receipt (setpqv EnableDebug does not survive reloading an older save).
    Debug.Trace("[V3] KO START " + a.GetDisplayName() + " slot=" + idx + " hp " + ((pct0 * 100.0) as Int) + "% -> " \
        + ((a.GetActorValuePercentage("Health") * 100.0) as Int) + "% (" + curHp + " -> " + a.GetActorValue("Health") \
        + ") healRate " + koHealRate[idx] + " -> 0 | restoreHealthEffect=" \
        + (kwMagicRestoreHealth != None && a.HasMagicEffectWithKeyword(kwMagicRestoreHealth)) \
        + " | down at 25%, wakes at 50%, tests start after a 4.5s settle")

    ; --- Silence vanilla barks ---
    a.SetVoiceRecoveryTime(999.0)

    ; --- Wake deadline: 2-4 game hours from now ---
    ; Utility.GetCurrentGameTime returns days; multiply by 24 for hours.
    Float wakeHours = Utility.RandomFloat(2.0, 4.0)
    koWakeHour[idx] = Utility.GetCurrentGameTime() * 24.0 + wakeHours

    ; Commit slot last so TickKO sees a fully-initialized entry.
    koActor[idx] = a
    ; ★ V19: publish the KO state (rank 5) - the passout already took the choke block (rank 1) off.
    KOMarkOn(a)

    ; Kick off tick if not already running
    if !koTicking
        koTicking  = True
        koNextTick = Utility.GetCurrentRealTime() + 5.0
        RegisterForSingleUpdate(5.0)
    EndIf
EndFunction

; Wake slot idx — restore all state and clear the slot.
Function WakeKOSlot(Int idx)
    Actor a = koActor[idx]
    if a != None && !a.IsDead()
        ; Knockout's wake order: unconscious off FIRST, then paralysis.
        ; Engine auto-plays get-up anim on Paralysis 1→0.
        a.SetUnconscious(False)
        a.ForceActorValue("Paralysis", 0)
        a.SetNotShowOnStealthMeter(False)
        a.QueueNiNodeUpdate()
        a.SetVoiceRecoveryTime(0.0)
        if koHealRate[idx] >= 0.0
            a.ForceActorValue("HealRate", koHealRate[idx])
        EndIf
        ; ★ 2026-09-12 THE WAKE BLOCK (the user's design): for her next 2 renders, 0798 tells
        ; the LLM she has just come to and is still gathering her senses. Without it nothing
        ; ever told SkyrimNet she woke - measured: every reply after a wake was still
        ; "*Carmella is unconscious.*", even while she was being choked again.
        ; Her potion abilities come back first (the user's ruling "b": off only while knocked out).
        KOPotionsOn(a, koPotionMask[idx])
        ; rank 4: off after her 2 spoken replies OR 60 s, whichever first. The time limit is the fix for
        ; VR test 2, where the wake block first showed 2 m 45 s after she woke, mid another choke.
        ; (V19: rank 4 replaces the KO rank 5 here; when it comes off, the slot below is already empty.)
        VRTEMark(a, 4, 2, 60.0)
        Debug.Trace("[V3] KO WOKE " + a.GetDisplayName() + " slot=" + idx + " - wake block up (2 replies or 60 s)")
    ElseIf a != None
        KOMarkOff(a)
    EndIf
    koActor[idx]    = None
    koHealRate[idx] = -1.0
    koWakeHour[idx] = 0.0
    koHpAtKO[idx]   = -1.0
    koAtReal[idx]   = 0.0
EndFunction

; Slot still in use — defensively re-assert paralysis if something external
; cleared it (another mod dispelling, engine cell-reset edge cases). Only
; meaningful when loaded. ★ 2026-09-12: now logged - an external clear is
; exactly the kind of fact a "she stood up" report needs.
Function KOHoldDown(Actor a)
    if a.Is3DLoaded() && a.GetActorValue("Paralysis") < 0.5
        Debug.Trace("[V3] KO paralysis was CLEARED externally on " + a.GetDisplayName() + " - re-asserted")
        a.ForceActorValue("Paralysis", 1)
        a.SetUnconscious(True)
    EndIf
EndFunction

; ================================================================
; ★ SMART NPC POTIONS OFF WHILE KNOCKED OUT (the user's ruling, 2026-09-12: "b")
; ================================================================
; Takes away whichever of the mod's three drink-potions abilities she holds and returns the mask
; (1 base, 2 Mage, 4 Assassin) so WakeKOSlot can give back exactly those. Also used to re-check:
; the mod's quest re-applies the ability periodically. Harmless (returns 0) without the mod.
Int Function KOPotionsOff(Actor a)
    Int mask = 0
    String gone = ""
    if spNpcPotion && a.HasSpell(spNpcPotion)
        a.RemoveSpell(spNpcPotion)
        mask += 1
        gone += " NPCpotions_Spell"
    EndIf
    if spNpcPotionMage && a.HasSpell(spNpcPotionMage)
        a.RemoveSpell(spNpcPotionMage)
        mask += 2
        gone += " NPCpotions_SpellMage"
    EndIf
    if spNpcPotionAssassin && a.HasSpell(spNpcPotionAssassin)
        a.RemoveSpell(spNpcPotionAssassin)
        mask += 4
        gone += " NPCpotions_SpellAssassin"
    EndIf
    if mask > 0
        Debug.Trace("[V3] KO potions OFF on " + a.GetDisplayName() + ":" + gone)
    EndIf
    return mask
EndFunction

; Smart NPC Potions' quest re-applies its ability on a timer: a knocked-out NPC is checked every
; TickKO, and anything re-added is taken off again and remembered for the wake.
Function KOPotionsRecheck(Int idx, Actor a)
    Int again = KOPotionsOff(a)
    if again > 0
        Debug.Trace("[V3] KO potion ability was RE-ADDED to " + a.GetDisplayName() + " (Smart NPC Potions quest) - taken off again")
        koPotionMask[idx] = KOMaskOr(koPotionMask[idx], again)
    EndIf
EndFunction

; Bitwise OR of two masks made of the bits 1 / 2 / 4 (no SKSE Math dependency).
Int Function KOMaskOr(Int m, Int add)
    Int r = 0
    Int bit = 1
    while bit <= 4
        if ((m / bit) % 2) == 1 || ((add / bit) % 2) == 1
            r += bit
        EndIf
        bit *= 2
    EndWhile
    return r
EndFunction

Function KOPotionsOn(Actor a, Int mask)
    if a == None || mask <= 0
        return
    EndIf
    String back = ""
    Bool ok = False
    if spNpcPotion && ((mask / 1) % 2) == 1 && !a.HasSpell(spNpcPotion)
        ok = a.AddSpell(spNpcPotion, False)
        back += " NPCpotions_Spell"
    EndIf
    if spNpcPotionMage && ((mask / 2) % 2) == 1 && !a.HasSpell(spNpcPotionMage)
        ok = a.AddSpell(spNpcPotionMage, False)
        back += " NPCpotions_SpellMage"
    EndIf
    if spNpcPotionAssassin && ((mask / 4) % 2) == 1 && !a.HasSpell(spNpcPotionAssassin)
        ok = a.AddSpell(spNpcPotionAssassin, False)
        back += " NPCpotions_SpellAssassin"
    EndIf
    Debug.Trace("[V3] KO potions back ON for " + a.GetDisplayName() + ":" + back)
EndFunction

; ================================================================
; ★★ THE MARKER FACTION (2026-09-12, third design — the user approved it after the C++ decorators
; were measured failing: SkyrimNet reuses a decorator's answer per NPC for ~30 s).
; ================================================================
; VRTE_ChokeStateFaction (VRTouchEvents.esp 0x804). The prompts read it with SkyrimNet's BUILT-IN
; get_faction_rank, which reads the actor at render time - why the DD gag block (worn_has_keyword)
; has always been on time.
;   rank 1 = being choked (0796) · 2 = recovery moderate · 3 = recovery severe (0797) · 4 = just woke (0798)
;   rank <= 0 = off (removed from the faction)
; replies > 0: VRTouchEvents.dll counts her SPOKEN replies (SkyrimNet "dialogue" event) and sends
;              VRTE_RepliesDone when they are spent -> OnVRTERepliesDone takes the rank off.
; seconds > 0: a REALTIME backstop - off at that time even if she never speaks (VRTEMarkTick).
; ⛔ Call BEFORE the DirectNarration that follows a change: SkyrimNet renders her reply ~60 ms later.
Int Function VRTEStateRank(Actor a)
    if a == None || !vrteStateFaction
        return -1
    EndIf
    return a.GetFactionRank(vrteStateFaction)
EndFunction

Function VRTEMark(Actor a, Int rank, Int replies, Float seconds)
    if a == None || !vrteStateFaction
        return
    EndIf
    if vmActor.Length != 8
        vmActor = new Actor[8]
        vmRank  = new Int[8]
        vmUntil = new Float[8]
    EndIf
    Int slot = -1
    Int free = -1
    Int i = 0
    while i < 8
        if vmActor[i] == a
            slot = i
        ElseIf vmActor[i] == None && free < 0
            free = i
        EndIf
        i += 1
    EndWhile

    if rank <= 0
        ; ★ The prompt reads the state FILE (fourth design) - publish first, it is what SkyrimNet sees.
        VRTouchEvents_Native.SetPromptState(a, a.GetDisplayName(), 0)
        if a.GetFactionRank(vrteStateFaction) >= 0
            if FindKOSlot(a) >= 0 && !a.IsDead()
                ; ★ V19: still knocked out - the KO rank goes back on under the state that just ended.
                a.SetFactionRank(vrteStateFaction, 5)
                Debug.Trace("[V3] MARK off: " + a.GetDisplayName() + " - still in a KO slot, back to rank 5")
            else
                a.RemoveFromFaction(vrteStateFaction)
                Debug.Trace("[V3] MARK off: " + a.GetDisplayName())
            EndIf
        EndIf
        if slot >= 0
            vmActor[slot] = None
            vmRank[slot]  = 0
            vmUntil[slot] = 0.0
        EndIf
        VRTouchEvents_Native.CountReplies(a, 0)
        return
    EndIf

    if slot < 0
        slot = free
    EndIf
    if slot < 0
        ; Eight NPCs marked at once: the entry whose time limit ends SOONEST gives way.
        ; ★ V18 (fix list 41, 2026-09-13): this was slot 0 by index, whatever it held. vmUntil 0.0 = no limit, which
        ; only the live choke (rank 1) has - it is never chosen while any after-state is there to give way.
        slot = 0
        Int e = 0
        Bool found = False
        while e < 8
            if vmUntil[e] > 0.0 && (!found || vmUntil[e] < vmUntil[slot])
                slot = e
                found = True
            EndIf
            e += 1
        EndWhile
        if vmActor[slot] != None && vmActor[slot] != a
            Debug.Trace("[V3] MARK slots full: " + vmActor[slot].GetDisplayName() + " (rank " + vmRank[slot] + ") gives way to " + a.GetDisplayName())
            VRTouchEvents_Native.SetPromptState(vmActor[slot], vmActor[slot].GetDisplayName(), 0)
            vmActor[slot].RemoveFromFaction(vrteStateFaction)
            VRTouchEvents_Native.CountReplies(vmActor[slot], 0)
        EndIf
    EndIf
    ; ★★ FOURTH DESIGN (2026-09-12, the user's placeholder idea): the state SkyrimNet's prompts read is
    ; the FILE Data/SKSE/Plugins/VRTouchEvents/prompt_state.json, written by the DLL right now. The
    ; faction rank is kept only as VRTE's own Papyrus-side record (EndChokeEx / OnVRTERepliesDone /
    ; the scene toggles test it); SkyrimNet's view of it lags ~20 s (VR test 4), so no prompt uses it.
    VRTouchEvents_Native.SetPromptState(a, a.GetDisplayName(), rank)
    if a.GetFactionRank(vrteStateFaction) < 0
        a.AddToFaction(vrteStateFaction)
    EndIf
    a.SetFactionRank(vrteStateFaction, rank)
    vmActor[slot] = a
    vmRank[slot]  = rank
    vmUntil[slot] = 0.0
    if seconds > 0.0
        vmUntil[slot] = Utility.GetCurrentRealTime() + seconds
    EndIf
    VRTouchEvents_Native.CountReplies(a, replies)
    String what = "being choked"
    if rank == 2
        what = "recovery moderate"
    ElseIf rank == 3
        what = "recovery severe"
    ElseIf rank == 4
        what = "just woke"
    EndIf
    Debug.Trace("[V3] MARK " + a.GetDisplayName() + " rank " + rank + " (" + what + ") replies=" + replies + " limit=" + seconds \
        + "s -> faction rank reads " + a.GetFactionRank(vrteStateFaction))
    if seconds > 0.0
        ScheduleNextUpdate()
    EndIf
EndFunction

; ★★ V19 (fix list 41, 2026-09-13) — THE KO STATE, PUBLISHED FOR OTHER MODS.
; rank 5 on VRTE_ChokeStateFaction (VRTouchEvents.esp 0x804) = she is in a VRTouchEvents KO slot: Paralysis 1,
; SetUnconscious, Health held at 25 %, HealRate 0, until she wakes at 50 % or at the 2-4 game-hour deadline.
; DD SN's Database reads it to hold its own effects (vibration, shock) off an NPC that cannot react to them.
;   * set in StartKOSlot · removed when the slot is released on death · replaced by rank 4 in WakeKOSlot
;   * a rank 1-4 set on her while knocked out (a kill-run choke) wins while it lasts; VRTEMark rank 0 puts 5 back
;   * NOT in the vm ring, and NOT in the prompt-state file (no prompt reads rank 5) - the faction is the whole contract
;   * the faction persists in the save and so does the KO slot; Setup re-asserts rank 5 for every live slot on load
Function KOMarkOn(Actor a)
    if a == None || !vrteStateFaction || a.IsDead()
        return
    EndIf
    if a.GetFactionRank(vrteStateFaction) < 0
        a.AddToFaction(vrteStateFaction)
    EndIf
    a.SetFactionRank(vrteStateFaction, 5)
    Debug.Trace("[V3] MARK " + a.GetDisplayName() + " rank 5 (knocked out) -> faction rank reads " + a.GetFactionRank(vrteStateFaction))
EndFunction

Function KOMarkOff(Actor a)
    if a == None || !vrteStateFaction
        return
    EndIf
    if a.GetFactionRank(vrteStateFaction) == 5
        a.RemoveFromFaction(vrteStateFaction)
        Debug.Trace("[V3] MARK off (KO slot released): " + a.GetDisplayName())
    EndIf
EndFunction

; VRTouchEvents.dll: this NPC has spoken the owed replies. Only an after-state (2/3/4) is counted.
Function OnVRTERepliesDone(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    Int r = VRTEStateRank(a)
    if a != None && r >= 2 && r <= 4   ; rank 5 (knocked out, V19) owes no replies
        Debug.Trace("[V3] MARK replies spent: " + a.GetDisplayName() + " (rank " + r + ")")
        VRTEMark(a, 0, 0, 0.0)
    EndIf
EndFunction

; Takes off every marker whose time limit has passed; returns the seconds to the next limit (999999 = none).
Float Function VRTEMarkTick(Float now)
    Float nextW = 999999.0
    if vmActor.Length != 8
        return nextW
    EndIf
    Int i = 0
    while i < 8
        Actor a = vmActor[i]
        if a != None && vmUntil[i] > 0.0
            if now >= vmUntil[i]
                Debug.Trace("[V3] MARK time limit reached: " + a.GetDisplayName() + " (rank " + vmRank[i] + ")")
                VRTEMark(a, 0, 0, 0.0)
            Else
                if (vmUntil[i] - now) < nextW
                    nextW = vmUntil[i] - now
                EndIf
                ; ★ 2026-09-12 DIAGNOSTIC: in VR test 4 a 180 s limit never fired (Carmella kept rank 3 for
                ; 20 min). This proves the update loop is still reaching the check - at most one line / 30 s.
                if now >= vmTraceAt
                    vmTraceAt = now + 30.0
                    Debug.Trace("[V3] MARK tick: " + a.GetDisplayName() + " rank " + vmRank[i] + " ends in " + ((vmUntil[i] - now) as Int) + "s")
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    return nextW
EndFunction

; ================================================================
; ★★ THE KISS (PPB build 20103 — wired 2026-09-12, the user: "the kiss contact is now live from PPB,
; wire it into VRTE"). Consumer guide: Report/Precision Physic Bodies Module/
; VRTE_API_Change_Request_HeadSource.md § "2026-09-12 UPDATE - how to read the KISS from the API".
; ================================================================
; PPB SENSES the kiss (one edge event); VRTE only VOICES it. Nothing here re-derives a kiss from
; geometry or from the HEAD:mouth digest contacts - PPB says outright those are "where on her face it
; is touching", not the kiss, and they flicker lips/nose through a single kiss.
;
; POLICY — the kiss takes the LIPS row of the policy table (Part 07), because a kiss is the player's
; mouth on her `lips` capsule: 0.5 s dwell · baseline arousal 6 · Speak (Interrupt) · private.
;   * The dwell is real: KissTick speaks only if the kiss is still up 0.5 s after it started, so a
;     lip bump while leaning in says nothing.
;   * The cooldown is NOT consulted (a kiss is one deliberate, edge-triggered act - PPB sends one ON
;     per kiss, so it cannot spam) but BOTH clocks are stamped, so hands touching her during the kiss
;     do not pile narration on top of it.
;   * While the kiss is up, and for 3 s after it ends, VRTE narrates NO HEAD-source touch on her
;     (V3Dispatch) - otherwise "face" and "lips" lines land on top of the kiss.
;   * The end is RECORDED, not spoken: a persistent event with the duration, only if the kiss was
;     narrated and lasted >= 1 s.
; Statement of fact only (the doctrine): which part touched which, and for how long. No pronouns.
Function OnPPBMouthLips(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    String[] parts = StringUtil.Split(strArg, "|")
    ; A fingertip at her lips arrives as "L|LIPS" / "R|LIPS" (two fields) - that is not a kiss.
    if a == None || parts.Length < 3 || parts[2] != "HEAD"
        return
    EndIf
    Float now = Utility.GetCurrentRealTime()
    if numArg >= 0.5
        kissActor   = a
        kissStartAt = now
        kissSaid    = False
        Debug.Trace("[V3] KISS START on " + a.GetDisplayName() + " (PPB_MouthLips " + strArg + ") - narrated if still held at 0.5s")
        ScheduleNextUpdate()
        return
    EndIf
    ; numArg 0 = the kiss ended. PPB may send the OFF for an NPC it stopped tracking; match the sender.
    if a != kissActor
        Debug.Trace("[V3] KISS END for " + a.GetDisplayName() + " with no kiss open on her - ignored")
        return
    EndIf
    Float held = now - kissStartAt
    Debug.Trace("[V3] KISS END on " + a.GetDisplayName() + " after " + held + "s (narrated=" + kissSaid + ")")
    if kissSaid && held >= 1.0 && !modOff && !a.IsDead()
        ; (Fixed 2026-09-12: a 1.76 s kiss read "lasted 1 seconds".)
        String lasted = (held as Int) + " seconds"
        if held < 2.0
            lasted = "about a second"
        EndIf
        SkyrimNetApi.RegisterPersistentEvent(playerRef.GetDisplayName() + "'s mouth left " + a.GetDisplayName() \
            + "'s lips after a kiss that lasted " + lasted + ".", a, playerRef)
    EndIf
    kissLastActor = a
    kissMuteUntil = now + 3.0
    if kissRingActor == a
        kissRingUntil = now + 5.0
    EndIf
    kissActor     = None
    kissSaid      = False
    kissStartAt   = 0.0
EndFunction

; Seconds until an open kiss reaches its 0.5 s dwell (999999 = nothing due). No side effects -
; ScheduleNextUpdate calls it.
Float Function KissWait(Float now)
    if kissActor == None || kissSaid
        return 999999.0
    EndIf
    Float w = (kissStartAt + 0.5) - now
    if w < 0.05
        w = 0.05
    EndIf
    return w
EndFunction

; OnUpdate: speak the kiss once its dwell has passed with the kiss still up.
Function KissTick(Float now)
    if kissActor == None || kissSaid || now < (kissStartAt + 0.5)
        return
    EndIf
    kissSaid = True
    KissSpeak(kissActor, now - kissStartAt)
EndFunction

Function KissSpeak(Actor a, Float held)
    String why = ""
    if a.IsDead()
        why = "she is dead"
    ElseIf modOff || V3InScene(a)
        why = "a scene is running"
    ElseIf chokeActive && chokeActor == a
        why = "she is being choked"
    ElseIf FindKOSlot(a) >= 0 || a.IsUnconscious()
        why = "she is out cold"
    ElseIf a == kissRingActor && Utility.GetCurrentRealTime() < kissRingUntil
        why = "a kiss on " + a.GetDisplayName() + " ended under 5 s ago (kiss ring)"
    EndIf
    if why != ""
        Debug.Trace("[V3] KISS on " + a.GetDisplayName() + " NOT narrated - " + why)
        return
    EndIf
    kissRingActor = a
    kissRingUntil = 0.0
    String narr = playerRef.GetDisplayName() + "'s mouth is pressed to " + a.GetDisplayName() + "'s lips in a kiss."
    Int arm = V3ArmorState(a, "lips")
    ; The LIPS row: Speak (Interrupt), private. The cut is GLOBAL, so it runs only when SHE is talking (V3CutIfTalking).
    V3CutIfTalking(a, "kiss")
    SkyrimNetApi.DirectNarration(narr, a, playerRef)
    V3RecordFire(a, True)
    Debug.Trace("[V3] KISS SPOKEN on " + a.GetDisplayName() + " at " + held + "s (interrupt, private, arm=" + arm + ") | " + narr)
    MaybeArousal(a, VRTouch_TriggerLib.V3ArousalKey("lips"), False, arm, narr, VRTouch_TriggerLib.V3GetArousal("lips", False, arm))
EndFunction

; True while HEAD-source touch narration on this NPC must stay quiet: during her kiss and 3 s after.
Bool Function KissMutes(Actor npc)
    if npc == None
        return False
    EndIf
    if npc == kissActor
        return True
    EndIf
    return npc == kissLastActor && Utility.GetCurrentRealTime() < kissMuteUntil
EndFunction

; ================================================================
; ★★ THE PUSH REACTIONS (PPB build 20104 — wired 2026-09-12, reworked 2026-09-13). Contract:
; Report/Precision Physic Bodies Module/VRTE_API_Notice_2026-09-12_Build20104_PushReaction.md
; ================================================================
; PPB SENSES the reaction and sends it only once the game accepted it (the walk started, the stagger
; played, the knockdown landed); VRTE only VOICES it. The pusher is always the player.
;   push    - a push walk engaged: she steps back from the player's push      = the user's "gentle push"
;   shove   - the push made her stumble (stagger)
;   dropped - a shove knocked her down (ragdoll)                               = "hard stumble"
;   sweeped - both legs swept, she went down (ragdoll)                         = "leg sweep"
; THE USER'S RULINGS:
;   * push + shove = a PERSISTENT EVENT and a THOUGHT; dropped + sweeped = an INTERRUPT with a DIRECT
;     NARRATION ("falling on your ass is a pretty significant event that need to make a NPC stop talking").
;   * "wait 3sec before exposing a push, in case it turn into a shove, that way it's not 2 event sent for one
;     interaction" - a push is HELD 3 s; a shove, a knockdown or a sweep on her inside that window REPLACES it.
;   * "once we sent an event to skyrimnet about a push, wait 5 sec for the next one" - shared by push and
;     shove. dropped / sweeped are never held and never throttled.
;   * HOW: "there can't be a push without a contact, we just need to look at that. only core contact can do
;     push/shove/stumble, and leg sweep is always at the leg" + "we prevent the contact event and add it to
;     the push/shove event". VRTouchEvents.dll's TakePushContact hands over the player's contact on her core
;     (or legs) and TAKES it - the bridge stops naming that contact while it lives. A touch line that already
;     went out before PPB's push event arrived cannot be recalled; the push line still says how.
;   * Fact only, no pronouns (V3PushLine). The direct narration is PRIVATE (she answers the player).
; ⚠ The THOUGHT half is SkyrimNet's to throttle (one per NPC per 60 s); the persistent event always lands.
Function OnPPBPushReaction(String eventName, String strArg, Float numArg, Form sender)
    ; FOMOD "Push reactions: off" - PPB still detects and still physically pushes her;
    ; VRTouchEvents simply says nothing, and the pushing hand's contact is left alone
    ; (not TAKEN), so it narrates normally as an ordinary touch.
    if !VRTouch_PushGate.IsEnabled()
        return
    EndIf
    ; The ARRIVAL time, read before any native call: it decides whether a shove came inside a push's 3 s grace.
    Float arrived = Utility.GetCurrentRealTime()
    Actor a = sender as Actor
    if a == None || a == playerRef || a.IsChild()
        return
    EndIf
    ; PPB build 20105: "<kind>|<npc name>|<wand R|L>|<slot>|<child>|<leftTwin>", every field '|'-free (older builds:
    ; "<kind>|<name>" - field 2 is then empty and the bridge ranks the candidates as before).
    ; PPB build 20106 (P2): field 7 <afterShove> = 1 on a dropped / sweeped that followed this NPC's own shove inside PPB's
    ; 1.5 s reaction cooldown (measured 0.17 s apart). Inside the 0.5 s shove hold (V9) the knockdown replaces the held
    ; shove whatever the flag says; the flag is logged so a fall that came AFTER the hold ran out can be read for what it was.
    String[] pf = V3Split12(strArg)
    String kind = pf[0]
    if pf[6] == "1"
        Debug.Trace("[V3] PUSH " + kind + " on " + a.GetDisplayName() + " came after a shove on her (PPB afterShove=1)")
    EndIf
    if kind != "push" && kind != "shove" && kind != "dropped" && kind != "sweeped"
        Debug.Trace("[V3] PUSH unknown kind '" + kind + "' on " + a.GetDisplayName() + " (" + strArg + ") - ignored")
        return
    EndIf
    ; The contact that did it - taken NOW, so the bridge stops narrating it from this moment. ★ PPB names the pushing
    ; hand now (the user, 2026-09-13: "sure, sound better"): that hand's contact wins when it qualifies.
    String how = VRTouchEvents_Native.TakePushContact(a, kind, pf[2])
    ; ⚠ The native yielded the script for a frame: the push hold's own OnUpdate may have run meanwhile.
    Float now = Utility.GetCurrentRealTime()

    if kind == "push"
        ; ★ The 3 s is a GRACE PERIOD, not a duration (user, 2026-09-13): a push that lasted 1 s is still sent - 3 s
        ; after it arrived, unless a shove or a fall on her replaced it first.
        Int held = PushHoldFind(a, 0)
        if held >= 0
            ; A second walk inside the same grace is the same interaction (and a walk under a held shove adds nothing).
            if pushHoldHow[held] == ""
                pushHoldHow[held] = how
            EndIf
            return
        EndIf
        PushHoldPut(a, now, how, "push")
        Debug.Trace("[V3] PUSH push on " + a.GetDisplayName() + " HELD 3s grace (sent unless a shove or a fall replaces it) | how=" + how)
        ScheduleNextUpdate()
        return
    EndIf

    ; shove / dropped / sweeped REPLACE a push held on her; dropped / sweeped also replace a held shove. Found and
    ; marked with no call in between, so nothing can interleave. A hold already being SENT is replaced too when this
    ; event ARRIVED inside its grace: PushSend checks the mark right before it talks to SkyrimNet (verify 2026-09-13:
    ; reading the clock after the native had pushed such a shove past the deadline and dropped it).
    Int hi = PushHoldFind(a, -2)
    if hi >= 0 && arrived < pushHoldAt[hi] + PushHoldSecs(pushHoldKind[hi])
        String heldKind = pushHoldKind[hi]
        if kind == "shove" && heldKind == "shove"
            ; A second stagger inside the same 0.5 s is the same interaction.
            if pushHoldState[hi] == 0 && pushHoldHow[hi] == ""
                pushHoldHow[hi] = how
            EndIf
            return
        EndIf
        String heldHow = pushHoldHow[hi]
        if pushHoldState[hi] == 0
            PushHoldClear(hi)
        Else
            pushHoldState[hi] = 2      ; SENDING -> REPLACED: that send aborts
        EndIf
        if how == "" && kind != "sweeped"
            how = heldHow    ; the same hand made both
        EndIf
        Debug.Trace("[V3] PUSH held " + heldKind + " on " + a.GetDisplayName() + " REPLACED by " + kind)
    EndIf
    ; ★ V9 (fix list 41, 2026-09-13): a shove is HELD 0.5 s the way a push is held 3 s. PPB's rag escalation can
    ; pre-empt its own reaction cooldown, so a hard push arrived as `shove` then `dropped` - two lines for one fall.
    ; A knockdown or a sweep inside the 0.5 s replaces the shove; otherwise the shove goes out when it runs out.
    if kind == "shove"
        PushHoldPut(a, now, how, "shove")
        Debug.Trace("[V3] PUSH shove on " + a.GetDisplayName() + " HELD 0.5s (sent unless a fall replaces it) | how=" + how)
        ScheduleNextUpdate()
        return
    EndIf
    PushSend(a, kind, how, now)
EndFunction

; ★ V9: how long a held reaction waits for something bigger to replace it.
Float Function PushHoldSecs(String kind)
    if kind == "shove"
        return 0.5
    EndIf
    return 3.0
EndFunction

; Narrate one push reaction now (the gates are checked at send time). holdSlot >= 0 = a held push being sent from
; that slot: it aborts if a shove or a fall replaced it while this send was yielding.
Function PushSend(Actor a, String kind, String how, Float now, Int holdSlot = -1)
    String nName = a.GetDisplayName()
    Bool loud = (kind == "dropped" || kind == "sweeped")
    String why = ""
    if a.IsDead()
        why = "she is dead"
    ElseIf modOff || V3InScene(a)
        why = "a scene is running"
    ElseIf chokeActive && chokeActor == a
        why = "she is being choked"
    ElseIf FindKOSlot(a) >= 0 || a.IsUnconscious()
        why = "she is out cold"
    ElseIf !loud && PushRecent(a, now, holdSlot)
        why = "a push or shove line went out on her under 5 s ago"
    EndIf
    if why != ""
        Debug.Trace("[V3] PUSH " + kind + " on " + nName + " NOT narrated - " + why)
        return
    EndIf
    Bool pushMale = False
    ActorBase pushBase = a.GetLeveledActorBase()
    if pushBase && pushBase.GetSex() == 0
        pushMale = True
    EndIf
    String narr = VRTouch_TriggerLib.V3PushLine(kind, playerRef.GetDisplayName(), nName, how, pushMale)
    ; The last check before SkyrimNet: a held push or shove whose slot was REPLACED while this send yielded does not go out.
    if holdSlot >= 0 && (pushHoldActor[holdSlot] != a || pushHoldState[holdSlot] == 2)
        Debug.Trace("[V3] PUSH " + kind + " on " + nName + " NOT narrated - replaced by a bigger reaction inside its grace")
        return
    EndIf
    if V3LogOnly
        if !loud
            PushStamp(a, now)   ; shadow mode models live pacing, like V3Dispatch's
        EndIf
        Debug.Trace("[V3] PUSH " + kind + " WOULD FIRE (log-only) on " + nName + " | " + narr)
        return
    EndIf
    if loud
        ; The cut is GLOBAL, so it runs only when SHE is talking (V3CutIfTalking, 2026-09-15).
        V3CutIfTalking(a, kind)
        SkyrimNetApi.DirectNarration(narr, a, playerRef)
        V3RecordFire(a, True)
        Debug.Trace("[V3] PUSH " + kind + " on " + nName + " -> INTERRUPT + DIRECT NARRATION (private) | " + narr)
    Else
        ; Stamp FIRST, so a shove landing during the SkyrimNet calls below sees this line as sent.
        PushStamp(a, now)
        ; The event first, so the thought is generated with it already in her history.
        SkyrimNetApi.RegisterPersistentEvent(narr, a, playerRef)
        SkyrimNetApi.GenerateNPCThought(a, narr)
        V3RecordFire(a, False)
        Debug.Trace("[V3] PUSH " + kind + " on " + nName + " -> PERSISTENT EVENT + THOUGHT requested (SkyrimNet may throttle the thought) | " + narr)
    EndIf
EndFunction

; OnUpdate: send every held push (3 s) or shove (0.5 s) whose grace ran out without turning into anything else.
Function PushTick(Float now)
    if pushHoldActor.Length < 4 || pushHoldState.Length < 4 \
        || pushHoldKind.Length < 4
        return
    EndIf
    Int i = 0
    while i < 4
        Actor a = pushHoldActor[i]
        if a != None && pushHoldState[i] == 0 && now >= pushHoldAt[i] + PushHoldSecs(pushHoldKind[i])
            ; Mark the slot SENDING instead of clearing it: PushSend yields on its actor and SkyrimNet calls, and a shove
            ; that arrived inside the grace must still be able to find and replace this push (review 2026-09-13).
            String how = pushHoldHow[i]
            String heldKind = pushHoldKind[i]
            pushHoldState[i] = 1
            PushSend(a, heldKind, how, now, i)
            if pushHoldActor[i] == a
                PushHoldClear(i)
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

; ★ 2026-09-13: True when that hand (lane "R" / "L") holds a piece of ARMOUR in HIGGS - any armour, a DD inventory
; half with no biped slot included. The contact payload carries only the object's name, so HIGGS is asked.
Bool Function V3HeldArmor(String w)
    if w != "R" && w != "L"
        return False
    EndIf
    ObjectReference held = HiggsVR.GetGrabbedObject(w == "L")
    return held != None && (held.GetBaseObject() as Armor) != None
EndFunction

; Seconds until the next held push is due (999999 = none). No side effects - ScheduleNextUpdate calls it.
Float Function PushWait(Float now)
    Float w = 999999.0
    if pushHoldActor.Length < 4 || pushHoldState.Length < 4 \
        || pushHoldKind.Length < 4
        return w
    EndIf
    Int i = 0
    while i < 4
        if pushHoldActor[i] != None && pushHoldState[i] == 0
            Float left = (pushHoldAt[i] + PushHoldSecs(pushHoldKind[i])) - now
            if left < 0.05
                left = 0.05
            EndIf
            if left < w
                w = left
            EndIf
        EndIf
        i += 1
    EndWhile
    return w
EndFunction

; The hold slot for this NPC, or -1. state 0 = only a HELD push/shove (not one being sent) · -1 = any state ·
; -2 = any state but 2 (V9: a replaced slot waiting to be cleared must not hide a newer hold on the same NPC).
Int Function PushHoldFind(Actor a, Int state0 = -1)
    if pushHoldActor.Length < 4 || pushHoldState.Length < 4
        return -1
    EndIf
    Int i = 0
    while i < 4
        if pushHoldActor[i] == a && (state0 == -1 || (state0 == -2 && pushHoldState[i] != 2) || pushHoldState[i] == state0)
            return i
        EndIf
        i += 1
    EndWhile
    return -1
EndFunction

Function PushHoldPut(Actor a, Float now, String how, String kind)
    if pushHoldActor.Length < 4 || pushHoldState.Length < 4 \
        || pushHoldKind.Length < 4
        pushHoldActor = new Actor[4]
        pushHoldAt    = new Float[4]
        pushHoldHow   = new String[4]
        pushHoldState = new Int[4]
        pushHoldKind  = new String[4]
    EndIf
    Int slot = pushHoldActor.Find(None)
    if slot < 0
        ; Four pushes held at once - send the oldest HELD one now rather than lose it. A slot being sent is never
        ; chosen (it would be sent twice - verify 2026-09-13); if all four are being sent, this push is dropped.
        slot = -1
        Int i = 0
        while i < 4
            if pushHoldState[i] == 0 && (slot < 0 || pushHoldAt[i] < pushHoldAt[slot])
                slot = i
            EndIf
            i += 1
        EndWhile
        if slot < 0
            Debug.Trace("[V3] PUSH push on " + a.GetDisplayName() + " NOT held - four pushes are being sent right now")
            return
        EndIf
        Actor old = pushHoldActor[slot]
        String oldHow = pushHoldHow[slot]
        String oldKind = pushHoldKind[slot]
        if oldKind == ""
            oldKind = "push"
        EndIf
        ; Take the slot for the new hold FIRST - PushSend yields, and nothing may claim this slot in between.
        pushHoldActor[slot] = a
        pushHoldAt[slot]    = now
        pushHoldHow[slot]   = how
        pushHoldState[slot] = 0
        pushHoldKind[slot]  = kind
        PushSend(old, oldKind, oldHow, now)
        return
    EndIf
    pushHoldActor[slot] = a
    pushHoldAt[slot]    = now
    pushHoldHow[slot]   = how
    pushHoldState[slot] = 0
    pushHoldKind[slot]  = kind
EndFunction

Function PushHoldClear(Int i)
    pushHoldActor[i] = None
    pushHoldAt[i]    = 0.0
    pushHoldHow[i]   = ""
    pushHoldState[i] = 0
    if pushHoldKind.Length > i
        pushHoldKind[i] = ""
    EndIf
EndFunction

; True when a push or shove LINE went out on this NPC less than 5 s ago, or one is being sent right now (except
; the push being sent from holdSlot itself). Read-only.
Bool Function PushRecent(Actor a, Float now, Int holdSlot = -1)
    if pushHoldActor.Length >= 4 && pushHoldState.Length >= 4
        Int h = 0
        while h < 4
            if h != holdSlot && pushHoldActor[h] == a && pushHoldState[h] == 1
                return True
            EndIf
            h += 1
        EndWhile
    EndIf
    if pushCdActor.Length < 4
        return False
    EndIf
    Int i = pushCdActor.Find(a)
    if i < 0 || pushCdAt[i] <= 0.0
        return False
    EndIf
    ; A small NEGATIVE age is a stamp written a moment after this event's clock was read (the handlers yield on
    ; natives) - still recent. Setup wipes the ring on load, so a large negative age cannot happen.
    Float age = now - pushCdAt[i]
    return age > -2.0 && age < 5.0
EndFunction

; Stamp a push/shove line for this NPC: her own slot, else an empty one, else the oldest.
Function PushStamp(Actor a, Float now)
    if pushCdActor.Length < 4
        pushCdActor = new Actor[4]
        pushCdAt    = new Float[4]
    EndIf
    Int slot = pushCdActor.Find(a)
    if slot < 0
        slot = pushCdActor.Find(None)
    EndIf
    if slot < 0
        slot = 0
        Int i = 1
        while i < 4
            if pushCdAt[i] < pushCdAt[slot]
                slot = i
            EndIf
            i += 1
        EndWhile
    EndIf
    pushCdActor[slot] = a
    pushCdAt[slot]    = now
EndFunction

; ================================================================
; ★★ MASTURBATION (2026-09-13) — moved INTO VRTE (the user: "just cut it away from the AddOn, it's a VRTE by
; product and yours to work into ... masturbation event are more a general thing than DD specific").
; ================================================================
; PPB_PlayerMasturbation: PPB sends it on the RELEASE edge after the player's OWN hand (an NPC's hand is
; excluded) brought him to full erection - one event at the end of the act. strArg "MAX", numArg = the level,
; sender = the player.
; Only the people who can SEE him hear of it, as a SHORT-LIVED event each (the user's 2026-08-29 witness rule:
; the one it happens to gets a persistent event, a watcher a short-lived one). Onlookers = VRTE's range +
; line-of-sight test (FindOnlookers), which found watchers in VR where the old HasLOS+IsDetectedBy sample did not.
; ⚠ That test does not ask whether the watcher DETECTS the player (the removed DD version did, at 1050 u) - the
;   same user-approved rule as the choke's onlookers. A sneaking player in plain line of sight still counts.
; ★ 30 s cooldown (review 2026-09-13): PPB raises it on EVERY release edge once the level reached max, so a hand
;   leaving the radius on each stroke would re-run the onlooker scan several times a second.
; Fact only, no pronouns.
Function OnPPBPlayerMasturbation(String eventName, String strArg, Float numArg, Form sender)
    v3nMasturbation += 1
    Float now = Utility.GetCurrentRealTime()
    if mastLastAt > 0.0 && now - mastLastAt >= 0.0 && now - mastLastAt < 30.0
        Debug.Trace("[V3] MASTURBATION not narrated - one went out " + ((now - mastLastAt) as Int) + "s ago (30 s)")
        return
    EndIf
    if modOff || V3InScene(playerRef)
        Debug.Trace("[V3] MASTURBATION not narrated - a scene is running")
        return
    EndIf
    mastLastAt = now
    String pName = playerRef.GetDisplayName()
    String narr = pName + " masturbated to a full erection."
    Actor[] seen = FindOnlookers(playerRef, 4)
    Int n = 0
    Int i = 0
    while i < 4
        Actor o = seen[i]
        if o != None
            if V3LogOnly
                Debug.Trace("[V3] MASTURBATION WOULD tell " + o.GetDisplayName() + " (log-only) | " + narr)
            Else
                SkyrimNetApi.RegisterShortLivedEvent("vrte_saw_mast_" + VRTouchEvents_Native.FormIDDec(o), \
                    "vrte_witnessed", narr, "", 600000, o, playerRef)
            EndIf
            n += 1
        EndIf
        i += 1
    EndWhile
    Debug.Trace("[V3] MASTURBATION (level " + (numArg as Int) + ") seen by " + n + " onlooker(s) | " + narr)
EndFunction

; ================================================================
; ★ THE ONLOOKER TEST (2026-09-12, user-approved: "within range and in line of sight")
; ================================================================
; Replaces HasLOS + IsDetectedBy on a random sample, which found 0 onlookers in VR test 2 with
; Carmella standing beside Sofia's choke. Every candidate within range is logged with its numbers,
; so the next test says exactly who was looked at and why they did or did not count.
Bool Function OnlookerSees(Actor victim, Actor p, Bool logIt)
    if p == None || p == victim || p == playerRef || p.IsDead() || p.IsDisabled() || p.IsChild() || !CanWitness(p)
        return False
    EndIf
    Float dist = p.GetDistance(victim)
    if dist > 2000.0
        return False
    EndIf
    if p.IsUnconscious() || FindKOSlot(p) >= 0
        if logIt
            Debug.Trace("[V3] ONLOOKER " + p.GetDisplayName() + " dist=" + (dist as Int) + " - out cold, not watching")
        EndIf
        return False
    EndIf
    Bool los = p.HasLOS(victim)
    if logIt
        String verdict = "not seen"
        if los
            verdict = "SEES IT"
        EndIf
        Debug.Trace("[V3] ONLOOKER " + p.GetDisplayName() + " dist=" + (dist as Int) + " los=" + los + " -> " + verdict)
    EndIf
    return los
EndFunction

; Up to maxCount (max 4) actors who can see the victim: every actor in her cell, then a sampled top-up
; for an exterior neighbour cell. Unused tail entries are None.
Actor[] Function FindOnlookers(Actor victim, Int maxCount)
    Actor[] found = new Actor[4]
    if victim == None
        return found
    EndIf
    if maxCount > 4
        maxCount = 4
    EndIf
    Int n = 0
    Int scanned = 0
    Cell c = victim.GetParentCell()
    if c
        ; ⛔ 43 = kNPC. SKSE's filter matches the reference's BASE OBJECT type, so the placed-
        ; reference type 62 (kCharacter) matched NOTHING - VR test 3 logged "0 actors checked in
        ; her cell" with Carmella herself in it. Diary of Mine, iActions and Laura's Bondage Shop
        ; all scan with 43.
        Int total = c.GetNumRefs(43)
        Int i = 0
        while i < total && n < maxCount
            Actor p = c.GetNthRef(i, 43) as Actor
            if p != None
                scanned += 1
                if OnlookerSees(victim, p, True)
                    found[n] = p
                    n += 1
                EndIf
            EndIf
            i += 1
        EndWhile
    EndIf
    Int tries = 0
    while tries < 8 && n < maxCount
        Actor q = Game.FindRandomActorFromRef(victim, 2000.0)
        if q != None && q.GetParentCell() != c && found.Find(q) < 0
            if OnlookerSees(victim, q, True)
                found[n] = q
                n += 1
            EndIf
        EndIf
        tries += 1
    EndWhile
    Debug.Trace("[V3] ONLOOKERS for " + victim.GetDisplayName() + ": " + n + " see it (" + scanned + " actors checked in her cell)")
    return found
EndFunction

; Poll all KO slots for death, heal, or wake-timer expiry.
; Called from OnUpdate every 5s while any slot is active (koNextTick, 2026-09-12).
Function TickKO()
    Float nowHour = Utility.GetCurrentGameTime() * 24.0
    Float nowReal = Utility.GetCurrentRealTime()
    Bool  any     = False
    Int   i       = 0
    while i < 10
        Actor a = koActor[i]
        if a != None
            ; ★ 2026-09-12: every branch that ends a slot says WHICH test fired, unconditionally.
            ; The VR test that found the instant wake could not say why - WakeKOSlot was silent.
            Float koSecs = -1.0
            if koAtReal[i] > 0.0
                koSecs = nowReal - koAtReal[i]
            EndIf
            if a.IsDead()
                ; Slot release — no wake anim, engine handles corpse.
                ; HealRate restore irrelevant on corpse; skip.
                Debug.Trace("[V3] KO slot " + i + " released: " + a.GetDisplayName() + " is dead")
                KOMarkOff(a)
                koPotionMask[i] = 0
                koActor[i]    = None
                koHealRate[i] = -1.0
                koWakeHour[i] = 0.0
                koHpAtKO[i]   = -1.0
                koAtReal[i]   = 0.0
            ElseIf nowHour >= koWakeHour[i]
                Debug.Trace("[V3] KO WAKE reason=deadline (game hour " + nowHour + " >= " + koWakeHour[i] + ") on " + a.GetDisplayName() + " after " + koSecs + "s")
                WakeKOSlot(i)
            ElseIf koHpAtKO[i] < -1.5
                ; ★ SETTLING (2026-09-12): no wake test of any kind yet. Once the knockout is
                ; 4.5 s old, make sure she really sits at 25% - pushing her back down if Health
                ; drifted up while the ragdoll settled - and start testing for 50% from there.
                if a.Is3DLoaded() && (koAtReal[i] <= 0.0 || koSecs >= 4.5)
                    Float sPct = a.GetActorValuePercentage("Health")
                    String sNote = "at " + ((sPct * 100.0) as Int) + "%"
                    if sPct > 0.26
                        Float sHp = a.GetActorValue("Health")
                        a.DamageActorValue("Health", sHp - (sHp * (0.25 / sPct)))
                        sNote = "drifted to " + ((sPct * 100.0) as Int) + "% while settling - pushed back to " \
                            + ((a.GetActorValuePercentage("Health") * 100.0) as Int) + "%"
                    EndIf
                    koHpAtKO[i] = a.GetActorValue("Health")   ; settled - the value is kept for the receipts
                    Debug.Trace("[V3] KO SETTLED " + a.GetDisplayName() + " after " + koSecs + "s: " + sNote \
                        + " | restoreHealthEffect=" + (kwMagicRestoreHealth != None && a.HasMagicEffectWithKeyword(kwMagicRestoreHealth)) \
                        + " | wakes at 50%")
                EndIf
                KOHoldDown(a)
                KOPotionsRecheck(i, a)
                any = True
            ElseIf a.Is3DLoaded() && a.GetActorValuePercentage("Health") >= 0.50
                ; ★ THE WAKE (the user's ruling): Health back to 50% of her real maximum. From the
                ; 25% floor that takes a real heal - a potion (incl. the GiftByHand feed), a heal
                ; spell, an ingested effect - and never stray regen. WakeKOSlot clears BOTH
                ; SetUnconscious and the Paralysis AV together, so she actually gets up.
                Debug.Trace("[V3] KO WAKE reason=hp50 on " + a.GetDisplayName() + " after " + koSecs + "s (hp " \
                    + ((a.GetActorValuePercentage("Health") * 100.0) as Int) + "%, settled at " + koHpAtKO[i] \
                    + ") | restoreHealthEffect=" + (kwMagicRestoreHealth != None && a.HasMagicEffectWithKeyword(kwMagicRestoreHealth)))
                WakeKOSlot(i)
            Else
                KOHoldDown(a)
                KOPotionsRecheck(i, a)
                any = True
            EndIf
        EndIf
        i += 1
    EndWhile

    if any
        koTicking = True
    Else
        koTicking = False
    EndIf
EndFunction

; ----------------------------------------------------------------
; TickChoke — called from OnUpdate at chokeNextTick intervals
; Sets chokeNextTick to schedule the next tick before returning.
; ----------------------------------------------------------------
Function TickChoke()
    if !chokeActive || !chokeActor
        return
    EndIf

    Actor  a       = chokeActor
    Float  now     = Utility.GetCurrentRealTime()
    Float  elapsed = now - chokeStartTime

    ; Always check for death (someone else killed the NPC, or our Kill fired)
    if a.IsDead()
        EndChokeEx(False, chokeIsKillRun)
        return
    EndIf

    ; ======================================================
    ; KILL-RUN phase (re-choke of already-KO'd NPC → 10s to death)
    ; NPC is already passed out, muted, and in a KO slot.  We
    ; do NOT fire narration events and we do NOT touch NPC
    ; state on release (slot owns it).  The 10s here is on top
    ; of the original 15s passout run, for a 25s total sequence.
    ; ======================================================
    if chokeIsKillRun
        ; Liveness: controller grip (see active phase) — both hands, not the
        ; single latched chokeIsLeft, PLUS the PPB grab witness.
        if elapsed >= 1.0 && HiggsVR.GetGrabbedObject(True) != a && HiggsVR.GetGrabbedObject(False) != a \
        && (now - chokeLastContact) >= 2.0
            EndChokeEx(False, True)
            return
        EndIf

        ; Pain grunts — NPC is KO'd but the voice engine still plays
        ; pain sounds on the anim event.
        if elapsed >= 1.0
            Debug.SendAnimationEvent(a, "painSmall")
        EndIf

        ; 10s → Kill.  TickKO will purge the slot on its next 5s poll
        ; via the IsDead branch (silent slot release, no wake anim).
        ; INTENTIONALLY NOT modOff-guarded: a kill is the physical outcome of the
        ; player deliberately holding a 25s lethal choke, same class as the 15s
        ; passout/KO (also unguarded) — "mod off during a scene" suppresses
        ; REACTIONS (LLM/combat/alarm), not the player's deliberate physical act.
        ; Kill(playerRef) handles murder attribution; SendAssaultAlarm is skipped
        ; anyway once a.IsDead().
        if elapsed >= 10.0
            a.Kill(playerRef)
            EndChokeEx(False, True)
            return
        EndIf

        chokeNextTick = now + 0.5
        return
    EndIf

    if !chokePassedOut
        ; ======================================================
        ; Active choke phase (0s – 15s)
        ; ======================================================

        ; --- Liveness: the CONTROLLER GRIP, on TWO independent witnesses ---
        ; The PPB neck+GRAB contact only ARMS the choke (hard to start, by
        ; design).  Once armed it holds until the player physically RELEASES
        ; the grip, the victim dies, or 15s passout.  It must NOT end merely
        ; because the reported capsule changed as the victim squirms — that
        ; was the old cancel+re-arm churn that fired a release tier on EVERY
        ; cycle (the "all three tiers fired" bug) and re-opened the gag gate.
        ;
        ; Two independent sources are retained deliberately (report 16 §7.3):
        ;   1. HiggsVR.GetGrabbedObject on BOTH hands — never the single
        ;      latched chokeIsLeft.  A VR mis-latch where HIGGS resolved the
        ;      throat grab to the other hand used to false-end the choke every
        ;      tick and let it re-arm (the multi-fire bug).
        ;   2. chokeLastContact — PPB's own src=GRAB stream via V3ChokeStamp,
        ;      read from the physics frame rather than HIGGS's Papyrus API.
        ;      This REPLACES the deleted grabActor_L/R pair; §7.3 warns that
        ;      dropping those without a substitute halves the watchdog.
        ; 2.0s of PPB staleness counts as released (updates arrive ~1/s).
        ; The 1s settle guards a hand-detection race right at StartChoke.
        if elapsed >= 1.0 && HiggsVR.GetGrabbedObject(True) != a && HiggsVR.GetGrabbedObject(False) != a \
        && (now - chokeLastContact) >= 2.0
            if EnableDebugGrab
                Debug.Notification("VRTouch: CHOKE grip released, ending")
            EndIf
            EndChoke(False)
            return
        EndIf

        ; --- Choke vocalization every ~2s ---
        ; Primary: configured ChokingSound SNDR (set in CK).
        ; Fallback: "painSmall" animation event — triggers the NPC's
        ; own pain voice line via their voice type.  Works for most
        ; humanoid voice types without extra setup.
        if elapsed >= 2.0 && chokeSoundHandle < 0
            ; Try a late runtime load in case Setup()'s GetFormFromFile
            ; was too early (pre-esp-resolve) or was run on an older save.
            if ChokingSound == None
                ChokingSound = Game.GetFormFromFile(0x000803, "VRTouchEvents.esp") as Sound
            EndIf
            if ChokingSound != None
                chokeSoundHandle = ChokingSound.Play(a)
                if chokeSoundHandle < 0
                    Debug.Notification("VRTouch: ChokingSound.Play returned bad handle " + chokeSoundHandle)
                EndIf
            ElseIf !chokeWarnedNoSound
                chokeWarnedNoSound = True
                ; Diagnostic: separate "ESP missing record" from "cast failed"
                Form fTest = Game.GetFormFromFile(0x000803, "VRTouchEvents.esp")
                if fTest == None
                    Debug.Notification("VRTouch: SOUN 000803 NOT in VRTouchEvents.esp (ESP not loaded?)")
                Else
                    Debug.Notification("VRTouch: SOUN 000803 found but not a Sound type")
                EndIf
            EndIf
        EndIf
        ; Fire pain anim event periodically — piggyback on existing tick
        ; cadence (every 0.5s in active phase).  The NPC's voice engine
        ; self-throttles so spam is harmless.
        if elapsed >= 1.0
            Debug.SendAnimationEvent(a, "painSmall")
        EndIf

        ; ★ THE 3s FEAR-THOUGHT IS DELETED (2026-08-08) — DO NOT RE-ADD.
        ; SkyrimNet allows ONE thought per NPC per 60 seconds
        ; (config/NpcThoughts.yaml, perNPCCooldownSeconds: 60), and that
        ; budget is global — it is NOT in PatchConfig's allowed section list,
        ; so it cannot be relaxed for the choke at runtime.
        ;
        ; With two fear-thoughts in the chain the 3s one always won the race
        ; and the 7s one was silently discarded, so the escalation never
        ; reached the LLM at all: the victim's inner state stopped developing
        ; four seconds into a fifteen-second strangling.  Spending the single
        ; available thought on the LATER, more desperate line is strictly
        ; better, and nothing is lost below 7s — a short choke still gets its
        ; full release narration (Short / Sustained tiers in EndChokeEx).

        ; ★ 3s: THE CHOKE LANDS (the user's design, 2026-09-12).
        ; ⚠ This is NOT the deleted 3s fear-thought above, and it spends none of her thought
        ; budget: it is an interrupt + a DirectNarration, and it raises the choke prompt block
        ; (0796, via the native vrte_choke decorator), so every render for her from here carries it.
        ; Before 3s a hand on the throat is still just a grab - a release in that window gets
        ; the ordinary short release line and no block.
        if elapsed >= 3.0 && !chokeFired3
            chokeFired3 = True
            if !modOff   ; OFF for a scene: consume the milestone; the block stays down too
                String c3Npc    = a.GetDisplayName()
                String c3Player = playerRef.GetDisplayName()
                ; ⛔ ORDER MATTERS: the block goes up BEFORE the narration. SkyrimNet renders her
                ; reply ~60 ms after DirectNarration, and the native decorator answers from the
                ; state at that instant. (The Papyrus version missed exactly this reply.)
                VRTEMark(a, 1, 0, 0.0)
                ; ★ V8 (fix list 41): the purge the ARM used to run - a choked NPC must not be mid-sentence or have a
                ; line queued. GLOBAL (every actor) and blocking, so it runs once per landed choke, not per grab.
                ; ★ 2026-09-15 (the interrupt rule): and only when SHE is the one talking - V3CutIfTalking.
                V3CutIfTalking(a, "choke landed")
                SkyrimNetApi.DirectNarration(c3Player + "'s hand is clamped tight around " + c3Npc + "'s throat and holds it shut. Air stops at the grip, so every sound " + c3Npc + " makes comes out as a choked, strangled noise.", a, playerRef)
                V3RecordFire(a, True)
                Debug.Trace("[V3] CHOKE 3s LANDED on " + c3Npc + " - interrupt + narration, choke block up")
            EndIf
        EndIf

        ; --- 5s milestone: sustained panic response (no LLM fire) ---
        ; We deliberately do NOT FireTrigger here.  A choked NPC cannot
        ; speak — the pain grunts above are their only vocalization.
        ; Combat behavior engages so they fight back when released.
        if elapsed >= 5.0 && !chokeFiredSustained
            chokeFiredSustained = True
            ; OFF for a scene: consume the milestone but do NOT start combat
            ; mid-scene (StartCombat would shatter the scene).  Wrapped, not
            ; FireTrigger-gated, because these are direct engine/AI calls.
          if !modOff
            ; Response depends on relationship rank — enemies draw
            ; steel, friendlies brawl with fists.
            Int rel = a.GetRelationshipRank(playerRef)
            if rel <= 1
                ; Enemy / stranger — armed combat, weapons drawn.
                a.StartCombat(playerRef)
            Else
                ; Friend, follower, family, lover — brawl response.
                ; Unequip both hands so their StartCombat produces
                ; fist attacks instead of drawn weapons.  Skyrim has
                ; no native Papyrus "StartBrawl" (the vanilla brawl
                ; system is dialogue-quest driven), but unarmed +
                ; StartCombat reproduces the behavior we want: a
                ; furious friendly swinging fists, not carving you up
                ; with their sword.  Their AI picks weapons back up
                ; naturally on combat exit.
                Weapon wR = a.GetEquippedWeapon(0)
                if wR != None
                    a.UnequipItem(wR)
                EndIf
                Weapon wL = a.GetEquippedWeapon(1)
                if wL != None
                    a.UnequipItem(wL)
                EndIf
                a.StartCombat(playerRef)
            EndIf
          EndIf ; !modOff
        EndIf

        ; ★ 7s: THE ROOM NOTICES (the user's design, 2026-09-12).
        ; REPLACES two things:
        ;   * the 7s unvoiced panic-thought pushed to the VICTIM - her state is now carried by
        ;     the choke block from 3s, and the thought spent her one thought per 60s for it;
        ;   * the old single-witness DirectNarration, which made ONE random bystander speak.
        ; Now everyone in view gets what the DD AddOn gives an onlooker: a SHORT-LIVED event
        ; (awareness that fades; keyed per watcher and victim, so a second choke replaces the
        ; first instead of stacking) and an unvoiced thought.
        ; Same sampler and filters as the old device onlooker loop (OnDDZDeviceEquipped, removed 2026-09-13): up to 4
        ; watchers, a mannequin never counts (CanWitness), and the victim is excluded by
        ; construction - she is being strangled, she is not watching it.
        if elapsed >= 7.0 && !chokeFiredWitnessed
            chokeFiredWitnessed = True
          if !modOff   ; OFF for a scene: consume the milestone, nobody is told
            String cwNpc    = a.GetDisplayName()
            String cwPlayer = playerRef.GetDisplayName()
            String cwLine   = cwPlayer + " has " + cwNpc + " by the throat, hand clamped shut around it, and " + cwNpc + " is clawing at the grip."
            ; ★ 2026-09-12: FindOnlookers (range + line of sight, every candidate logged) replaces the
            ; random sample + HasLOS + IsDetectedBy, which found 0 in VR with Carmella watching.
            Actor[] cwSeen = FindOnlookers(a, 4)
            Int cwFound = 0
            Int cwi = 0
            while cwi < 4
                Actor cwProbe = cwSeen[cwi]
                if cwProbe != None
                    SkyrimNetApi.RegisterShortLivedEvent("vrte_choke_saw_" + cwProbe.GetFormID() + "_" + a.GetFormID(), \
                        "vrte_choke_witnessed", cwLine, "", 600000, cwProbe, a)
                    SkyrimNetApi.GenerateNPCThought(cwProbe, cwLine)
                    cwFound += 1
                EndIf
                cwi += 1
            EndWhile
            Debug.Trace("[V3] CHOKE 7s seen by " + cwFound + " onlooker(s) on " + cwNpc + " | " + cwLine)
          EndIf ; !modOff
        EndIf

        ; --- 15s milestone: passout ---
        if elapsed >= 15.0
            ; Stop sound (12 s of audio started at elapsed >= 2.0 s — see the
            ; arming site; this comment said "at 3s" and was wrong)
            if chokeSoundHandle >= 0
                Sound.StopInstance(chokeSoundHandle)
                chokeSoundHandle = -1
            EndIf

            ; Hand off to KO slot manager (quest-level state).
            ; StartKOSlot applies the ragdoll recipe, HP/regen drop,
            ; voice silence, disarm, and arms the 2-4 game-hour wake
            ; timer.  Quest-level state is immune to cell transitions
            ; that terminated the previous AME-based implementation.
            ;
            ; Unblock activation — NPC is on the ground now
            a.BlockActivation(False)

            ; ★★ THE PASSOUT NARRATION — WHO SPEAKS (the user's ruling, 2026-09-12: "an onlooker
            ; reacts if one can see it").
            ; It used to be DirectNarration(line, None, None) on the theory that SkyrimNet would
            ; pick a bystander. Measured in VR: it picked THE VICTIM - an unconscious NPC was
            ; forced to reply ("*Carmella is unconscious.*"). Now:
            ;   * an onlooker who can SEE her (FindOnlookers: within range + line of sight on
            ;     her, not out cold themselves) is named as the speaker -> that person reacts out loud;
            ;     targetActor None = addressed to everyone nearby, as the old YAML's audience was
            ;   * nobody sees it -> nobody is forced to speak. The passout is still RECORDED as a
            ;     persistent event (awareness, no reaction), so her history holds the passout the
            ;     wake block (0798) later refers to.
            ; NOT a thought: the thought manager self-skips unconscious actors, so a thought would
            ; be dropped the moment StartKOSlot runs. !modOff: a scene consumes the milestone
            ; silently, like every other choke milestone.
            VTLog("CHOKE PASSOUT at elapsed=" + elapsed + "s on " + a.GetDisplayName())
            ; ★ 2026-09-12: the choke block comes DOWN before this narration is sent (measured:
            ; the Papyrus decorator left it up, so her passout reply was told every sound she
            ; makes is a strangled noise). And the line lost its "their strength ... they go
            ; limp" - names, never they/their, like the three release lines.
            VRTEMark(a, 0, 0, 0.0)
            String poLine = a.GetDisplayName() + "'s eyes flutter and roll back, and " + a.GetDisplayName() + \
                " goes limp in " + playerRef.GetDisplayName() + "'s grasp, unconscious."
            if !modOff
                Actor[] poSeen = FindOnlookers(a, 1)
                Actor poWitness = poSeen[0]
                if poWitness != None
                    SkyrimNetApi.DirectNarration(poLine, poWitness, None)
                    Debug.Trace("[V3] CHOKE PASSOUT at " + elapsed + "s on " + a.GetDisplayName() + " - block down; onlooker " + poWitness.GetDisplayName() + " reacts")
                Else
                    SkyrimNetApi.RegisterPersistentEvent(poLine, a, playerRef)
                    Debug.Trace("[V3] CHOKE PASSOUT at " + elapsed + "s on " + a.GetDisplayName() + " - block down; no onlooker sees it, recorded silently")
                EndIf
            Else
                Debug.Trace("[V3] CHOKE PASSOUT at " + elapsed + "s on " + a.GetDisplayName() + " - block down; scene on, nothing said")
            EndIf

            StartKOSlot(a)

            ; ★ PART B3 — the choke does NOT end at passout any more.
            ; It used to reset chokeActive/chokeActor inline here and let
            ; the tick loop die.  Now the state machine STAYS ALIVE while
            ; the grip holds, and TickChoke drops into the post-passout
            ; phase below: 10 more seconds of continuous hold = a kill at
            ; 25s total.  A release in between ends it cleanly and
            ; silently via EndChokeEx's KO-slot short-circuit.
            ;
            ; chokeEndTime is deliberately NOT armed here: the choke has
            ; not ENDED, and StartChoke's `if chokeActive` guard already
            ; blocks any re-arm.  EndChokeEx arms the lockout when the
            ; hold genuinely finishes.
            ;
            ; Milestone flags are left as-is on purpose — every one of
            ; them is already consumed (True), and the post-passout phase
            ; fires no milestones, so re-arming them would be meaningless.
            chokePassedOut = True

            ; ChokeKillAt25 False = the pre-B3 behaviour, restored exactly:
            ; the passout ENDS the choke.  EndChokeEx's KO-slot
            ; short-circuit (which chokePassedOut above has just armed) is
            ; precisely the old inline reset — flags cleared, no release
            ; tier, no alarm, no SetVoiceRecoveryTime undo, victim left to
            ; the KO slot.  Independent of V3LogOnly on purpose: the kill
            ; is a choke feature, not part of the PPB cutover.
            if !ChokeKillAt25
                VTLog("CHOKE ends at passout (ChokeKillAt25=False) on " + a.GetDisplayName())
                EndChokeEx(False, True)
                return
            EndIf

            chokeNextTick  = Utility.GetCurrentRealTime() + 0.5
            VTLog("CHOKE post-passout hold begins on " + a.GetDisplayName() + " — 25s total = kill")
            return
        EndIf

        ; Active phase: tick every 0.5s to catch milestones promptly
        chokeNextTick = now + 0.5
    Else
        ; ======================================================
        ; POST-PASSOUT phase (15s – 25s) — the continuous-hold kill.
        ; The victim is already ragdolled and in a KO slot; the slot owns
        ; all of their state.  This phase fires NO narration and NO
        ; milestones (they are unconscious — nothing to react to, and by
        ; user directive there is NO warning cue).  It does exactly two
        ; things: watch the grip, and kill at 25s.
        ; ======================================================

        ; --- Liveness: THREE witnesses, ALL of which must say "released"
        ; before the choke ends here.
        ;
        ; Two are HIGGS's own hands.  They are proven on an ALREADY-ragdolled
        ; NPC (the kill-run branch runs the same test), but that is NOT the
        ; same as surviving the passout ragdoll TRANSITION this branch sits
        ; behind — StartKOSlot does ForceActorValue(Paralysis) +
        ; PushActorAway + SetUnconscious at 15s, and if HIGGS drops the grab
        ; there, both go false, the choke ends at t=16s, and the 25s kill —
        ; the whole point of this phase — never fires.
        ;
        ; The third is PPB's own src=GRAB stream (V3ChokeStamp), read from
        ; the physics frame and independent of HIGGS's Papyrus API.  It is
        ; report 18 §3c's actor-level liveness and it costs no C++.  2.0s of
        ; staleness = "no longer held" (updates arrive ~1/s).
        ; (It was five before the CBPC removal; the two grab-tracking vars
        ; were fed by OnObjectGrabbed, which is gone.  Independence is what
        ; matters, not count — those two were the same HIGGS fact recorded
        ; twice, whereas PPB reads a different layer entirely.)
        ;
        ; The 16s floor is a 1s settle after the passout upheaval,
        ; mirroring StartChoke's own 1s settle; it can only DELAY noticing
        ; a release, never cause a kill, because the kill still needs a
        ; further 9s of unbroken hold.
        ;
        ; The witness dump below is deliberately unconditional: this
        ; transition has never been observed in VR, and one run of it
        ; settles which witnesses actually survive the ragdoll.  ~20 lines
        ; per choke, only in the 15-25s window.
        Float ppbAge = now - chokeLastContact
        VTLog("CHOKE post-passout witness e=" + elapsed \
            + " higgsL=" + (HiggsVR.GetGrabbedObject(True) == a) \
            + " higgsR=" + (HiggsVR.GetGrabbedObject(False) == a) \
            + " ppbGrabAge=" + ppbAge)
        if elapsed >= 16.0 && HiggsVR.GetGrabbedObject(True) != a && HiggsVR.GetGrabbedObject(False) != a \
        && ppbAge >= 2.0
            if EnableDebugGrab
                Debug.Notification("VRTouch: CHOKE released post-passout, ending")
            EndIf
            VTLog("CHOKE post-passout RELEASE at elapsed=" + elapsed + "s on " + a.GetDisplayName() + " — no kill")
            ; silentCleanup=True is belt-and-suspenders: the KO-slot
            ; short-circuit in EndChokeEx already claims this case on
            ; chokePassedOut, so no release tier and no alarm can fire.
            EndChokeEx(False, True)
            return
        EndIf

        ; Pain grunts — the NPC is out, but the voice engine still plays
        ; pain sounds off the anim event (same as the kill-run phase).
        Debug.SendAnimationEvent(a, "painSmall")

        ; --- 25s total: the kill ---
        ; INTENTIONALLY NOT modOff-guarded, for the same reason as the
        ; kill-run branch: a kill is the physical outcome of the player
        ; deliberately holding a 25s lethal choke, the same class of act
        ; as the 15s passout/KO (also unguarded).  "Mod off during a
        ; scene" suppresses REACTIONS (LLM / combat / alarm), not the
        ; player's deliberate physical act.  Kill(playerRef) handles
        ; murder attribution; TickKO purges the slot on its next 5s poll
        ; via its IsDead branch (silent release, no wake anim).
        if elapsed >= 25.0
            if !a.IsDead()
                VTLog("CHOKE KILL at elapsed=" + elapsed + "s on " + a.GetDisplayName() + " (25s continuous hold)")
                a.Kill(playerRef)
            Else
                VTLog("CHOKE kill skipped at elapsed=" + elapsed + "s — " + a.GetDisplayName() + " already dead")
            EndIf
            EndChokeEx(False, True)
            return
        EndIf

        ; Post-passout: same 0.5s cadence as every other phase.
        chokeNextTick = now + 0.5
    EndIf
EndFunction

; ################################################################
; ############  V3 (PPB coalescer) dispatcher — ADDITIVE  ########
; ################################################################
; Receives the C++ coalescer's mod events (see the VRTE contract):
;   "VRTE_Contact"       first emit for a session, or an escalation
;   "VRTE_ContactUpdate" ~1/s while the session lives, after first emit
;   "VRTE_ContactEnd"    session over (numArg = total duration)
; sender = the touched NPC; numArg = PRIMARY contact duration (s);
; strArg = EXACTLY 16 pipe-separated fields:
;   0 W1  1 SRC1  2 NAME1  3 PART1  4 SUB1  5 DEP1  6 DIST1
;   7 W2  8 SRC2  9 NAME2 10 PART2 11 SUB2 12 DEP2 13 DIST2
;  14 SKEL 15 ESC
; The C++ side owns sensing/priority/windows/merging; THIS side owns
; policy (armor, delays, cooldowns, gates), narration and dispatch.
; ================================================================

; ================================================================
; VRTE handlers (Functions registered via RegisterForModEvent, same
; pattern as OnCBPC / OnVRTouchEvent — no Event declarations).
; ================================================================
Function OnVRTEContact(String eventName, String strArg, Float numArg, Form sender)
    Actor npc = sender as Actor
    if !npc || npc == playerRef || npc.IsChild()
        return
    EndIf
    if v3CdActor.Length < 16 || v3PendActor.Length < 16
        return    ; rings not sized yet (Setup runs on every load via the alias)
    EndIf

    ; ================================================================
    ; ★ SCENE SHUTDOWN ENTRY — RESTORED 2026-08-02 (regression fix).
    ; ================================================================
    ; This call was LOST in the CBPC removal.  EnterSceneOff used to be
    ; reached from OnCBPC and OnVRTouchEvent — the two high-frequency entry
    ; points — and deleting both left it defined with NO caller.  Result: an
    ; OStim scene ran with `modOff` never set, so the sinks were never
    ; unregistered and the C++ bridge never paused; confirmed by the absence
    ; of any `[PPB-BRIDGE] PAUSED` line during a live scene.
    ;
    ; Correctness was never affected — V3Dispatch keeps its own exact
    ; per-event scene gate further down, so nothing was ever narrated during
    ; a scene.  What was lost is the OPTIMISATION that gate exists to avoid:
    ; the coalescer sweeping at apiHz and Papyrus receiving every event only
    ; to drop it. That is precisely the scene-lag fix.
    ;
    ; ScenesSuppress is throttled to ~2 checks/sec, so this costs almost
    ; nothing on the hot path.  OnVRTEContact is the direct successor to
    ; OnCBPC, so it is the correct home.
    if ScenesSuppress(npc)
        EnterSceneOff(npc)
        return
    EndIf

    v3nContacts += 1
    String[] f = V3Split35(strArg)
    V3ChokeStamp(npc, f)
    ; A fresh VRTE_Contact is a NEW session or an escalation - either way the hold that was
    ; being watched for a sustain upgrade is over. If this one also goes out persistent it
    ; re-arms with its own point.
    ; ★ 2026-09-13: a lane JOIN (ESC "2" - her left hand, the mouth ... joined a running session) is not a
    ; new hold: the hold already being watched keeps its sustain point.
    if f[0] != "2"
        V3SusClear(npc)
    EndIf
    ; ESC "0" on a VRTE_Contact = the session's FIRST emit: nothing in it has been voiced yet.
    if f[0] == "0"
        V3VoicedSet(npc, 0)
    EndIf
    V3Dispatch(npc, f, numArg, False)
EndFunction

Function OnVRTEContactUpdate(String eventName, String strArg, Float numArg, Form sender)
    Actor npc = sender as Actor
    if !npc
        return
    EndIf
    ; ★ CHOKE LIVENESS WITNESS (see TickChoke's post-passout phase).
    ; This must run BEFORE the pending-dwell bail-out below: once the
    ; choke arms, V3Dispatch clears the pending entry, so every later
    ; update for the choked actor returns at that check and would never
    ; reach a stamp placed inside V3Dispatch.  Guarded on chokeActive so
    ; the split costs nothing in the normal case.
    if chokeActive && npc == chokeActor
        V3ChokeStamp(npc, V3Split35(strArg))
    EndIf
    ; ★ THE SUSTAIN CHECK (2026-09-12). Must run BEFORE the pending bail below: a hold that
    ; already fired quietly (persistent or thought) is by construction not pending, so every update for it would
    ; otherwise return below unseen. It never adds to the pending ring, so falling through is
    ; safe - the bail below then returns exactly as it always did.
    if V3SusFind(npc) >= 0
        V3SusCheck(npc, strArg, numArg)
    EndIf
    ; Updates only matter to a session that is WAITING on a dwell delay.
    if V3PendFind(npc) < 0
        return
    EndIf
    ; Scene shutdown is checked here TOO, not just in OnVRTEContact: a scene
    ; that starts while a contact is already pending its dwell produces only
    ; Updates — no new Contact — so the Contact-side check would never see it
    ; and the mod would stay fully armed for the whole scene.
    if ScenesSuppress(npc)
        EnterSceneOff(npc)
        return
    EndIf
    String[] f = V3Split35(strArg)
    V3Dispatch(npc, f, numArg, True)
EndFunction

Function OnVRTEContactEnd(String eventName, String strArg, Float numArg, Form sender)
    Actor npc = sender as Actor
    if !npc
        return
    EndIf
    ; A line this NPC was holding for one update goes out now - her touch ended before any update came.
    if waitActor == npc
        String[] wf = waitF
        Float wd = waitArgDur
        waitActor = None
        if wf.Length > 0
            V3Dispatch(npc, wf, wd, True, False, -1, True)
        EndIf
    EndIf
    V3SusClear(npc)   ; the hold is over - nothing left to upgrade
    V3VoicedSet(npc, 0)
    if kissTrailActor == npc
        kissTrailActor = None   ; the mouth left her - a later kiss is a new act, not the trail
    EndIf
    if V3PendFind(npc) >= 0
        V3PendClear(npc)
        VTLog("[V3] END (pending dwell never met) on " + npc.GetDisplayName() + " total=" + numArg + "s")
    Else
        VTLog("[V3] END session on " + npc.GetDisplayName() + " total=" + numArg + "s")
    EndIf
    ; A session ending is the natural end of a burst — flush the report now
    ; rather than leaving the last few events unaccounted until the next one.
    V3ReportMaybe()
EndFunction

; ================================================================
; ★ THE ADDON BUS — undress (2026-08-23; masturbation left this bus on 2026-09-13 - OnPPBPlayerMasturbation)
; ================================================================
; The AddOn detects; VRTE narrates. Two rules the user set:
;   * While an undress is ARMED, VRTE must not narrate the grab that is doing
;     it — otherwise one physical act is reported twice, once wrongly.
;   * When the piece comes off, THAT is the event worth telling the LLM.
; Arm/End is a PAIR and End fires on cancel too, so an aborted grab cannot
; leave an actor permanently muted.
; ================================================================
Actor  ddzUndressActor  = None      ; the NPC currently being undressed (or None)
Float  ddzUndressAt     = 0.0       ; realtime the arm arrived — stale-guard only
Float  ddzUndressUntil  = 0.0       ; 0 = armed, no End yet · > 0 = the End came: both hands stay muted until this
Bool   ddAddOnLoaded    = False     ; DD SN AddOn.esp in the load order (read in Setup) - its plug events own plugs
Bool   ddDatabaseLoaded = False     ; DD SN Database.esp in the load order (read in Setup) - it ships VRTE_DDZaZ_Native (1.3.1+: WornDeviceName)

; True while an undress runs on this actor, and for the short tail after its End. The 20 s stale guard covers an
; Arm with no End at all: PPB sends none when a pause, a load or a hot-disable drops the pair.
Bool Function DDZIsUndressing(Actor a)
    if ddzUndressActor == None || a != ddzUndressActor
        return False
    EndIf
    Float now = Utility.GetCurrentRealTime()
    if ddzUndressUntil > 0.0
        if now < ddzUndressUntil
            return True
        EndIf
        ddzUndressActor = None
        return False
    EndIf
    if now - ddzUndressAt > 20.0
        ddzUndressActor = None
        VTLog("[GEAR] undress suppression EXPIRED (no End within 20s) - un-muting")
        return False
    EndIf
    return True
EndFunction

; The End came (or, for a DD device, is on its way through the AddOn): keep both hands muted `secs` more - here and
; in the bridge. MEASURED: the grab contacts outlive PPB's End by up to 0.49 s, and the holding hand lets go
; 0.24-0.61 s after it. When the tail runs out, a hand still on her waits its own dwell from that moment.
Function UndressMuteTail(Actor a, Float secs)
    if a == ddzUndressActor
        ddzUndressUntil = Utility.GetCurrentRealTime() + secs
    EndIf
    VRTouchEvents_Native.TakeGestureLanes(a, secs)
EndFunction

; ★★ PPB_GestureUndressArm (2026-09-13, PPB's own event - see Setup). strArg = the capsule under the pulling hand.
; PPB sends it when the SECOND hand grabs the worn piece, so the first hand's grab has already been on her for
; 0.3-0.9 s (measured). The user's ruling: accept that window until PPB can announce the first hand earlier.
Function OnPPBUndressArm(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a == None || a == playerRef
        return
    EndIf
    ddzUndressActor = a
    ddzUndressAt    = Utility.GetCurrentRealTime()
    ddzUndressUntil = 0.0
    v3nUndressArm  += 1
    ; Both hands out of the BRIDGE as well: a Papyrus-only gate dropped the clause but never restarted the hand's
    ; clock, so the hand still gripping her was voiced the moment the piece came off. 20 s = the stale guard.
    VRTouchEvents_Native.TakeGestureLanes(a, 20.0)
    VTLog("[GEAR] UNDRESS ARMED on " + a.GetDisplayName() + " at '" + strArg + "' - both hands muted")
EndFunction

; ★★ PPB_GestureUndressEnd (2026-09-13). strArg = "<name>|<slotMask>|<done>|<isDD>|<capsule>|<class>|<reason>|<sentence>"
; (PPB build 20105 appended reason + sentence), split with the FIXED splitter so a nameless piece keeps its empty field.
; ⚠ done=1 is a PROMISE: PPB sends it ~55 ms BEFORE it pulls the piece off. So the line is not sent here -
;   GearOffQueue waits for the piece to be gone from her. PPB also sends a second End (done=0, reason ripfailed) when a
;   promised removal did not happen; that cancels a queued line.
; ★★ EVERY PIECE, DEVICES INCLUDED (the user, 2026-09-13, correcting the earlier routing): "for the DD and ZaZ equip,
;   they still need to be narrated if equip without the AddOn, it's just that the AddOn will fire specific SkyrimNet
;   action ... do narrate them like normal gears and all 'specific' stuff will come from the AddOn if it's in the
;   modlist". So a DD, ZaZ or Diary of Mine piece comes off under the normal-gear rules, with or without the AddOn. A
;   nameless DD half is named by its class ("the gag"); when the AddOn is loaded its relay (OnDDZUndressEnd) upgrades a
;   queued line to the device's real name. PPB asks the AddOn's removal gate before it announces, so the key rule has
;   already spoken by the time done=1 arrives.
; ⚠ Plugs stay with the AddOn's plug events while the AddOn is loaded (they narrate every route at the interrupt tier);
;   without it a plug is narrated here like anything else.
; ★ fix list 41 (2026-09-13):
;   V15 - PPB sends the End with NO sender when the actor form is gone: the mute is released for whoever was armed
;         (the DLL releases its hand takes the same way), instead of lingering to the 20 s stale guard.
;   V13 - a pull the LOCK refused (reason gate - the removal gate spoke before PPB announced) is told to her like a
;         refused equip: one short-lived event, PPB's field 8 carrying the AddOn's sentence ("This device can only be
;         removed with the Simple Skeleton Key, and will stay on otherwise."). The user: "V13 yes".
;   V4  - R-P1 (the DD SN AddOn's request; the user: "plug removal, it will be in the AddOn"): a piece on the PLUG SLOTS
;         (57 vaginal, 48 anal) is the AddOn's removal while it is loaded, even when PPB gives it no plug class (a Diary
;         of Mine plug). No ordinary gear sits on those slots.
Function OnPPBUndressEnd(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a == None
        if ddzUndressActor != None
            VTLog("[GEAR] undress End with no actor (the actor is gone) - releasing the mute on " + ddzUndressActor.GetDisplayName())
            ddzUndressActor = None
        EndIf
        return
    EndIf
    if a == playerRef
        return
    EndIf
    String[] f = V3Split12(strArg)
    UndressMuteTail(a, 1.5)
    Int mask = f[1] as Int
    String show = f[0]
    if show == "" && f[5] != ""
        show = "the " + VRTouch_TriggerLib.V3DDType(f[5])
    EndIf
    if f[2] != "1"
        if f[6] == "ripfailed"
            GearOffCancel(a, f[0], mask)
        ElseIf f[6] == "gate"
            ; ★ THE DEVICE'S REAL NAME (2026-09-14, the user: "yes, that sound better for LLM awareness"). A DD rendered half has
            ; no name of its own, so PPB's payload says "The Gag"; DD SN Database 1.3.1+ answers with the inventory half's name
            ; (VRTE_DDZaZ_Native.WornDeviceName - their response 2026-09-14). An older Database leaves the native unbound: one
            ; Papyrus error line, "" back, and the line falls back to what PPB sent. The second mention is the class noun
            ; ("the gag"), so a long device name is said once and the line stays pronoun-free.
            String realName = ""
            if ddDatabaseLoaded
                realName = VRTE_DDZaZ_Native.WornDeviceName(a, mask)
            EndIf
            String what = show
            if realName != ""
                what = realName
            EndIf
            if what != ""
                ; string-cache fix 2026-09-15: the old tail assembled `"the " + V3DDType(cls)`,
                ; a SHORT string that the engine's case-insensitive literal cache handed back as
                ; PPB's "The Gag" -> "...but The Gag stayed on.". One long literal cannot collide.
                String pulled = playerRef.GetDisplayName() + " pulled at " + what + " on " + a.GetDisplayName() + ", but the device stayed on."
                if f[7] != ""
                    pulled = pulled + " " + f[7]
                EndIf
                GearRefusedTell(a, pulled, "PULL REFUSED by the lock (name '" + realName + "' from DD SN, PPB sent '" + f[0] + "')")
            EndIf
        EndIf
        VTLog("[GEAR] undress ended on " + a.GetDisplayName() + " with nothing removed - reason '" + f[6] + "' " + f[7])
        return
    EndIf
    if ddAddOnLoaded && (VRTouch_TriggerLib.V3IsPlugClass(f[5]) || Math.LogicalAnd(mask, 134217728) != 0 || Math.LogicalAnd(mask, 262144) != 0)
        VTLog("[GEAR] UNDRESS '" + show + "' cls='" + f[5] + "' slot mask " + mask + " is a plug - the AddOn's plug events own it")
        return
    EndIf
    GearOffQueue(a, f[0], show, mask, f[3] == "1")
EndFunction

; ★★ Q3 - A REFUSED EQUIP (the user, 2026-09-13: "an equip event can fail due to the slot being already used or the
; wrong location. if that happen, an shortliveenvent should be sent to the LLM" and "VRTE will narrate it, it's not
; different from normal gears"). EVERY refused hand equip - plain gear, DD and ZaZ devices alike.
; PPB_GestureEquipRefused (build 20105): "<name>|<slotMask>|<reason>|<blocker>|<isDD>|<class>|<zone>", numArg = hand.
;   reason slot (a worn piece holds its slot) · clothing (a garment or device over the site) · place (held against a
;   body part it does not go on) · refused (asked for, did not go on)
; One short-lived event on HER, keyed per NPC so a retry replaces the last one. Fact only, no pronouns.
; ★ 2026-09-13 (the user): hand gear lines run DURING A SCENE too - "it's only gonna happen if the player's decide to pull
; equipment during a scene, and in this case it will need to be narrated". No modOff / scene gate on any gear sender.
Function OnPPBEquipRefused(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a == None || a == playerRef
        return
    EndIf
    String[] f = V3Split12(strArg)
    String nName = a.GetDisplayName()
    String pName = playerRef.GetDisplayName()
    String item = f[0]
    if item == ""
        item = "a piece of gear"
    EndIf
    String blocker = f[3]
    String reason  = f[2]
    String where = VRTouch_TriggerLib.V3GearZoneOf(f[6], nName)
    String narr = ""
    if reason == "slot"
        if blocker != ""
            narr = pName + " tried to put " + item + " on " + where + ", but " + nName + " already wears " + blocker + " there."
        Else
            narr = pName + " tried to put " + item + " on " + where + ", but something " + nName + " already wears is in the way."
        EndIf
    ElseIf reason == "clothing"
        if blocker != ""
            narr = pName + " tried to put " + item + " on " + where + ", but " + blocker + " is in the way."
        Else
            narr = pName + " tried to put " + item + " on " + where + ", but clothing is in the way."
        EndIf
    ElseIf reason == "place"
        narr = pName + " tried to put " + item + " on " + where + ", but " + item + " does not go there."
    ElseIf blocker != ""
        narr = pName + " tried to put " + item + " on " + nName + ", but " + blocker + " kept " + item + " from going on."
    Else
        narr = pName + " tried to put " + item + " on " + nName + ", but " + item + " did not stay on."
    EndIf
    v3nGearRefused += 1
    GearRefusedTell(a, narr, "REFUSED (" + reason + ", isDD " + f[4] + ", zone '" + f[6] + "')")
EndFunction

; The short-lived event both refusals share - a refused equip and a pull the lock refused (V13). Keyed per NPC: the latest
; attempt replaces the last. Never onto a body that cannot take it in (fix list 41 V7).
Function GearRefusedTell(Actor a, String narr, String tag)
    ; FOMOD "Equip/unequip awareness: off" - no refused-equip and no refused-pull event.
    if !VRTouch_GearGate.IsEnabled()
        return
    EndIf
    String nName = a.GetDisplayName()
    if V3OutCold(a)
        VTLog("[GEAR] " + tag + " on " + nName + " NOT told - dead or unconscious | " + narr)
        return
    EndIf
    if V3LogOnly
        VTLog("[GEAR] " + tag + " WOULD TELL (log-only) " + nName + " | " + narr)
        return
    EndIf
    SkyrimNetApi.RegisterShortLivedEvent("vrte_gear_refused_" + VRTouchEvents_Native.FormIDDec(a), "vrte_gear_refused", \
        narr, "", 120000, a, playerRef)
    VTLog("[GEAR] " + tag + " on " + nName + " -> SHORT-LIVED EVENT | " + narr)
EndFunction

; ================================================================
; ★★ NORMAL GEAR PULLED OFF (2026-09-13, the user's rulings)
; ================================================================
;   * "all gears removal should be a direct narration and follow the 10sec cooldown, except for slot32 gears,
;     which is the main body, which should be an interrupt too. being put bare and naked is a significant event"
;   * a removal that lands inside the cooldown is DROPPED (AskUserQuestion, 2026-09-13)
;   * naked = nothing left on slots 32, 52, 49 and 56
; The removal ring is its OWN (gearCdActor), never the touch clocks: a grope a few seconds earlier must not swallow
; the unequip. A removal line still stamps the touch clocks, so the hand that pulled cannot pile on.
; Fact only, no pronouns.
Actor[]  gearOffActor           ; a removal waiting for the piece to be gone (4 slots) - WIPED every load
Float[]  gearOffDue
String[] gearOffName            ; the worn record's own name - what GetWornForm is matched against ("" for a DD half)
String[] gearOffShow            ; what the line says - a class noun for a nameless DD half, the AddOn's real name if it came
Int[]    gearOffMask
Int[]    gearOffTries
Actor[]  gearCdActor            ; the removal cooldown ring (8 slots) - WIPED every load
Float[]  gearCdAt

Function GearOffQueue(Actor a, String name, String show, Int mask, Bool isDD = False)
    ; FOMOD "Equip/unequip awareness: off" - nothing is queued, so GearOffTick never
    ; confirms and nothing is narrated. The hand-mute and held-armour gates stay live.
    if !VRTouch_GearGate.IsEnabled()
        return
    EndIf
    GearOffPut(a, name, show, mask, Utility.GetCurrentRealTime() + 0.5, 0)
    ScheduleNextUpdate()
EndFunction

; No native calls in here - nothing can interleave while a slot is written.
Function GearOffPut(Actor a, String name, String show, Int mask, Float due, Int tries)
    if gearOffActor.Length < 4 || gearOffTries.Length < 4 \
    || gearOffShow.Length < 4
        gearOffActor = new Actor[4]
        gearOffDue   = new Float[4]
        gearOffName  = new String[4]
        gearOffShow  = new String[4]
        gearOffMask  = new Int[4]
        gearOffTries = new Int[4]
    EndIf
    Int slot = gearOffActor.Find(None)
    if slot < 0
        slot = 0
        Int i = 1
        while i < 4
            if gearOffDue[i] < gearOffDue[slot]
                slot = i
            EndIf
            i += 1
        EndWhile
        VTLog("[GEAR] removal queue full - dropping the check for '" + gearOffShow[slot] + "'")
    EndIf
    gearOffActor[slot] = a
    gearOffDue[slot]   = due
    gearOffName[slot]  = name
    gearOffShow[slot]  = show
    gearOffMask[slot]  = mask
    gearOffTries[slot] = tries
EndFunction

; The AddOn's relay carries a DD device's REAL name (its hold swaps in the inventory half's): upgrade a line still waiting.
Function GearOffRename(Actor a, Int mask, String show)
    if gearOffActor.Length < 4 || gearOffShow.Length < 4 || show == ""
        return
    EndIf
    Int i = 0
    while i < 4
        if gearOffActor[i] == a && gearOffMask[i] == mask
            gearOffShow[i] = show
        EndIf
        i += 1
    EndWhile
EndFunction

; OnUpdate: narrate each announced removal once the piece is really off. Still worn 0.5 s after the End: look again every
; 0.75 s up to 3.5 s (a DD removal is a Papyrus round trip plus DD's settle), then give up silently - PPB's corrective
; End (ripfailed, 2.5 s) normally cancels it first.
Function GearOffTick(Float now)
    if gearOffActor.Length < 4 || gearOffTries.Length < 4 \
    || gearOffShow.Length < 4
        return
    EndIf
    Int i = 0
    while i < 4
        Actor a = gearOffActor[i]
        if a != None && now >= gearOffDue[i]
            String nm    = gearOffName[i]
            String shw   = gearOffShow[i]
            Int    mask  = gearOffMask[i]
            Int    tries = gearOffTries[i]
            ; Claimed BEFORE any native call: a second OnUpdate running while this one yields cannot send it twice.
            gearOffActor[i] = None
            if GearStillWorn(a, nm, mask)
                if tries < 4
                    GearOffPut(a, nm, shw, mask, Utility.GetCurrentRealTime() + 0.75, tries + 1)
                Else
                    v3nGearStayed += 1
                    VTLog("[GEAR] '" + shw + "' is STILL WORN by " + a.GetDisplayName() + " 3.5 s after PPB announced it off - nothing narrated")
                EndIf
            Else
                GearOffSend(a, shw, mask)
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

Float Function GearOffWait(Float now)
    Float w = 999999.0
    if gearOffActor.Length < 4 || gearOffDue.Length < 4
        return w
    EndIf
    Int i = 0
    while i < 4
        if gearOffActor[i] != None
            Float left = gearOffDue[i] - now
            if left < 0.05
                left = 0.05
            EndIf
            if left < w
                w = left
            EndIf
        EndIf
        i += 1
    EndWhile
    return w
EndFunction

; True while any slot of the removed piece still holds a worn item of the same name. Each slot is asked on its own:
; a multi-slot mask would return whatever else overlaps it (a hood on 31 for a 31+42 hat).
Bool Function GearStillWorn(Actor a, String name, Int mask)
    if a == None || mask == 0
        return False
    EndIf
    Int b = 0
    while b < 32
        Int bit = Math.LeftShift(1, b)
        if Math.LogicalAnd(mask, bit) != 0
            Form w = a.GetWornForm(bit)
            if w != None && w.GetName() == name
                return True
            EndIf
        EndIf
        b += 1
    EndWhile
    return False
EndFunction

; What still covers her after the body piece came off, as a readable list - "" when slots 32, 52, 49 and 56 are all
; empty (naked, the user's definition), "?" when something is worn there but has no name to say.
String Function GearLeftOn(Actor a)
    Int[] masks = new Int[4]
    masks[0] = 4            ; 32 body
    masks[1] = 4194304      ; 52
    masks[2] = 524288       ; 49
    masks[3] = 67108864     ; 56
    Form[] seen = new Form[4]
    String[] names = new String[4]
    Int n = 0
    Bool covered = False
    Int i = 0
    while i < 4
        Form w = a.GetWornForm(masks[i])
        if w != None && seen.Find(w) < 0
            seen[i] = w
            covered = True
            String nm = w.GetName()
            if nm != ""
                names[n] = nm
                n += 1
            EndIf
        EndIf
        i += 1
    EndWhile
    if !covered
        return ""
    EndIf
    if n == 0
        return "?"
    EndIf
    String out = names[0]
    Int k = 1
    while k < n
        if k == n - 1
            out = out + " and " + names[k]
        Else
            out = out + ", " + names[k]
        EndIf
        k += 1
    EndWhile
    return out
EndFunction

; Send one confirmed removal (the gates are checked at send time).
Function GearOffSend(Actor a, String name, Int mask)
    String nName = a.GetDisplayName()
    Float  now   = Utility.GetCurrentRealTime()
    String why   = ""
    ; (fix list 41 V7) never onto a dead or knocked-out body - the body piece would be a GLOBAL interrupt + a forced reply.
    ; ★ No scene gate any more (the user, 2026-09-13): a piece pulled off during a scene is narrated.
    if V3OutCold(a)
        why = "she is dead or unconscious"
    EndIf
    String piece = name
    if piece == ""
        piece = "a piece of clothing"
    EndIf
    if why != ""
        VTLog("[GEAR] OFF '" + piece + "' on " + nName + " NOT narrated - " + why)
        return
    EndIf
    String pName = playerRef.GetDisplayName()
    Bool body = (Math.LogicalAnd(mask, 4) == 4)
    if body
        ; ★ The body piece: always an INTERRUPT, past the removal cooldown - "being put bare and naked is a
        ; significant event and should be recognized".
        String left = GearLeftOn(a)
        String narr = pName + " pulled " + piece + " off " + nName + "."
        if left == ""
            narr = pName + " pulled " + piece + " off " + nName + ", leaving " + nName + " naked."
        ElseIf left != "?"
            narr = pName + " pulled " + piece + " off " + nName + ", leaving " + nName + " in only " + left + "."
        EndIf
        GearCdStamp(a, now)     ; stamped FIRST - the SkyrimNet calls below yield
        if V3LogOnly
            VTLog("[GEAR] OFF (body) WOULD FIRE (log-only) on " + nName + " | " + narr)
            return
        EndIf
        ; The cut is GLOBAL, so it runs only when SHE is talking (V3CutIfTalking, 2026-09-15).
        V3CutIfTalking(a, "body piece pulled off")
        SkyrimNetApi.DirectNarration(narr, a, playerRef)
        V3RecordFire(a, True)
        v3nGearOff += 1
        v3nUndressFire += 1
        if left == ""
            v3nGearNaked += 1
        EndIf
        VTLog("[GEAR] OFF (body, slot 32) on " + nName + " left on 32/52/49/56='" + left + "' -> INTERRUPT + DIRECT NARRATION | " + narr)
        return
    EndIf
    if GearCdRecent(a, now)
        v3nGearOffCd += 1
        VTLog("[GEAR] OFF '" + piece + "' on " + nName + " DROPPED - a removal line went out on " + nName + " under " + (GlobalCooldown as Int) + " s ago")
        return
    EndIf
    GearCdStamp(a, now)
    String narr2 = pName + " pulled " + piece + " off " + nName + "."
    if V3LogOnly
        VTLog("[GEAR] OFF WOULD FIRE (log-only) on " + nName + " | " + narr2)
        return
    EndIf
    SkyrimNetApi.DirectNarration(narr2, a, playerRef)
    V3RecordFire(a, False)
    v3nGearOff += 1
    v3nUndressFire += 1
    VTLog("[GEAR] OFF (slot mask " + mask + ") on " + nName + " -> DIRECT NARRATION | " + narr2)
EndFunction

; True when a removal line went out on her less than GlobalCooldown seconds ago. Read-only.
Bool Function GearCdRecent(Actor a, Float now)
    if gearCdActor.Length < 8
        return False
    EndIf
    Int i = gearCdActor.Find(a)
    if i < 0
        return False
    EndIf
    ; A small NEGATIVE age is a stamp written a moment after `now` was read (the handlers yield) - still recent.
    Float age = now - gearCdAt[i]
    return age > -2.0 && age < GlobalCooldown
EndFunction

; Stamp a removal line: her own slot, else an empty one, else the oldest.
Function GearCdStamp(Actor a, Float now)
    if gearCdActor.Length < 8
        gearCdActor = new Actor[8]
        gearCdAt    = new Float[8]
    EndIf
    Int slot = gearCdActor.Find(a)
    if slot < 0
        slot = gearCdActor.Find(None)
    EndIf
    if slot < 0
        slot = 0
        Int i = 1
        while i < 8
            if gearCdAt[i] < gearCdAt[slot]
                slot = i
            EndIf
            i += 1
        EndWhile
    EndIf
    gearCdActor[slot] = a
    gearCdAt[slot]    = now
EndFunction

; strArg = "<piece>|<slotMask>|<done>|<isDD>|<capsule>"
; ═══════════════════════════════════════════════════════════════════════
; ★★ MOVED TO THE ADDON (2026-08-29, the user's ruling - report 29 §0.6k):
; OnDDZPlugInserted/Removed narration, OnDDZDeviceMenuOn/Off, DDZDeviceName,
; DDZPlugWhere and DDZWitness now live in VRTEDD_Controller.psc. The AddOn is
; the mouth for everything its own sinks see; VRTE narrates only the player's
; gesture equip/undress.
;
; ⚠ THE TWO STUBS BELOW ARE PACING, NOT NARRATION. A plug event still stamps
; the INTIMATE cooldown clock so a touch cannot be narrated right on top of a
; plug insertion - the user's prioritization rule ("a boob touch versus a
; soulgem nipple piercing installed"). The AddOn speaks; this only paces.
; ═══════════════════════════════════════════════════════════════════════
Function OnDDZPlugInserted(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a != None && !modOff
        V3RecordFire(a, True)
        v3nPlugIn += 1
    EndIf
EndFunction

Function OnDDZPlugRemoved(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a != None && !modOff
        V3RecordFire(a, True)
        v3nPlugOut += 1
    EndIf
EndFunction

; ★★★ THE INTERRUPT RULE (2026-09-15, the user): "Every single interrupt event we push to SkyrimNet will be interrupt ONLY if
; the NPC's that the interrupt is going to is currently talking. If not, don't do an interrupt. So that if someone else is talking,
; they are not the one getting interrupted. [...] And we do that, for every single one we push, so that only when the NPC that is
; talking is stopping. Including the finger in the mouth."
; SkyrimNet's cut is GLOBAL - it stops whoever is speaking - so it runs only when the speaker IS the NPC the line is about.
; "Talking" = VRTouchEvents.dll's IsTalking, DD SN Database 1.3.9's definition: her voice is playing, she is between two lines of
; one reply, or her reply is still being written. The cut is PurgeDialogue(False) - it stops her line now AND drops what was
; queued behind it, so her old reply cannot play after the reaction line (the call DD SN's gag cut and the choke release make).
; Not talking: nothing is cut; the line that follows is sent exactly as before and waits its turn.
; Every site that used to call TriggerInterruptDialogue / PurgeDialogue calls this instead: the kiss, the finger/touch interrupt
; tier (V3Dispatch), the knockdown and leg sweep, the body piece pulled off, the choke landing at 3 s, the choke release.
Bool Function V3CutIfTalking(Actor a, String what)
    if a == None
        return False
    EndIf
    if !VRTouchEvents_Native.IsTalking(a)
        VTLog("[INTERRUPT] " + what + " on " + a.GetDisplayName() + " - not the one talking, nothing cut")
        return False
    EndIf
    Int cut = SkyrimNetApi.PurgeDialogue(False)
    if cut == 1
        VTLog("[INTERRUPT] " + what + " on " + a.GetDisplayName() + " - was talking, the line was cut mid-word")
    Else
        VTLog("[INTERRUPT] " + what + " on " + a.GetDisplayName() + " - was talking, the reply was dropped before its voice started")
    EndIf
    return True
EndFunction

; ★★ THE PLUG STAMP AT THE ACT ITSELF (2026-09-14, the user: "yes, do the PPB event").
; PPB_GesturePlug is PPB's own edge: "<in|out>|<name>|<class>|<siteMask>|<leftHand>", sent the instant a fingertip extraction
; is granted (after the DD/ZaZ removal gate said yes - a refused pull sends nothing) or an insertion is confirmed (PPB doc 26 §3).
; The AddOn's spoken line (VRTE_DDZaZ_PlugRemoved / PlugInserted above) now arrives 1.5-4.5 s LATER: since DD SN v1.2.7 every
; removal is held 1.5 s so DD's own re-fit flicker is never narrated, and the hold drains on their 3 s poll (their response
; 2026-09-14). Stamping only on their line left that gap open - the finger still at the orifice earned a touch line inside it,
; which their late interrupt then cut. So the INTIMATE clock is stamped HERE, at the act; their line re-stamps when it lands.
; ⚠ Only while the AddOn is loaded: without it nobody narrates a plug pull (the user's ruling 1) and an insertion is VRTE's own
; gear line (OnPPBDeviceEquipped), which stamps for itself.
Function OnPPBGesturePlug(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a == None || a == playerRef || !ddAddOnLoaded
        return
    EndIf
    String[] f = V3Split12(strArg)
    if f[0] != "in" && f[0] != "out"
        return
    EndIf
    V3RecordFire(a, True)
    VTLog("[GEAR] PLUG " + f[0] + " '" + f[1] + "' cls='" + f[2] + "' site=" + f[3] + " on " + a.GetDisplayName()         + " - intimate clock stamped at the act (the AddOn's line follows)")
EndFunction

; ★ 2026-09-13 (afternoon): THE ADDON'S RELAY NARRATES NOTHING. Every piece - DD devices included - is narrated from PPB's
; own End (OnPPBUndressEnd), with or without the AddOn (the user: "do narrate them like normal gears and all 'specific'
; stuff will come from the AddOn"). The relay is read for a DD device only, for two things the AddOn's hold knows:
;   done=1 - the inventory half's REAL name ("Black Leather Ball Strap Gag" instead of "the gag"): a line still waiting
;            for the piece to come off is upgraded to it (GearOffRename)
;   done=0 - DD refused the unlock after PPB announced the pull: the waiting line is dropped
; ⛔ THE EMPTY-NAME FIELD SHIFT (measured 2026-08-30): read with the FIXED splitter - StringUtil.Split drops the empty
; name of a DD half and slides every field left.
Function OnDDZUndressEnd(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a == None || a == playerRef
        return
    EndIf
    String[] f = V3Split12(strArg)
    if f[1] == "" || f[3] != "1"
        return
    EndIf
    Int mask = f[1] as Int
    if f[2] == "1"
        GearOffRename(a, mask, f[0])
    Else
        GearOffCancel(a, "", mask)
    EndIf
EndFunction

; Drop a queued removal line for this NPC - by the worn record's name, or (name "") by the slot mask. PPB's corrective End
; (reason ripfailed) or the AddOn's refused DD unlock said it never came off.
Function GearOffCancel(Actor a, String name, Int mask)
    if gearOffActor.Length < 4 || gearOffName.Length < 4
        return
    EndIf
    Int i = 0
    while i < 4
        if gearOffActor[i] == a && gearOffMask[i] == mask && (name == "" || gearOffName[i] == name)
            gearOffActor[i] = None
            VTLog("[GEAR] queued removal of '" + gearOffShow[i] + "' on " + a.GetDisplayName() + " CANCELLED - it never came off")
        EndIf
        i += 1
    EndWhile
EndFunction

; A fixed 12-field splitter that keeps empty fields in place (StringUtil.Split drops them). Fields past 12 land in [11].
String[] Function V3Split12(String s)
    String[] out = new String[12]
    Int idx = 0
    Int start = 0
    Int slen = StringUtil.GetLength(s)
    while idx < 11
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
        out[11] = StringUtil.Substring(s, start)
    EndIf
    return out
EndFunction

; (OnDDZMasturbation moved to the AddOn 2026-08-29, and on 2026-09-13 the user moved masturbation back into VRTE
;  for good - OnPPBPlayerMasturbation consumes PPB's own event; the AddOn relay and its line are removed.)

; ================================================================
; * A DEVIOUS DEVICE WENT ON - narrated like normal gear (2026-09-13)
; ================================================================
; PPB_GestureDeviceEquipped, consumed DIRECTLY: "<name>|<classSuffix>|<locked>|<quest>|<siteMask>|<slotMask>|<force>".
; PPB sends it instead of GearEquipped for a piece with a Devious class; <name> is the held (inventory) half's name.
; ★ The user, 2026-09-13: "for the DD and ZaZ equip, they still need to be narrated if equip without the AddOn, it's just
;   that the AddOn will fire specific SkyrimNet action, but yes, do narrate them like normal gears and all 'specific'
;   stuff will come from the AddOn if it's in the modlist". So the SAME line and pacing as any gear (GearOnSend), with or
;   without the AddOn. The device-specific wearer line (mechanism, sensation) and the onlooker lines that used to go out
;   here through the AddOn's relay (VRTE_DDZaZ_DeviceEquipped, now unregistered) are the AddOn's to provide.
; ⚠ A plug is still left to the AddOn's own plug event (interrupt tier, every route) while the AddOn is loaded.
Function OnPPBDeviceEquipped(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a == None || a == playerRef
        return
    EndIf
    String[] f = V3Split12(strArg)
    if ddAddOnLoaded && VRTouch_TriggerLib.V3IsPlugClass(f[1])
        VTLog("[GEAR] ON '" + f[0] + "' cls='" + f[1] + "' is a plug - the AddOn's plug event owns it")
        return
    EndIf
    String item = f[0]
    if item == "" && f[1] != ""
        item = "the " + VRTouch_TriggerLib.V3DDType(f[1])
    EndIf
    v3nDevice += 1
    if ddAddOnLoaded && (V3StateDeviceClass(f[1]) || V3StateWornPiece(a, f[5] as Int))
        V3StateDeviceHold(a, item)
    EndIf
    GearOnSend(a, item, f[5] as Int, f[6])
EndFunction

; ★ RULING #2 (the user, 2026-09-13): "sound like a good plan, but only for device with State that change the NPC's
; behavior/answer". The AddOn's DeviceFitted (a persistent event, never spoken) reads the SAME PPB event about one task tick
; after this script does, so an equip line spoken at once can reach the LLM before her context says the gag holds her jaw
; open. While DD SN AddOn.esp is loaded, a device in one of the AddOn's STATE rows waits 0.3 s first; anything else goes at
; once. The rows are the AddOn's kBuiltinKw table (tools/VRTE-DDZaZ-plugin/src/DeviceEquip.cpp): gag · blind · arms · legs ·
; all · deaf. ⚠ zad_DeviousGloves is NOT in it (the AddOn counts a glove only by name) and neither is a collar or a belt.
Bool Function V3StateDeviceClass(String cls)
    if cls == ""
        return False
    EndIf
    return StringUtil.Find(cls, "Gag") == 0 || cls == "Blindfold" || cls == "Hood" || cls == "HeavyBondage" \
        || StringUtil.Find(cls, "Armbinder") == 0 || StringUtil.Find(cls, "Yoke") == 0 || cls == "ElbowTie" \
        || cls == "BondageMittens" || cls == "CuffsFront" || StringUtil.Find(cls, "Boxbinder") >= 0 \
        || cls == "StraitJacket" || StringUtil.Find(cls, "HobbleSkirt") == 0 || cls == "AnkleShackles" \
        || cls == "PonyGear" || cls == "Boots" || cls == "PetSuit"
EndFunction

; The same rows by KEYWORD, on the piece that just went on (every slot bit of its mask, one bit at a time). This is the
; route for ZaZ / Diary of Mine restraints, which carry no DD class, and a backstop for a DD class name not listed above.
Bool Function V3StateWornPiece(Actor a, Int slotMask)
    if a == None || slotMask == 0
        return False
    EndIf
    String kws = ",zad_DeviousGag,zad_DeviousGagLarge,zad_DeviousGagPanel,zad_DeviousGagBit,zad_DeviousGagRing,zad_DeviousGagTape,zad_DeviousGagInflatable,zbfWornGag,DOMWornGag" \
        + ",zad_DeviousBlindfold,zad_DeviousHood,zbfWornBlindfold,DOMWornBlindfold" \
        + ",zad_DeviousHeavyBondage,zad_DeviousArmbinder,zad_DeviousArmbinderElbow,zad_DeviousYoke,zad_DeviousYokeBB,zad_DeviousElbowTie,zad_DeviousBondageMittens,zad_DeviousCuffsFront,zadNG_DeviousBoxbinder,zadNG_DeviousYokeFront,zad_DeviousStraitJacket,zbfWornYoke,zbfEffectNoFighting,DOMWornArmbinder,DOMWornCuffsBack,DOMWornWrist,DOMWornCuffsCrossed,DOMWornYoke" \
        + ",zad_DeviousHobbleSkirt,zad_DeviousHobbleSkirtRelaxed,zad_DeviousAnkleShackles,zad_DeviousPonyGear,zad_DeviousBoots,zbfWornAnkles,zbfEffectSlowMove,DOMWornAnkle" \
        + ",zad_DeviousPetSuit,"
    Form last = None
    Int b = 0
    while b < 32
        Int bit = Math.LeftShift(1, b)
        if Math.LogicalAnd(slotMask, bit) != 0
            Form piece = a.GetWornForm(bit)
            if piece != None && piece != last
                last = piece
                Int n = piece.GetNumKeywords()
                Int k = 0
                while k < n
                    Keyword kw = piece.GetNthKeyword(k)
                    if kw != None && StringUtil.Find(kws, "," + kw.GetString() + ",") >= 0
                        return True
                    EndIf
                    k += 1
                EndWhile
            EndIf
        EndIf
        b += 1
    EndWhile
    return False
EndFunction

Function V3StateDeviceHold(Actor a, String item)
    VTLog("[GEAR] ON '" + item + "' on " + a.GetDisplayName() + " is a state device - line held 0.3 s for the AddOn's DeviceFitted")
    Utility.Wait(0.3)
EndFunction

; ================================================================
; ★★ SCENE SUSPENSION — driven by the scene EDGES (2026-08-24)
; ================================================================
; User: "Make sure our Ostim gate is the same fix that PPB use, as PPB
; discovered that the excitement faction ain't a good scene blocker, there is a
; 'scene start' and 'scene end' value that really work."
;
; ⚠ WHAT WAS WRONG. Scene suppression used to rest entirely on MEMBERSHIP tests
; asked once every half second:
;   * SexLab  - IsInFaction(0x0000E50F), the animating faction. A faction is
;     set by a script at some point during the scene's own startup, so there is
;     a window where the scene is running and the flag is not set yet - and if
;     anything interrupts the teardown it can be left set afterwards.
;   * OStim   - OActor.IsInOStim(a), better, but it only exists if OStim.esp is
;     present AND the OStim patch was actually installed from the FOMOD.
; Neither says anything at the MOMENT the scene begins, which is exactly when a
; touch is most likely to be narrated over the top of it.
;
; ★ The edges are the reliable signal, and they cost nothing: both frameworks
;   announce them as SKSE mod events, so we are told rather than polling.
;   This is what PPB uses (main.cpp SceneEventSink) and it is now what we use.
;
; ⚠ ADDITIVE, NOT A REPLACEMENT. The membership tests stay and are OR-ed with
; the flag. The complaint was FALSE NEGATIVES - scenes that were not blocked -
; so removing a signal could only make that worse. A missed `end` event is
; covered by the expiry below; a missed membership test is covered by the flag.
;
; ⚠ AND IT NOW WORKS WITHOUT EITHER PATCH. The mod events reach the BASE
; install, so a user who never picked the OStim or SexLab option in the FOMOD is
; now covered too. Those patches become belt-and-braces rather than the only
; line of defence.
Bool  v3SceneFlag = False           ; a scene edge said "started"
Float v3SceneAt   = 0.0             ; realtime of that edge - expiry only

; ⚠ THE EXPIRY IS A BACKSTOP, NOT A TIMER. If an `end` event is ever missed -
; a CTD mid-scene, a save-load, a framework that forgets - the flag would
; otherwise mute this NPC forever. 20 minutes is far longer than any scene and
; far shorter than "forever".
Bool Function V3InScene(Actor npc)
    if v3SceneFlag
        if Utility.GetCurrentRealTime() - v3SceneAt < 1200.0
            return True
        EndIf
        v3SceneFlag = False
        VTLog("[V3] scene flag EXPIRED (no end event within 20 min) - un-suppressing")
    EndIf
    return VRTouch_SexLabGate.IsInScene(npc) || VRTouch_SexLabGate.IsInScene(playerRef) \
        || VRTouch_OStimGate.IsInScene(npc)  || VRTouch_OStimGate.IsInScene(playerRef)
EndFunction

Function OnV3SceneStart(String eventName, String strArg, Float numArg, Form sender)
    if !v3SceneFlag
        VTLog("[V3] SCENE START ('" + eventName + "') - touch narration suspended")
    EndIf
    v3SceneFlag = True
    v3SceneAt   = Utility.GetCurrentRealTime()
EndFunction

Function OnV3SceneEnd(String eventName, String strArg, Float numArg, Form sender)
    if v3SceneFlag
        VTLog("[V3] SCENE END ('" + eventName + "') - touch narration restored")
    EndIf
    v3SceneFlag = False
EndFunction

; ================================================================
; * ORDINARY GEAR WENT ON (2026-08-23)
; ================================================================
; strArg = "<name>|<slotMask>|<force>" - PPB_GestureGearEquipped, consumed DIRECTLY since 2026-09-13 (it used to
; arrive only as the AddOn's VRTE_DDZaZ_GearEquipped rename, i.e. never without DD SN AddOn.esp). PPB sends it
; 1.2 s after the piece went on, once it checked the piece is really worn.
;
; User: "the last thing we miss is normal gear equip... A normal persistentEvent
; to the NPC we give it to. Normal neutral tone as usual, we don't tell NPC how
; they feel or how to react, we just tell them what is happening."
;
; So: ONE event, ONE recipient. No onlooker line - a bystander seeing someone
; handed a tunic is not worth a slot in anyone's context window, and persistent
; events are budgeted (NpcThoughts.yaml eventHistoryCount: 35).
;
; No tier ladder either: it is always Persistent. Being dressed is a STATE she
; should know about later, not a moment that needs a reaction now - and a plain
; equip that INTERRUPTED would be intolerable by the third piece of an outfit.
;
; PPB decides what counts as "ordinary": a DD-scripted device carries a class and goes out as PPB_GestureDeviceEquipped
; (OnPPBDeviceEquipped) instead, so the two events never both fire for one item.
; ★ 2026-09-13 (afternoon, the user): ZaZ / Diary of Mine restraints (<ordinary> 0 since PPB build 20105) are narrated
; HERE like any gear, with or without the AddOn - "all 'specific' stuff will come from the AddOn if it's in the modlist".
; The AddOn's relay (VRTE_DDZaZ_GearEquipped) is no longer listened to.
Function OnPPBGearEquipped(String eventName, String strArg, Float numArg, Form sender)
    Actor a = sender as Actor
    if a == None || a == playerRef
        return
    EndIf
    String[] f = V3Split12(strArg)
    if f[1] == ""
        return
    EndIf
    ; <ordinary> 0 = a ZaZ / Diary of Mine restraint (PPB build 20105); the AddOn's DeviceFitted reads it too (ruling #2).
    if ddAddOnLoaded && f[3] == "0" && V3StateWornPiece(a, f[1] as Int)
        V3StateDeviceHold(a, f[0])
    EndIf
    GearOnSend(a, f[0], f[1] as Int, f[2])
EndFunction

; One equip line, for every piece. Statement of fact and nothing else: what went on, and where. No verb of feeling, no
; reaction cue - report 19 §1, and the user: "we don't tell NPC how they feel or how to react".
; ★ 2026-09-13: pronoun-free now - "<P> just put Hide Boots on Carmella's feet." (it read "...on Carmella. It sits on
; their feet.") via V3GearOnNamed; a slot it cannot place gives "<P> just put <item> on <N>."
; Pacing unchanged: DirectNarration once per GlobalCooldown per NPC (V3DevNarrReady), else a persistent event.
; ★ THE FORCE GRADE (the user, 2026-09-13: "yes, we want it. just add it to the equip, it's one word in the LLM prompt").
; PPB's <force> (GearEquipped field 2, DeviceEquipped field 6) is graded from the gesture's peak press depth: 0 gentle,
; 1 firm, 2 forced. ★ The user (2026-09-13): "gently and firmly, just no description for normal equip, so it make more
; sense" -> 0 "gently put", 1 (the ordinary press) "put", 2 "firmly put". A physical fact about the press, not a feeling.
; No field (an older PPB) = "put".
Function GearOnSend(Actor a, String item, Int slotMask, String force = "")
    ; FOMOD "Equip/unequip awareness: off" - no equip line.
    if !VRTouch_GearGate.IsEnabled()
        return
    EndIf
    if item == ""
        item = "a piece of gear"
    EndIf
    String how = " put "
    if force == "0"
        how = " gently put "
    ElseIf force == "2"
        how = " firmly put "
    EndIf
    String narr = playerRef.GetDisplayName() + how + item + " " \
        + VRTouch_TriggerLib.V3GearOnNamed(slotMask, a.GetDisplayName()) + "."
    ; V7 (fix list 41): a dead or knocked-out NPC is told nothing (she cannot hear it; the same gate as every touch line).
    if V3OutCold(a)
        VTLog("[GEAR] ON NOT narrated - " + a.GetDisplayName() + " is dead or unconscious | " + narr)
        return
    EndIf
    if V3LogOnly
        VTLog("[GEAR] ON WOULD FIRE (log-only) slot=" + slotMask + " on " + a.GetDisplayName() + " | " + narr)
        return
    EndIf
    if V3DevNarrReady(a)
        SkyrimNetApi.DirectNarration(narr, a, playerRef)
        ; V10 (fix list 41): stamp the touch clock like GearOffSend, so a hand still resting on the collar it just
        ; closed does not add a touch line 0.2 s after this one.
        V3RecordFire(a, False)
    else
        SkyrimNetApi.RegisterPersistentEvent(narr, a, playerRef)
    EndIf
    v3nGearEquip += 1
    VTLog("[GEAR] ON slot=" + slotMask + " on " + a.GetDisplayName() + " | " + narr)
EndFunction

; ================================================================
; V3Dispatch — the single policy funnel for Contact + Update.
; fromUpdate=True means we are re-testing a pending dwell wait (stay
; quiet while still short; fire once the duration crosses the delay).
;
; ★★ 2026-09-13 — ONE LINE PER NPC FOR EVERYTHING TOUCHING HER (the user's ruling).
; VRTouchEvents.dll sends up to FOUR clauses, one per source lane (right hand · left hand · the player's
; head · the player's genital) - payload layout in V3Split35. The user: "if both hand, genital and head all
; touch at the same time ... VRTE simply see all four and publish that information", as ONE combined line,
; the loudest tier winning. Before this, the head and the genital shared the right hand's slot in the bridge
; and the loser was silently dropped.
;   * each clause runs its OWN gates (key, undress, plug, grab gate, combat hit, plausibility, hover, the
;     kiss mute) - a failing clause is dropped, never the whole event (a choke arm still takes it all)
;   * VOICED vs FRESH (v3VoicedMask): a lane that already went out this session is CONTEXT - it is named
;     again, but only FRESH lanes (not yet voiced, or the one that escalated) decide the dwell, the tier and
;     the cooldown. So a late arrival is judged on its own, and an old line is never re-sent because
;     something else joined.
;   * a FRESH clause waits its OWN dwell on its own lane clock (DUR); until it is ready it is NOT named, and
;     she stays pending so the next update re-tests it
;   * ESC ("1") belongs to clause 0 alone - the bridge puts the lane that escalated there
;   * the tier is the loudest FRESH READY clause: Interrupt > Speak > Thought > Persistent (per clause the
;     old precedence holds: Persistent, then Thought, then Interrupt, then Speak)
;   * private if ANY named clause is private; a clause from the player's MOUTH always is (user)
;   * arousal from the named clause with the highest baseline
; ================================================================
Function V3Dispatch(Actor npc, String[] f, Float dur, Bool fromUpdate, Bool sustain = False, Int sustainK = -1, Bool noWait = False)
    String npcName = npc.GetDisplayName()

    ; ★ MALE UPDATE (2026-08-23): resolve the touched actor's sex ONCE. PPB's contact carries no sex
    ; field, and PPB itself resolves sex exactly this way. Only V3MapKey consumes it.
    Int isMale = 0
    ActorBase npcBase = npc.GetLeveledActorBase()
    if npcBase && npcBase.GetSex() == 0
        isMale = 1
    EndIf

    String[] cW     = new String[4]
    String[] cSrc   = new String[4]
    String[] cName  = new String[4]
    String[] cPart  = new String[4]
    String[] cSub   = new String[4]
    Int[]    cDep   = new Int[4]
    Float[]  cDist  = new Float[4]
    Float[]  cDur   = new Float[4]
    String[] cKey   = new String[4]
    Int[]    cArm   = new Int[4]
    String[] cCloth = new String[4]
    Float[]  cDelay = new Float[4]
    Bool[]   cUse   = new Bool[4]
    Bool[]   cGrab  = new Bool[4]
    Bool[]   cMouth = new Bool[4]
    Bool[]   cReady = new Bool[4]
    Bool[]   cFresh = new Bool[4]
    Bool[]   cEsc   = new Bool[4]
    Bool[]   cName2 = new Bool[4]    ; named in the line

    ; ★ PLAYER GENITAL SOURCE — THE SLOT-52 GATE IS PPB'S, NOT OURS (2026-08-23). PPB tears the genital
    ; wand down whenever the player is not exposed, so a GENITAL clause only ever arrives when he is.
    ; ⛔ VRTE once carried its own GetWornForm(52) gate here and it was EXACTLY INVERTED (the schlong lives
    ; on the SKIN, which GetWornForm cannot see) - it dropped 100% of genital contacts. Do not re-add it.
    ; The counters are diagnostics: 0 while touching means the fault is upstream in PPB.
    Int presentMask = 0
    Int k = 0
    while k < 4
        Int b = 3 + k * 8
        if f[b + 1] != ""
            cW[k]    = f[b]
            cSrc[k]  = f[b + 1]
            cName[k] = f[b + 2]
            cPart[k] = f[b + 3]
            cSub[k]  = f[b + 4]
            if f[b + 5] != ""
                cDep[k] = f[b + 5] as Int
            EndIf
            if f[b + 6] != ""
                cDist[k] = f[b + 6] as Float
            EndIf
            if f[b + 7] != ""
                cDur[k] = f[b + 7] as Float
            EndIf
            cUse[k]   = True
            cGrab[k]  = (cSrc[k] == "GRAB")
            cMouth[k] = VRTouch_TriggerLib.V3MouthSource(cSrc[k], cName[k])
            presentMask = Math.LogicalOr(presentMask, V3LaneBit(cW[k]))
            if cSrc[k] == "GENITAL"
                v3nGenSource += 1
            ElseIf cMouth[k]
                v3nMouthSource += 1
            EndIf
        EndIf
        k += 1
    EndWhile
    ; ESC "1" = clause 0 escalated (the bridge puts the causing lane first). It belongs to that clause ALONE.
    cEsc[0] = (f[0] == "1") && cUse[0]
    ; Voiced lanes persist through the session: the BRIDGE decides whether a lane that left and came back is new (it
    ; sends a JOIN) or the same contact (it puts it back silently - final verify 2026-09-13).
    Int voiced = V3VoicedGet(npc)
    ; ★ A JOIN (ESC "2") puts the lane that came (back) in clause 0 - the bridge only sends it for a lane absent from
    ; its previous event. So clause 0 is NEW even if a stale voiced bit survived (verify 2026-09-13: a hand that lifted
    ; and came back onto her breast was treated as already said).
    if f[0] == "2" && cUse[0]
        voiced = Math.LogicalAnd(voiced, Math.LogicalXor(15, V3LaneBit(cW[0])))
        ; V2 (fix list 41): write the cleared bit BACK. Every Update after the JOIN re-reads the ring, so a joined lane
        ; still under its dwell on the JOIN itself was read as already said on the next Update and never spoken.
        V3VoicedSet(npc, voiced)
    EndIf
    ; The kiss trail belongs to a mouth still on her: once the head lane is gone, it is over.
    if kissTrailActor == npc && Math.LogicalAnd(presentMask, 4) == 0
        kissTrailActor = None
    EndIf

    ; ★★ THE KISS MUTE (2026-09-12), per CLAUSE and per PART since 2026-09-13. While PPB has a kiss up on her
    ; (PPB_MouthLips ...|HEAD) and for 3 s after it ends, a HEAD-source clause on her FACE (lips, face, ear,
    ; the mouth keys) is part of the kiss KissSpeak already voiced - PPB: the HEAD:mouth contacts flicker between
    ; her lips and nose through one kiss. Only that clause is dropped; her other contacts still speak, and a
    ; mouth on her neck or chest is not the flicker, so it is never muted.
    ; ★ THE KISS TRAIL (user, 2026-09-13): a MOUTH clause muted here keeps her PENDING, so the next update
    ; re-tests the mouth once it moves off her face (lips -> neck without pulling back), and that line passes
    ; the clocks KissSpeak stamped, once (kissTrailActor, valid 10 s after the last muted pass or until the
    ; session ends).
    Bool mouthMuted = False
    if KissMutes(npc)
        k = 0
        while k < 4
            if cUse[k] && cSrc[k] == "HEAD"
                String headKey = VRTouch_TriggerLib.V3MapKey(cSub[k], cPart[k], isMale)
                if VRTouch_TriggerLib.V3IsFaceFamily(headKey) || VRTouch_TriggerLib.V3IsMouthKey(headKey)
                    cUse[k] = False
                    ; ANY muted head clause keeps her pending - PPB's single HEAD contact can read "face" for a
                    ; moment when the front of the head box wins, and that must not end the trail (review).
                    mouthMuted = True
                    if cMouth[k]
                        kissTrailActor = npc
                        kissTrailUntil = Utility.GetCurrentRealTime() + 10.0
                    EndIf
                    VTLog("[V3] HEAD contact muted - part of the kiss on " + npcName + " (" + cPart[k] + ")")
                EndIf
            EndIf
            k += 1
        EndWhile
        if !cUse[0]
            cEsc[0] = False
        EndIf
    EndIf

    ; ================================================================
    ; ★ CHOKE ARMING (PART B1) — the choke ARMS from PPB, on ANY clause.
    ; ================================================================
    ; PPB reports a throat grab cleanly as sub="Neck" + src="GRAB" on the FRONT NECK capsule only
    ; (PPB v2.0 slot 7 child 1, ~2.5u proud so a frontal grab lands on it; a grab from behind lands on
    ; "neck / throat" and narrates as an ordinary neck hold). ★ 2026-09-13: tested on every clause - a
    ; mouth or a breast outranks the neck, and a kiss must not stop a choke from arming.
    ; Only the ARMING lives here; TickChoke owns liveness, every milestone, the passout, the KO slot and
    ; the kill. The scene test is duplicated because StartChoke is a heavy state change that would shatter a
    ; SexLab / OStim scene; the GRAB-SUPPRESSION GATE too ("No Follower Grab" patch; a stub in the base mod).
    Int ck = -1
    k = 0
    while k < 4 && ck < 0
        if cUse[k] && cGrab[k] && cSub[k] == "Neck" && VRTouch_TriggerLib.V3IsNeckFrontPart(cPart[k])
            ck = k
        EndIf
        k += 1
    EndWhile
    if ck >= 0
        if chokeActive && npc == chokeActor
            ; Already choking THIS actor: refresh the liveness stamp and drop the throat clause only - the
            ; choke gag below still handles everything else, including the free-hand thought (review).
            chokeLastContact = Utility.GetCurrentRealTime()
            cUse[ck] = False
            if ck == 0
                cEsc[0] = False
            EndIf
        Else
            if VRTouch_GrabGate.ShouldSuppressGrab(npc)
                VTLog("[V3] CHOKE ARM SUPPRESSED (grab gate) on " + npcName)
            ElseIf V3InScene(npc)
                VTLog("[V3] CHOKE ARM SUPPRESSED (scene gate) on " + npcName)
            ElseIf V3LogOnly
                VTLog("[V3] CHOKE-CANDIDATE (log-only — would arm StartChoke) on " + npcName + " dur=" + dur)
            ElseIf !chokeActive
                ; Seed the hand latch and the PPB liveness stamp from THIS clause before arming; StartChoke's
                ; HIGGS probes refine chokeIsLeft if they resolve. chokeLastContact must be fresh at t=0 or the
                ; 1s-settle liveness test would end the choke instantly. Log the RESULT, not the intent.
                chokeIsLeft      = (cW[ck] == "L")
                chokeLastContact = Utility.GetCurrentRealTime()
                StartChoke(npc)
                if chokeActive && chokeActor == npc
                    v3nChokeArm += 1
                    VTLog("[V3] CHOKE ARMED (PPB Neck/GRAB) on " + npcName + " dur=" + dur)
                Else
                    VTLog("[V3] CHOKE ARM REJECTED by StartChoke (re-arm lockout) on " + npcName + " dur=" + dur)
                EndIf
            EndIf
            ; (chokeActive on a DIFFERENT actor: leave the running choke alone - one choke at a time.)
            V3PendClear(npc)
            return
        EndIf
    EndIf

    ; ★ 2026-09-13 (fix list 41 V1): NOTHING IS NARRATED ONTO A BODY THAT CANNOT ANSWER. A DirectNarration forces a
    ; spoken reply, and SkyrimNet picks the addressed NPC even when she is out cold (measured: "it picked THE VICTIM").
    ; PPB keeps publishing contacts on anything short of true death, and VRTE's own KO keeps her Paralysis + Unconscious.
    ; ⚠ PLACED AFTER THE CHOKE ARMING ON PURPOSE: a throat grab on an NPC already knocked out must still arm the
    ; kill-run (StartChoke's isKillRun) - a guard at the top of V3Dispatch would have silently removed it.
    if V3OutCold(npc)
        if !fromUpdate
            VTLog("[V3] NOT narrated - " + npcName + " is dead or unconscious")
        EndIf
        V3PendClear(npc)
        return
    EndIf

    ; ================================================================
    ; PER-CLAUSE GATES — a clause that fails is DROPPED; the others carry on.
    ; ================================================================
    Int alive = 0
    k = 0
    while k < 4
        if cUse[k]
            String clauseKey = VRTouch_TriggerLib.V3MapKey(cSub[k], cPart[k], isMale)
            cKey[k] = clauseKey
            if clauseKey == ""
                v3nUnmapped += 1
                ; Shout a NEW unknown name once, loudly — PPB's sub-region vocabulary moved.
                if V3NoteUnmapped(cSub[k])
                    VTLog("[V3] ★ UNMAPPED SUB-REGION '" + cSub[k] + "' (capsule '" + cPart[k] + "') — no V3MapKey row. " \
                        + "Every contact on it is being DROPPED; add it to V3MapKey + V3PartOf.")
                ElseIf !fromUpdate
                    VTLog("[V3] UNMAPPED sub=" + cSub[k] + " part=" + cPart[k] + " — dropped")
                EndIf
                cUse[k] = False
            ElseIf (cW[k] == "R" || cW[k] == "L") && DDZIsUndressing(npc)
                ; ★ UNDRESS SUPPRESSION (2026-08-23; 2026-09-13 EVERY hand clause, not only GRAB): the two hands
                ; doing the undress are not a grope, and a palm or a finger of the same pull is not one either.
                ; The removal line says what happened. The bridge takes both hand lanes too (TakeGestureLanes) -
                ; this catches a payload that was already on its way.
                v3nUndressGate += 1
                VTLog("[V3] SUPPRESSED (undress in progress): " + clauseKey + " src=" + cSrc[k] + " on " + npcName)
                cUse[k] = False
            ElseIf cSrc[k] == "OBJECT" && VRTouch_TriggerLib.V3PlugSiteOfKey(clauseKey) == "" && V3HeldArmor(cW[k])
                ; ★ A HELD PIECE OF ARMOUR IS NEVER A TOUCH (user, 2026-09-13: an equip must not "end up as a
                ; contact event"). It is on its way to being worn - PPB_GestureGearEquipped says so if it goes on -
                ; or it fails and PPB says nothing yet. This replaces the 3 s dwell FLOOR, which a fumbled or
                ; refused equip outlasted (measured refused holds 2.2-4.2 s) and a DD inventory half (slot mask 0)
                ; never met at all. Plug sites keep their narration: the plug events are the AddOn's.
                v3nGearHeld += 1
                if !fromUpdate
                    VTLog("[V3] SUPPRESSED (a held armour piece, not a touch): " + clauseKey + " name=" + cName[k] + " on " + npcName)
                EndIf
                cUse[k] = False
            ElseIf V3PlugGated(npc, clauseKey)
                v3nPlugGate += 1
                VTLog("[V3] SUPPRESSED (orifice plugged): " + clauseKey + " src=" + cSrc[k] + " on " + npcName)
                cUse[k] = False
            ElseIf cGrab[k] && VRTouch_GrabGate.ShouldSuppressGrab(npc)
                ; Grab-suppression gate (parity with V2's OnObjectGrabbed) - touches are unaffected.
                v3nGrabGate += 1
                VTLog("[V3] SUPPRESSED (grab gate): " + clauseKey + " on " + npcName)
                cUse[k] = False
            ElseIf (cSrc[k] == "WEAPON" || cSrc[k] == "OBJECT") && VRTouchEvents_Native.WasHitRecently(npc, 1.5)
                ; ★ THE COMBAT GATE: a blade that is taking her health off is a fight, not a touch. Hands
                ; and GRAB are exempt (V2's behaviour). Returns False without the DLL -> fails toward narrating.
                v3nCombatHit += 1
                VTLog("[V3] SUPPRESSED (real hit, not a touch): " + clauseKey + " src=" + cSrc[k] + " on " + npcName)
                cUse[k] = False
            Else
                ; V3ArmorState, NOT GetArmorState(V3SlotKey(...)): the face family needs the 44->30 helmet
                ; chain and the interior ladder must probe the pelvis slots only (49->52).
                Int clauseArm = V3ArmorState(npc, clauseKey)
                cArm[k]   = clauseArm
                cCloth[k] = GetLastArmorName()
                if VRTouch_TriggerLib.V3PlausibilityDrop(clauseKey, clauseArm)
                    ; interior contact through armor = a detection artefact
                    v3nPlausibility += 1
                    VTLog("[V3] PLAUSIBILITY DROP key=" + clauseKey + " arm=" + clauseArm + " (interior contact through armor) on " + npcName)
                    cUse[k] = False
                ElseIf VRTouch_TriggerLib.V3RequiresPenetration(clauseKey) && cDist[k] >= 0.0
                    ; hover is not "inside": a positive distU is OUTSIDE the capsule (PPB reports hover as
                    ; contact by design, and the palate sits about that far behind the cheek)
                    v3nHoverDrop += 1
                    VTLog("[V3] HOVER DROP key=" + clauseKey + " part='" + cPart[k] + "' dist=" + cDist[k] \
                        + " (>=0 means OUTSIDE the capsule — not inside) on " + npcName)
                    cUse[k] = False
                Else
                    alive += 1
                EndIf
            EndIf
        EndIf
        k += 1
    EndWhile
    if !cUse[0]
        cEsc[0] = False   ; the clause that escalated was dropped: nothing left carries its ESC (review)
    EndIf
    if alive == 0
        if mouthMuted
            V3PendAdd(npc)   ; the kiss trail
        Else
            V3PendClear(npc)
        EndIf
        return
    EndIf

    ; ================================================================
    ; FRESH vs VOICED, and each FRESH clause's own dwell (on its lane clock).
    ; ================================================================
    Bool anyFreshReady   = False
    Bool anyFreshUnready = False
    Int  firstK = -1
    k = 0
    while k < 4
        if cUse[k]
            ; A sustain upgrade makes only the HELD clause fresh (verify 2026-09-13): the others keep their own rules.
            Bool susK = sustain && k == sustainK
            cFresh[k] = susK || cEsc[k] || Math.LogicalAnd(voiced, V3LaneBit(cW[k])) == 0
            Float dly = VRTouch_TriggerLib.V3GetDelay(cKey[k], cGrab[k], cArm[k]) * DelayMultiplier
            ; ★ The genital source overrides the body part's dwell (user, 2026-08-23), and the player's
            ; mouth takes the same flat dwell (2026-09-12): hard enough to land at all without a hip's 4s.
            if cSrc[k] == "GENITAL" || cMouth[k]
                dly = VRTouch_TriggerLib.V3GenSourceDelay() * DelayMultiplier
            EndIf
            ; (The 2026-08-26 held-armour dwell FLOOR is gone: since 2026-09-13 a held armour piece is dropped at
            ;  the gates above - V3HeldArmor.)
            cDelay[k] = dly
            if cFresh[k]
                cReady[k] = cEsc[k] || susK || cDur[k] >= dly
                if cReady[k]
                    anyFreshReady = True
                Else
                    anyFreshUnready = True
                    if firstK < 0
                        firstK = k
                    EndIf
                EndIf
                ; Named when it is ready; a fresh clause still inside its dwell waits its own turn.
                cName2[k] = cReady[k]
            Else
                cName2[k] = True    ; already voiced: named again as context
            EndIf
        EndIf
        k += 1
    EndWhile
    if !anyFreshReady
        if anyFreshUnready || mouthMuted
            if !fromUpdate && firstK >= 0
                v3nPending += 1
                VTLog("[V3] PENDING key=" + cKey[firstK] + " dur=" + cDur[firstK] + " < delay=" + cDelay[firstK] \
                    + " (" + alive + " clause(s)) on " + npcName)
            EndIf
            V3PendAdd(npc)
        Else
            V3PendClear(npc)   ; nothing new on her - every clause here was already voiced
        EndIf
        return    ; a later VRTE_ContactUpdate re-tests with fresh durations
    EndIf
    ; Keep re-testing while a fresh clause is still short of its dwell, or the kiss trail is owed.
    Bool keepPending = anyFreshUnready || mouthMuted
    V3PendClear(npc)
    if keepPending
        V3PendAdd(npc)
    EndIf

    ; --- Gates, in order: scene, choke gag, cooldown ---
    if V3InScene(npc)
        v3nSceneGate += 1
        VTLog("[V3] SUPPRESSED (scene gate) on " + npcName)
        return
    EndIf
    if chokeActive && npc == chokeActor
        v3nChokeGag += 1
        ; ★ THE FREE-HAND EXCEPTION (from the deleted FireGrabHold). A choked NPC is gagged, but if the
        ; player's OTHER hand grabs her while the first is on her throat she still NOTICES it, as one
        ; unvoiced thought - stated as bare fact.
        if !modOff
            k = 0
            while k < 4
                if cUse[k] && cFresh[k] && cReady[k] && cGrab[k] && (cW[k] == "L") != chokeIsLeft
                    String freeNarr = playerRef.GetDisplayName() + "'s free hand takes hold of " \
                        + npcName + VRTouch_TriggerLib.V3PartOf(cSub[k], cPart[k]) \
                        + VRTouch_TriggerLib.V3PreciseOf(cSub[k], cPart[k]) + "."
                    SkyrimNetApi.GenerateNPCThought(npc, freeNarr)
                    V3VoicedSet(npc, Math.LogicalOr(voiced, V3LaneBit(cW[k])))
                    VTLog("[V3] CHOKE free-hand thought on " + npcName + " | " + freeNarr)
                    return
                EndIf
                k += 1
            EndWhile
        EndIf
        VTLog("[V3] SUPPRESSED (choke gag) on " + npcName)
        return
    EndIf

    ; ================================================================
    ; THE TIER — the loudest FRESH READY clause decides (Interrupt > Speak > Thought > Persistent).
    ; ================================================================
    ;   * Gear never interrupts (user, 2026-08-26) - ESC sits INSIDE that gate.
    ;   * THE FOURTH TIER (2026-08-23): armored "Though" rows become PERSISTENT - context, no reaction.
    ;   * Per clause the OLD precedence holds (review 2026-09-13): Persistent, then Thought, then Interrupt -
    ;     an escalation onto a thought row stays a thought, exactly as before.
    ;   * THE ARMOR FLOOR: a genital-source contact (2026-08-23) and a mouth contact (2026-09-12) always at
    ;     least SPEAK, whatever she wears. They still never force an interrupt on their own.
    ;   * THE SUSTAIN UPGRADE (2026-09-12): the second, louder fire of a quiet hold = plain Speak.
    Int d = -1
    Int bestRank = 0
    k = 0
    while k < 4
        if cUse[k] && cFresh[k] && cReady[k]
            Bool mayInt = (cSrc[k] != "OBJECT" && cSrc[k] != "WEAPON")
            Bool kInt = mayInt && (cEsc[k] || VRTouch_TriggerLib.V3IsInterrupting(cKey[k], cArm[k], cGrab[k], cSrc[k]))
            Bool kTho = VRTouch_TriggerLib.V3IsThought(cKey[k], cArm[k], cGrab[k])
            Bool kPer = False
            if !kInt && VRTouch_TriggerLib.V3IsPersistent(cKey[k], cGrab[k], cArm[k])
                kPer = True
                kTho = False
            EndIf
            if cSrc[k] == "GENITAL" || cMouth[k]
                kPer = False
                kTho = False
            EndIf
            if sustain && k == sustainK
                kInt = False
                kPer = False
                kTho = False
            EndIf
            Int rank = 3
            if kPer
                rank = 1
            ElseIf kTho
                rank = 2
            ElseIf kInt
                rank = 4
            EndIf
            if rank > bestRank
                bestRank = rank
                d = k
            EndIf
        EndIf
        k += 1
    EndWhile
    Bool interrupting = (bestRank == 4)
    Bool asThought    = (bestRank == 2)
    Bool asPersistent = (bestRank == 1)
    ; An escalation passes the clocks whoever decides the tier (verify 2026-09-13: a fresh escalated clause was held
    ; back with a louder clause that was on its clock). Only clause 0 can carry it.
    Bool escLine = cEsc[0] && cReady[0]
    Bool susD    = sustain && d == sustainK

    ; ★ The kiss trail passes the clocks once: a FRESH READY mouth clause OFF HER FACE (lips -> neck), on the NPC the
    ; kiss mute last dropped a mouth clause from. A mouth still on her face after the mute is the flicker, not a trail.
    Bool trail = False
    if kissTrailActor == npc && !mouthMuted && Utility.GetCurrentRealTime() < kissTrailUntil
        k = 0
        while k < 4
            if cUse[k] && cMouth[k] && cFresh[k] && cReady[k] \
            && !VRTouch_TriggerLib.V3IsFaceFamily(cKey[k]) && !VRTouch_TriggerLib.V3IsMouthKey(cKey[k])
                trail = True
            EndIf
            k += 1
        EndWhile
    EndIf

    ; ★ ONE LINE, NOT TWO (verify 2026-09-13; ruling A): contacts that begin together but have different dwells used to
    ; split into two lines, the second one then held by the clock the first had just stamped. When another FRESH clause
    ; will reach its dwell by the next update (~1 s), wait for it and send both at once. Never for an interrupt, an
    ; escalation, a sustain upgrade or the kiss trail - those go now.
    ; ⚠ BOUNDED (final verify 2026-09-13): at most ONE wait per NPC per 1.5 s, one NPC waiting at a time, and a Papyrus
    ;   deadline (WaitTick, 1.2 s) or her session End re-sends the held line if no update came - a ready line is never lost
    ;   and never stalled behind a contact whose clock keeps restarting.
    Float nowW = Utility.GetCurrentRealTime()
    Bool mayWait = !noWait && (waitActor == None || (waitActor == npc && nowW - waitAt >= 1.5))
    if mayWait && bestRank < 4 && !escLine && !susD && !trail
        Bool soon = False
        k = 0
        while k < 4
            if cUse[k] && cFresh[k] && !cReady[k] && (cDelay[k] - cDur[k]) <= 1.05
                soon = True
            EndIf
            k += 1
        EndWhile
        if soon
            waitActor  = npc
            waitF      = f
            waitArgDur = dur
            waitAt     = nowW
            V3PendAdd(npc)
            VTLog("[V3] WAIT one update so " + cKey[d] + " and a contact about to ripen go out as one line on " + npcName)
            ScheduleNextUpdate()
            return
        EndIf
    EndIf

    ; ================================================================
    ; THE GATE — two clocks, and thoughts are exempt entirely.
    ; ================================================================
    ; "Though" rows are NEVER gated by us (unvoiced; SkyrimNet throttles them itself, 60s per NPC).
    ; Speak rows consult the NORMAL clock. Speak (Interrupt) rows consult the INTIMATE clock ONLY - they
    ; cut through an ordinary reaction, but never through their own.
    ; ★ ESCALATIONS BYPASS EVERY CLOCK (report 16 §16.3 #4): the bridge sends ESC "1" only when a lane's
    ; priority STRICTLY rises above its own last named value, capped (uterus 100) - a few times per session at
    ; most. A lane JOIN (ESC "2") is new information but NOT an escalation: it passes no clock.
    ; ★ A sustain upgrade bypasses the clock too (its own quiet fire stamped it 2-6s ago).
    ; ★ 2026-09-13: a line held back by the clock keeps her PENDING - a fresh contact is re-tested once the clock
    ;   runs out instead of being lost for the rest of the session (review: a kiss joining a hand was lost).
    if !asThought && !escLine && !susD && !trail && V3IsOnCooldown(npc, interrupting)
        V3PendAdd(npc)
        ; Counted and logged once per contact, not once per retry second (verify 2026-09-13).
        if !fromUpdate
            v3nCooldown += 1
            String cdWhich = "normal"
            if interrupting
                cdWhich = "intimate"
            EndIf
            VTLog("[V3] SUPPRESSED (" + cdWhich + " cooldown, re-tested on each update until it runs out): " + cKey[d] + " on " + npcName)
        EndIf
        return
    EndIf

    ; --- Compose: the named clauses, in the bridge's order ---
    Int erect = -1
    String privStr = "0"
    Int arK = d
    Float arBest = -1.0
    Int firedBits = 0
    Bool[] cNamed = new Bool[4]
    Int named = 0
    k = 0
    while k < 4
        ; ★ A mouth or genital contact is ALWAYS a direct narration (ruling D): already-voiced ones are not repeated as
        ; context inside a THOUGHT or a PERSISTENT line (verify 2026-09-13).
        Bool quietSkip = bestRank < 3 && !cFresh[k] && (cMouth[k] || cSrc[k] == "GENITAL")
        if cUse[k] && cName2[k] && !quietSkip
            cNamed[k] = True
            named += 1
            if cFresh[k] && cReady[k]
                firedBits = Math.LogicalOr(firedBits, V3LaneBit(cW[k]))
                ; Arousal is judged on what is NEW in this line, not on an old kiss named again as context.
                Float ab = VRTouch_TriggerLib.V3GetArousal(cKey[k], cGrab[k], cArm[k])
                if ab > arBest
                    arBest = ab
                    arK = k
                EndIf
            EndIf
            if cKey[k] == "male_genitals"
                ; carries erection state (PPB GENBEND via the native; -1 = unknown -> clause omitted)
                erect = VRTouchEvents_Native.GetErectionLevel(npc)
            EndIf
            if VRTouch_TriggerLib.V3IsPrivate(cKey[k], cArm[k]) || cMouth[k]
                privStr = "1"
            EndIf
        EndIf
        k += 1
    EndWhile
    String narr = VRTouch_TriggerLib.V3NarrationMulti(npcName, playerRef.GetDisplayName(), \
        cW, cSrc, cName, cPart, cSub, cDep, cDist, cKey, cArm, cCloth, cNamed, erect, d, cDur[d])
    ; V3EffectiveDepth, not the raw depth — must match the verb inside the narration.
    String intensity = VRTouch_TriggerLib.V3IntensityVerb(cDist[d], \
        VRTouch_TriggerLib.V3EffectiveDepth(cSub[d], cDep[d]))
    ; Every fresh clause that went out is voiced from here on. RE-READ the ring and merge (verify 2026-09-13): this
    ; dispatch yielded on natives, and another one for her may have voiced a lane in the meantime.
    V3VoicedSet(npc, Math.LogicalOr(V3VoicedGet(npc), firedBits))
    if waitActor == npc
        waitActor = None   ; the line this NPC was waiting to combine went out
    EndIf
    if trail
        kissTrailActor = None
    EndIf

    ; --- Shadow mode: log-only while V3LogOnly is set (the cooldown is still recorded) ---
    if V3LogOnly
        String lmode = "SPEAK"
        if asThought
            lmode = "THOUGHT"
        ElseIf asPersistent
            lmode = "PERSISTENT"
        EndIf
        VTLog("[V3] WOULD FIRE (" + lmode + ") key=" + cKey[d] + " arm=" + cArm[d] + " esc=" + f[0] + " priv=" + privStr \
            + " | " + cW[d] + "/" + cSrc[d] + " part=" + cPart[d] + " sub=" + cSub[d] + " dep=" + cDep[d] + " dist=" + cDist[d] \
            + " dur=" + cDur[d] + " | named=" + named + " skel=" + f[1] + " cloth=" + cCloth[d] + " intensity=" + intensity \
            + " | " + narr)
        if !asThought
            V3RecordFire(npc, interrupting)
        EndIf
        return
    EndIf

    ; ================================================================
    ; --- LIVE dispatch — the four delivery tiers ---
    ; ================================================================
    ; Each is a DIRECT SkyrimNet call (TriggerManager stopped evaluating events on this load order,
    ; 2026-08-08). Audience = DirectNarration's targetActor: the player -> private, None -> public.
    if asPersistent
        ; PERSISTENT: context, no reaction. No SkyrimNet-side throttle and a finite rendered history, so it
        ; consults AND stamps the NORMAL clock like a Speak.
        v3nPersistent += 1
        SkyrimNetApi.RegisterPersistentEvent(narr, npc, playerRef)
        V3RecordFire(npc, False)
        V3SusArm(npc, cKey[d], cDelay[d], cW[d], cDur[d])   ; ...and watch the hold: if it lasts, it speaks up
        VTLog("[V3] PERSISTENT key=" + cKey[d] + " arm=" + cArm[d] + " part='" + cPart[d] + "' named=" + named + " on " + npcName + " | " + narr)
    ElseIf asThought
        ; A thought stamps NEITHER clock: brushing an arm must never silence a grope.
        v3nThought += 1
        SkyrimNetApi.GenerateNPCThought(npc, narr)
        V3SusArm(npc, cKey[d], cDelay[d], cW[d], cDur[d])
        VTLog("[V3] THOUGHT key=" + cKey[d] + " part='" + cPart[d] + "' named=" + named + " on " + npcName + " | " + narr)
    Else
        ; SPEAK (INTERRUPT): cut the line she is saying right now - ONLY when she is the one talking (V3CutIfTalking,
        ; 2026-09-15: the finger in her mouth, a bare breast grab... never cut somebody else's line).
        String mode = "SPEAK"
        if interrupting
            if V3CutIfTalking(npc, "touch '" + cKey[d] + "'")
                mode = "SPEAK-INTERRUPT"
            Else
                mode = "SPEAK-INTERRUPT-TIER (not talking, nothing cut)"
            EndIf
        EndIf
        if susD
            mode = "SPEAK-SUSTAIN"
            v3nSustain += 1
            Debug.Trace("[V3] SUSTAIN FIRED key=" + cKey[d] + " dur=" + cDur[d] + " priv=" + privStr + " on " + npcName + " | " + narr)
        EndIf
        if privStr == "1"
            SkyrimNetApi.DirectNarration(narr, npc, playerRef)
        Else
            SkyrimNetApi.DirectNarration(narr, npc, None)
        EndIf
        v3nSpoken += 1
        ; An interrupt stamps BOTH clocks; an ordinary Speak stamps only the normal one.
        V3RecordFire(npc, interrupting)
        ; part logged RAW beside the finished narration: a casing or naming bug stays diagnosable.
        VTLog("[V3] " + mode + " key=" + cKey[d] + " esc=" + f[0] + " priv=" + privStr \
            + " part='" + cPart[d] + "' named=" + named + " on " + npcName + " | " + narr)
    EndIf
    if trail
        Debug.Trace("[V3] KISS TRAIL narrated on " + npcName + " | " + narr)
    EndIf
    V3ReportMaybe()

    ; Optional arousal — the existing pipeline, from the named clause with the highest baseline.
    MaybeArousal(npc, VRTouch_TriggerLib.V3ArousalKey(cKey[arK]), cGrab[arK], cArm[arK], narr, \
        VRTouch_TriggerLib.V3GetArousal(cKey[arK], cGrab[arK], cArm[arK]))
EndFunction

; ================================================================
; ★ THE PLUGGED-ORIFICE GATE (user, 2026-08-26), now a helper so each clause can ask it (2026-09-13).
; ================================================================
; "if a plug is installed, disable that orifice VRTE reaction for insertion ... it's the used mechanism to
; removing the plug anyway, so the removal will be the events firing." The orifice is physically occupied,
; so an interior verdict there is the extraction gesture or a detection artefact - never a penetration.
; ⚠ TESTED BY SLOT, NOT BY NAME: 57 = vaginal, 48 = anal (DD's own map, zadLibs.psc:665/679), and DD's double
;   plugs occupy both. ⚠ It deliberately does NOT touch V3SlotChain (that would hand every plugged-orifice
;   contact to V3PlausibilityDrop, including the removal gesture).
; ⛔ SLOT ALONE IS NOT ENOUGH (2026-08-26): `aaaDDShoulder` (Dark Dreams.esl) sits on 57. The slot says the
;   orifice is OCCUPIED; the keyword says by a PLUG. Both, or no gate. Fails SAFE on a keywordless plug.
Bool Function V3PlugGated(Actor npc, String key)
    String plugSite = VRTouch_TriggerLib.V3PlugSiteOfKey(key)
    if plugSite == ""
        return False
    EndIf
    Int plugMask = 262144                        ; slot 48 - anal
    Keyword siteKw = kwPlugAnal
    if plugSite == "vaginal"
        plugMask = 134217728                     ; slot 57 - vaginal
        siteKw   = kwPlugVaginal
    EndIf
    Bool wornIsPlug = False
    if siteKw != None && npc.WornHasKeyword(siteKw)
        wornIsPlug = True
    ElseIf kwPlugAny != None && npc.WornHasKeyword(kwPlugAny)
        wornIsPlug = True
    EndIf
    return wornIsPlug && npc.GetWornForm(plugMask) != None
EndFunction

; ================================================================
; V3 helpers
; ================================================================

; ================================================================
; V3ReportReset / V3ReportMaybe — the session diagnostic.
; ================================================================
; One line, at most once a minute, listing every outcome the dispatcher
; reached.  It exists so a user can answer "why was it quiet?" from the log
; alone.  The counters are cumulative for the session and are NOT reset by
; the report — a running total is a measurement, a per-window count that
; keeps resetting is not (PPB's ledger lesson: a capped diagnostic that
; reaches its cap has stopped being a measurement).
Function V3ReportReset()
    v3nContacts     = 0
    v3nSpoken       = 0
    v3nThought      = 0
    v3nPending      = 0
    v3nUnmapped     = 0
    v3nPlausibility = 0
    v3nCooldown     = 0
    v3nSceneGate    = 0
    v3nChokeGag     = 0
    v3nGrabGate     = 0
    v3nCombatHit    = 0
    v3nChokeArm     = 0
    v3nPlugGate     = 0
    v3nPlugOut      = 0
    v3nAftermath    = 0
    v3nPlugIn       = 0
    v3nMenuOn       = 0
    v3nMenuOff      = 0
    v3ReportAt      = 0.0
EndFunction

Function V3ReportMaybe()
    Float now = Utility.GetCurrentRealTime()
    if now < v3ReportAt
        return
    EndIf
    v3ReportAt = now + 60.0
    VTLog("[V3] REPORT contacts=" + v3nContacts \
        + " spoken=" + v3nSpoken + " thought=" + v3nThought \
        + " | pending=" + v3nPending + " unmapped=" + v3nUnmapped \
        + " implausible=" + v3nPlausibility \
        + " | suppressed: cooldown=" + v3nCooldown + " scene=" + v3nSceneGate \
        + " chokegag=" + v3nChokeGag + " grabgate=" + v3nGrabGate \
        + " combathit=" + v3nCombatHit + " plugged=" + v3nPlugGate + " plugOut=" + v3nPlugOut + " after=" + v3nAftermath + " plugIn=" + v3nPlugIn + " menuOn=" + v3nMenuOn + " menuOff=" + v3nMenuOff \
        + " | persistent=" + v3nPersistent + " sustain=" + v3nSustain + " genSource=" + v3nGenSource + " mouthSource=" + v3nMouthSource + " hoverDrop=" + v3nHoverDrop \
        + " | undress: arm=" + v3nUndressArm + " gate=" + v3nUndressGate + " fire=" + v3nUndressFire \
        + " masturbation=" + v3nMasturbation + " device=" + v3nDevice \
        + " gear=" + v3nGearEquip + " gearOff=" + v3nGearOff + " naked=" + v3nGearNaked + " offCd=" + v3nGearOffCd \
        + " offStayed=" + v3nGearStayed + " heldArmour=" + v3nGearHeld + " refused=" + v3nGearRefused \
        + " fx=" + v3nDeviceEffect \
        + " | chokesArmed=" + v3nChokeArm)
EndFunction

; True the FIRST time this PPB sub-region name is seen as unmapped.  An
; unmapped name means PPB has renamed or added a sub-region and our key
; table has drifted — a real bug, but one that would otherwise scroll past
; at 4 Hz.  Shout it once, count the rest.
Bool Function V3NoteUnmapped(String sub)
    if v3UnmappedSeen.Length < 8 || sub == ""
        return False
    EndIf
    Int i = 0
    while i < 8
        if v3UnmappedSeen[i] == sub
            return False
        EndIf
        if v3UnmappedSeen[i] == ""
            v3UnmappedSeen[i] = sub
            return True
        EndIf
        i += 1
    EndWhile
    return False    ; ring full — 8 distinct unknown names is already a shout
EndFunction

; ----------------------------------------------------------------
; V3ChokeStamp — the PPB liveness witness for the choke.
; ----------------------------------------------------------------
; A src=GRAB contact means HIGGS is actively grabbing THIS actor with that
; hand (PpbTouchAPI.h kSourceGrab), read straight out of PPB's own frame
; data.  That makes it an INDEPENDENT witness to the two the choke already
; polls (HiggsVR.GetGrabbedObject on both hands) — and the only one that is
; certain to survive the 15s passout ragdoll, which is where the HIGGS pair
; has never been tested.  Actor-level, exactly as report 18 §3c specified:
; any grabbed capsule counts, because she ragdolls and the hand leaves the
; neck capsule.
;
; It can only ever EXTEND a hold, never invent one: no grip, no GRAB
; source, no stamp.  The HIGGS test is already actor-level too (it accepts
; a grab on any part of her), so this adds no new class of "still held".
Function V3ChokeStamp(Actor npc, String[] f)
    if !chokeActive || npc != chokeActor
        return
    EndIf
    ; ★ 2026-09-13: any of the four clauses (SRC at 4 / 12 / 20 / 28 - see V3Split35).
    if f[4] == "GRAB" || f[12] == "GRAB" || f[20] == "GRAB" || f[28] == "GRAB"
        chokeLastContact = Utility.GetCurrentRealTime()
    EndIf
EndFunction

; Split the 35-field VRTE strArg on '|'.  Base-SKSE StringUtil only
; (no PapyrusUtil Split dependency at compile time).  Missing tail
; fields stay "" — new String[35] elements default to empty.
; NOTE: Substring(s, start, 0) means "to end of string", so empty
; fields (p == start) must be skipped explicitly, not sliced.
; ★★ 2026-09-13 LAYOUT (VRTouchEvents.dll PpbBridge.cpp — change BOTH together):
;   0 ESC ("1" escalation · "2" a source lane joined) · 1 SKEL · 2 N clauses
;   then 4 clauses of 8 fields at 3 / 11 / 19 / 27: W SRC NAME PART SUB DEP DIST DUR (unused = "")
; ⛔ StringUtil.Split would DROP empty fields and shift every column (the 2026-08-30 "536870912" bug).
String[] Function V3Split35(String s)
    String[] out = new String[35]
    Int idx = 0
    Int start = 0
    Int slen = StringUtil.GetLength(s)
    while idx < 34
        Int p = StringUtil.Find(s, "|", start)
        if p < 0
            ; Malformed / short payload — dump the remainder into the
            ; current field and leave the rest empty.
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
        out[34] = StringUtil.Substring(s, start)
    EndIf
    return out
EndFunction

; Pending (delay-wait) ring.  Presence in the ring = "this actor's
; session has been seen but its dwell delay is not yet met"; the next
; VRTE_ContactUpdate re-tests it with the fresh duration.
Int Function V3PendFind(Actor a)
    if a == None || v3PendActor.Length < 16
        return -1
    EndIf
    Int i = 0
    while i < 16
        if v3PendActor[i] == a
            return i
        EndIf
        i += 1
    EndWhile
    return -1
EndFunction

Function V3PendAdd(Actor a)
    if a == None || v3PendActor.Length < 16
        return
    EndIf
    if V3PendFind(a) >= 0
        return
    EndIf
    Int i = 0
    while i < 16
        if v3PendActor[i] == None
            v3PendActor[i] = a
            return
        EndIf
        i += 1
    EndWhile
    ; Full — steal slot 0 (16 simultaneously-touched actors is unrealistic).
    v3PendActor[0] = a
EndFunction

Function V3PendClear(Actor a)
    Int idx = V3PendFind(a)
    if idx >= 0
        v3PendActor[idx] = None
    EndIf
EndFunction

; ================================================================
; ★ THE SUSTAIN RING (2026-09-12) - the user's two-fire design
; ================================================================
; "The gate becomes an entry for the event." A contact that fires QUIETLY - PERSISTENT
; (context, no reaction) or THOUGHT (unvoiced) - is remembered with an upgrade point of
; TWICE its dwell, capped at 6 seconds:
;     1s-gated -> speaks at a 2s hold    2s-gated -> 4s    3s or longer -> 6s
; If the same hold is still on the same body part when the session reaches that point, it
; fires ONCE more as a plain DirectNarration carrying the REAL duration, and clears.
;
; WHY: a fleeting brush and a hand left resting were indistinguishable. Both went out as one
; quiet event, and the "held for N seconds" in the text was frozen at the moment it fired.
;
; ⚠ Measured on the SESSION duration (numArg) - the same clock the dwell uses - so the points
;   mean "total hold", exactly as the user stated them.
; ★ BOTH quiet tiers arm it (the user, 2026-09-12: "the fire will work on a clothed NPC
;   too, same rule as armor"). Clothed and bare contacts mostly go out as THOUGHTS, and a
;   hand resting on a clothed arm is exactly the fleeting-vs-resting case this exists for.
;   ⚠ That includes the bare THOUGHT rows (arms, hands, feet) - same tier, same rule.

Int Function V3SusFind(Actor a)
    if a == None || v3SusActor.Length < 16
        return -1
    EndIf
    Int i = 0
    while i < 16
        if v3SusActor[i] == a
            return i
        EndIf
        i += 1
    EndWhile
    return -1
EndFunction

Function V3SusArm(Actor a, String key, Float delay, String laneW = "", Float firedDur = 0.0)
    ; FOMOD "Subtle contact": the sustain upgrade never arms, so a hold that went out
    ; quietly stays quiet and every contact keeps the tier the matrix gives it.
    if !VRTouch_SustainGate.IsEnabled()
        return
    EndIf
    if a == None || v3SusActor.Length < 16
        return
    EndIf
    if v3SusW.Length < 16
        v3SusW = new String[16]
    EndIf
    Float upAt = delay * 2.0
    if upAt > 6.0
        upAt = 6.0
    EndIf
    ; ★ A quiet fire that went out LATE (it waited on the clock - the retry) keeps the same gap to its upgrade,
    ; measured from when it actually fired (verify 2026-09-13: it used to upgrade on the very next update).
    if firedDur > delay && firedDur + (upAt - delay) > upAt
        upAt = firedDur + (upAt - delay)
    EndIf
    Int idx = V3SusFind(a)
    if idx < 0
        idx = 0
        Bool placed = False
        while idx < 16 && !placed
            if v3SusActor[idx] == None
                placed = True
            Else
                idx += 1
            EndIf
        EndWhile
        if !placed
            idx = 0   ; full - 16 NPCs held at once is unrealistic; steal slot 0
        EndIf
    EndIf
    v3SusActor[idx] = a
    v3SusKey[idx]   = key
    v3SusAt[idx]    = upAt
    v3SusW[idx]     = laneW
    Debug.Trace("[V3] SUSTAIN armed key=" + key + " dwell=" + delay + " -> speaks at " + upAt + "s on " + a.GetDisplayName())
EndFunction

Function V3SusClear(Actor a)
    Int idx = V3SusFind(a)
    if idx >= 0
        v3SusActor[idx] = None
        v3SusKey[idx]   = ""
    EndIf
EndFunction

; ★ THE ONE-LINE WAIT's deadline (2026-09-13): if no update for the waiting NPC fired her line within 1.2 s, send it now.
Function WaitTick(Float now)
    if waitActor == None || now < waitAt + 1.2
        return
    EndIf
    Actor a = waitActor
    String[] wf = waitF
    Float wd = waitArgDur
    waitActor = None
    if a != None && !a.IsDead() && wf.Length > 0
        Debug.Trace("[V3] WAIT deadline - sending the held line on " + a.GetDisplayName())
        V3Dispatch(a, wf, wd, True, False, -1, True)
    EndIf
EndFunction

Float Function WaitWait(Float now)
    if waitActor == None
        return 999999.0
    EndIf
    Float w = (waitAt + 1.2) - now
    if w < 0.05
        w = 0.05
    EndIf
    return w
EndFunction

; ★ THE VOICED-LANES RING (2026-09-13) - see its declaration. Bit per lane letter: R 1 · L 2 · H 4 · G 8.
Int Function V3LaneBit(String w)
    if w == "R"
        return 1
    ElseIf w == "L"
        return 2
    ElseIf w == "H"
        return 4
    ElseIf w == "G"
        return 8
    EndIf
    return 0
EndFunction

Int Function V3VoicedGet(Actor a)
    if a == None || v3VoicedActor.Length < 16
        return 0
    EndIf
    Int i = v3VoicedActor.Find(a)
    if i < 0
        return 0
    EndIf
    return v3VoicedMask[i]
EndFunction

Function V3VoicedSet(Actor a, Int mask)
    if a == None
        return
    EndIf
    if v3VoicedActor.Length < 16 || v3VoicedAt.Length < 16
        v3VoicedActor = new Actor[16]
        v3VoicedMask  = new Int[16]
        v3VoicedAt    = new Float[16]
    EndIf
    Float now = Utility.GetCurrentRealTime()
    Int i = v3VoicedActor.Find(a)
    if i < 0
        if mask == 0
            return
        EndIf
        i = v3VoicedActor.Find(None)
        if i < 0
            ; Full: a session dropped silently (door, loading screen, scene) never sends an End, so its entry lingers -
            ; take the OLDEST entry rather than always slot 0 (verify 2026-09-13).
            i = 0
            Int j = 1
            while j < 16
                if v3VoicedAt[j] < v3VoicedAt[i]
                    i = j
                EndIf
                j += 1
            EndWhile
        EndIf
        v3VoicedActor[i] = a
    EndIf
    v3VoicedMask[i] = mask
    v3VoicedAt[i]   = now
    if mask == 0
        v3VoicedActor[i] = None
    EndIf
EndFunction

; Called from OnVRTEContactUpdate for an armed actor. Consumes the entry the moment the hold
; reaches its point, whatever the checks below decide - at most ONE upgrade per hold.
Function V3SusCheck(Actor npc, String strArg, Float dur)
    Int idx = V3SusFind(npc)
    if idx < 0
        return
    EndIf
    String susKey = v3SusKey[idx]
    Float  susAt  = v3SusAt[idx]
    String susW   = ""
    if v3SusW.Length >= 16
        susW = v3SusW[idx]
    EndIf
    String[] f = V3Split35(strArg)
    ; ★ 2026-09-13: the point is measured on the HELD clause's own clock (its lane DUR), not the session's -
    ; a hand that joined a long session would otherwise pass its point on the very next update (review).
    ; Re-resolve the part that lane is on NOW. A hand that slid from her arm to her hip must never be narrated
    ; as still resting on the arm, and a different hand on the same part is not the same hold.
    Int isMale = 0
    ActorBase npcBase = npc.GetLeveledActorBase()
    if npcBase && npcBase.GetSex() == 0
        isMale = 1
    EndIf
    Int heldK = -1
    String nowKey = ""
    Int k = 0
    while k < 4 && heldK < 0
        Int b = 3 + k * 8
        if f[b + 1] != "" && (susW == "" || f[b] == susW)
            String laneKey = VRTouch_TriggerLib.V3MapKey(f[b + 4], f[b + 3], isMale)
            if nowKey == ""
                nowKey = laneKey
            EndIf
            if laneKey == susKey
                heldK = k
            EndIf
        EndIf
        k += 1
    EndWhile
    if heldK < 0
        V3SusClear(npc)
        Debug.Trace("[V3] SUSTAIN dropped - the " + susW + " hold moved from " + susKey + " to '" + nowKey + "' by " + dur + "s on " + npc.GetDisplayName())
        return
    EndIf
    Float heldDur = f[3 + heldK * 8 + 7] as Float
    if heldDur < susAt
        return    ; still a hold, not yet a long one
    EndIf
    V3SusClear(npc)
    Debug.Trace("[V3] SUSTAIN point reached key=" + susKey + " at " + dur + "s (point " + susAt + "s) on " + npc.GetDisplayName())
    ; The FULL pipeline, so the upgrade is composed, gated (scene, choke, grab, plug...) and
    ; addressed exactly like any other contact - forced to plain Speak, past the dwell wait
    ; and past the cooldown.
    V3Dispatch(npc, f, dur, True, True, heldK)
EndFunction

; V3 per-NPC cooldown ring — same semantics as IsOnNpcCooldown /
; RecordCdFire but on V3's OWN arrays, so the shadow run never
; disturbs V2's pacing (and vice versa).  Escalations and
; V3IsInterrupting keys bypass this check at the call site.
; Is this actor gated?  `intimate` picks WHICH clock is consulted:
;   intimate = False -> the normal clock.  Ordinary contact waits its turn.
;   intimate = True  -> the INTIMATE clock ONLY.  The normal clock is
;                       deliberately not read, so an interrupt cuts straight
;                       through an ordinary reaction — but still cannot spam
;                       itself.
Bool Function V3IsOnCooldown(Actor a, Bool intimate = False)
    if a == None || v3CdActor.Length < 16 || v3CdIntimateTime.Length < 16
        return False
    EndIf
    Int i = 0
    while i < 16
        if v3CdActor[i] == a
            Float stamp = v3CdTime[i]
            if intimate
                stamp = v3CdIntimateTime[i]
            EndIf
            ; Negative age = a stamp from an earlier game launch: expired (see Setup's arousal note).
            Float cdAge = Utility.GetCurrentRealTime() - stamp
            return cdAge >= 0.0 && cdAge < GlobalCooldown
        EndIf
        i += 1
    EndWhile
    return False
EndFunction

; Stamp the clocks after a fire.  An interrupt stamps BOTH (she has just
; reacted, so an ordinary touch must not pile on); an ordinary fire stamps
; only the normal clock, leaving intimate contact free to cut in at once.
Function V3RecordFire(Actor a, Bool intimate = False)
    if a == None || v3CdActor.Length < 16 || v3CdIntimateTime.Length < 16
        return
    EndIf
    Float now = Utility.GetCurrentRealTime()
    Int i = 0
    while i < 16
        if v3CdActor[i] == a
            v3CdTime[i] = now
            if intimate
                v3CdIntimateTime[i] = now
            EndIf
            return
        EndIf
        i += 1
    EndWhile
    i = 0
    while i < 16
        if v3CdActor[i] == None
            v3CdActor[i] = a
            v3CdTime[i]  = now
            ; A fresh slot must NOT inherit a zeroed intimate clock as
            ; "15s ago" — 0.0 reads as long-expired, which is correct for a
            ; non-intimate fire and is overwritten immediately for an
            ; intimate one.
            v3CdIntimateTime[i] = 0.0
            if intimate
                v3CdIntimateTime[i] = now
            EndIf
            return
        EndIf
        i += 1
    EndWhile
    ; All slots full — evict oldest (lowest v3CdTime).
    Int oldestIdx = 0
    Float oldestTime = v3CdTime[0]
    i = 1
    while i < 16
        if v3CdTime[i] < oldestTime
            oldestTime = v3CdTime[i]
            oldestIdx  = i
        EndIf
        i += 1
    EndWhile
    v3CdActor[oldestIdx]        = a
    v3CdTime[oldestIdx]         = now
    v3CdIntimateTime[oldestIdx] = 0.0
    if intimate
        v3CdIntimateTime[oldestIdx] = now
    EndIf
EndFunction

; (DDZAftermath and OnDDZDeviceEffect - vibration, shock, climax, cast, trip -
;  MOVED to the AddOn: VRTEDD_Controller.psc, 2026-08-29. The pronoun helpers
;  below STAY - they are Global and the AddOn calls them.)

; ═══ THE EQUIP-ACKNOWLEDGEMENT COOLDOWN (2026-08-30) ═══════════════════════
; True at most once per GlobalCooldown REAL seconds per NPC (15 until 2026-09-13). Dressing someone is a BURST -
; collar, cuffs, boots, belt inside a few seconds - and one spoken
; acknowledgement for the burst is what was asked for. The rest still land as
; persistent context, so nothing is lost from the LLM's picture of her; it just
; is not spoken four times over.
; ⚠ Its own 16-slot ring, mirroring v3CdActor's shape and reusing V3CdSlot's
; find-or-claim idea, so the contact cooldowns are untouched.
Actor[] v3DevNarrActor
Float[] v3DevNarrAt

Bool Function V3DevNarrReady(Actor a)
    if a == None
        return False
    EndIf
    if v3DevNarrActor.Length < 16
        v3DevNarrActor = new Actor[16]
        v3DevNarrAt    = new Float[16]
    EndIf
    Float now = Utility.GetCurrentRealTime()
    Int i = 0
    while i < 16
        if v3DevNarrActor[i] == a
            ; Negative age = a stamp from an earlier game launch: expired.
            ; ★ 2026-09-13: GlobalCooldown (10 s) instead of a literal 15 - the user brought the cooldown to 10 s
            ; ("15 can be really long") and ruled gear follows "the 10sec cooldown".
            if (now - v3DevNarrAt[i]) >= 0.0 && (now - v3DevNarrAt[i]) < GlobalCooldown
                return False
            EndIf
            v3DevNarrAt[i] = now
            return True
        EndIf
        i += 1
    EndWhile
    ; not in the ring - claim a free slot, else the oldest
    Int free = -1
    Int oldest = 0
    i = 0
    while i < 16
        if v3DevNarrActor[i] == None && free < 0
            free = i
        EndIf
        if v3DevNarrAt[i] < v3DevNarrAt[oldest]
            oldest = i
        EndIf
        i += 1
    EndWhile
    Int use = free
    if use < 0
        use = oldest
    EndIf
    v3DevNarrActor[use] = a
    v3DevNarrAt[use]    = now
    return True
EndFunction
