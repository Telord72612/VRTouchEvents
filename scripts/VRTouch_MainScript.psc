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
Float Property GlobalCooldown  = 15.0  Auto
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
Bool   chokeFiredThought7   = False  ; 7s choke panic-thought pushed to victim?
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
Float[] koHpAtKO         ; Health at KO time — an external heal (potion OR spell) raising it wakes them
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
    ; Vanilla Restoration heal-spell keyword (tags Healing, Healing
    ; Hands, Grand Healing, Close Wounds, etc. MGEFs).  Used by the
    ; choke passout recovery: any NPC-targeted heal spell wakes them.
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
    ; (koActor already sized, koHpAtKO None) gets it.  -1 disables the HP-rise
    ; wake for any slot occupied before this update (those fall back to the
    ; wake timer / heal-spell keyword), so no false wake on load.
    if koHpAtKO.Length < 10
        koHpAtKO = new Float[10]
        Int kh = 0
        while kh < 10
            koHpAtKO[kh] = -1.0
            kh += 1
        EndWhile
    EndIf
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
    arousalEnabled = ((Game.GetModByName("OSLAroused.esp") != 255) || (Game.GetModByName("SexLabAroused.esm") != 255)) && VRTouch_ArousalGate.IsEnabled()
    if arousalCdActor.Length < 16
        arousalCdActor = new Actor[16]
        arousalCdTime  = new Float[16]
    EndIf
    arousalPendingActor = None

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
    chokeLastContact    = 0.0
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

    ; V3 dispatcher rings (preserved across loads, like cdActor).
    if v3CdActor.Length < 16
        v3CdActor = new Actor[16]
        v3CdTime  = new Float[16]
    EndIf
    ; ⚠ v3CdIntimateTime is allocated INDEPENDENTLY, not inside the block
    ; above.  On a save made before the two-tier cooldown existed, v3CdActor
    ; is already sized 16, so that guard is false and this array would stay
    ; None forever — every V3IsOnCooldown/V3RecordFire call would then bail
    ; on its length check and the gate would silently never apply.
    ; Same pattern, same reason, as koHpAtKO above.
    if v3CdIntimateTime.Length < 16
        v3CdIntimateTime = new Float[16]
    EndIf
    if v3PendActor.Length < 16
        v3PendActor = new Actor[16]
    EndIf
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

    ; Register the SkyrimNet event schema.
    ; Only vrtouch_contact remains.  The V2 `vrtouch_event` schema and the
    ; two `vrtouch_weapon*` schemas were deleted with FireTrigger — nothing
    ; emits those event types any more, and vrtouch_weapon/_alert were never
    ; populated even in V2.
    RegisterV3Schema()

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
        if VRTouch_SexLabGate.IsInScene(sceneActor) || VRTouch_SexLabGate.IsInScene(playerRef) \
        || VRTouch_OStimGate.IsInScene(sceneActor)  || VRTouch_OStimGate.IsInScene(playerRef)
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
    if koTicking
        TickKO()
        if koTicking
            if 5.0 < nextWake
                nextWake = 5.0
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
        sceneActive = VRTouch_SexLabGate.IsInScene(akActor) || VRTouch_SexLabGate.IsInScene(playerRef) \
                   || VRTouch_OStimGate.IsInScene(akActor)  || VRTouch_OStimGate.IsInScene(playerRef)
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
        return
    EndIf
    ; No arousal LLM call during a SexLab/OStim scene — it was the missing gate:
    ; FireTrigger/FireWeaponTrigger checked the scene, but MaybeArousal did not,
    ; so it fired an LLM prompt per intimate touch AND changed the NPC's face
    ; mid-scene.  (OnCBPC now bails earlier too; this also covers the grab path.)
    if ScenesSuppress(akActor)
        return
    EndIf
    ; No arousal LLM call while this NPC is being choked — a strangled NPC
    ; isn't getting aroused, and no other event should fire during a choke.
    if chokeActive && akActor == chokeActor
        return
    EndIf
    Float baseline = baselineOverride
    if baseline < 0.0
        baseline = VRTouch_TriggerLib.GetArousal(bp, isGrab, arm)
    EndIf
    if baseline <= 0.0
        return
    EndIf
    Float now = Utility.GetCurrentRealTime()
    ; One LLM query in flight at a time (recover if a prior one never returned).
    if arousalPendingActor != None
        if (now - arousalPendingTime) > 20.0
            arousalPendingActor = None
        Else
            return
        EndIf
    EndIf
    if IsOnArousalCd(akActor, now)
        return
    EndIf
    arousalPendingActor = akActor
    arousalPendingTime  = now
    RecordArousalCd(akActor, now)

    String uuid = SkyrimNetApi.GetEntityUUID(akActor)
    String ctx  = "{\"npcUUID\":\"" + uuid + "\",\"narration\":\"" + narration + "\",\"baseline\":" + (baseline as Int) + "}"
    SkyrimNetApi.SendCustomPromptToLLM("vrtouch_arousal", "", ctx, Self as Quest, "VRTouch_MainScript", "OnArousalResponse")
    VTLog("AROUSAL query bp=" + bp + " grab=" + isGrab + " base=" + baseline + " on " + akActor.GetDisplayName())
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
            return (now - arousalCdTime[i]) < ArousalCooldown
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
    if chokeSoundHandle >= 0
        Sound.StopInstance(chokeSoundHandle)   ; defensive: clear any orphaned choke-sound handle
    EndIf
    chokeSoundHandle    = -1
    chokePassedOut      = False
    chokeNextTick       = chokeStartTime + 1.0
    chokeFiredSustained = False
    chokeFiredWitnessed = False
    chokeFiredThought7  = False
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

    ; Purge any pending LLM dialogue for this actor — a choked NPC
    ; shouldn't be mid-sentence.  Interrupts currently playing TTS and
    ; clears queued lines for all actors (SkyrimNet scope is global).
    SkyrimNetApi.PurgeDialogue(False)

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
    ; Just cut off whatever line she's speaking RIGHT NOW.  (We do NOT register a
    ; persistent "cannot speak" event — that lingered in her context and swallowed
    ; the RELEASE reaction too, leaving her silent even after letting go.)  The
    ; no-mid-choke-event change + the FireTrigger gag gate keep her quiet during
    ; the choke; the release reaction is forced via DirectNarration in EndChokeEx.
    SkyrimNetApi.TriggerInterruptDialogue(false)

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
Bool Function IsAssaultWitnessed(Actor victim)
    if victim == None
        return False
    EndIf
    Int tries = 0
    while tries < 12
        Actor probe = Game.FindRandomActorFromRef(victim, 2000.0)
        if probe != None && probe != victim && probe != playerRef && !probe.IsDead() && !probe.IsDisabled()
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
Actor Function FindChokeWitness(Actor victim)
    if victim == None
        return None
    EndIf
    Int tries = 0
    while tries < 12
        Actor probe = Game.FindRandomActorFromRef(victim, 2000.0)
        if probe != None && probe != victim && probe != playerRef && !probe.IsDead() && !probe.IsDisabled()
            if probe.HasLOS(playerRef) && playerRef.IsDetectedBy(probe)
                return probe
            EndIf
        EndIf
        tries += 1
    EndWhile
    return None
EndFunction

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

        if chokeElapsed < 3.0
            releaseTrigger = "VRTouch_Neck_Choke_Short"
            releaseNarr    = playerName2 + "'s hand closed briefly around " + npcName2 + \
                "'s throat — a short squeeze, a flash of pressure, then release. " + npcName2 + \
                " can still speak, but the warning was unmistakable"
        ElseIf chokeElapsed < 7.0
            releaseTrigger = "VRTouch_Neck_Choke_Sustained"
            releaseNarr    = playerName2 + " held " + npcName2 + \
                "'s throat crushed shut for several seconds before letting go. " + npcName2 + \
                " coughs hoarsely, voice rasping — they couldn't make a sound while that grip was on them, and their throat still throbs with bruising pressure"
        Else
            ; 7.0 – 15.0s window (15s+ would have passed out and taken the Passout path)
            releaseTrigger = "VRTouch_Neck_Choke_Severe"
            releaseNarr    = playerName2 + " finally released " + npcName2 + \
                "'s throat just before they lost consciousness. " + npcName2 + \
                " gasps raggedly, lungs burning, black spots still flickering at the edges of their vision — throat raw and scorched, each breath a harsh wheeze. They came within a hair's breadth of passing out"
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
        ; PurgeDialogue(False) is the blocking interrupt (StartChoke uses
        ; the same call for the same reason).  It clears the queue AND cuts
        ; audio mid-playback, which is what makes this an interrupt tier.
        SkyrimNetApi.PurgeDialogue(False)
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

    ; --- HP 50% + zero regen (makes heal detection reliable) ---
    Float maxHp    = a.GetBaseActorValue("Health")
    Float curHp    = a.GetActorValue("Health")
    Float targetHp = maxHp * 0.5
    if curHp > targetHp
        a.DamageActorValue("Health", curHp - targetHp)
    EndIf
    koHealRate[idx] = a.GetActorValue("HealRate")
    a.ForceActorValue("HealRate", 0.0)
    ; Snapshot HP now.  With HealRate zeroed, the ONLY way Health rises is an
    ; external heal — a potion (incl. the GiftByHand feed), an ingested effect,
    ; or a heal spell.  TickKO wakes her when it does (catches potions, which
    ; the heal-spell-keyword test misses).
    koHpAtKO[idx] = a.GetActorValue("Health")

    ; --- Silence vanilla barks ---
    a.SetVoiceRecoveryTime(999.0)

    ; --- Wake deadline: 2-4 game hours from now ---
    ; Utility.GetCurrentGameTime returns days; multiply by 24 for hours.
    Float wakeHours = Utility.RandomFloat(2.0, 4.0)
    koWakeHour[idx] = Utility.GetCurrentGameTime() * 24.0 + wakeHours

    ; Commit slot last so TickKO sees a fully-initialized entry.
    koActor[idx] = a

    ; Kick off tick if not already running
    if !koTicking
        koTicking = True
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
    EndIf
    koActor[idx]    = None
    koHealRate[idx] = -1.0
    koWakeHour[idx] = 0.0
    koHpAtKO[idx]   = -1.0
EndFunction

; Poll all KO slots for death, heal, or wake-timer expiry.
; Called from OnUpdate every 5s while any slot is active.
Function TickKO()
    Float nowHour = Utility.GetCurrentGameTime() * 24.0
    Bool  any     = False
    Int   i       = 0
    while i < 10
        Actor a = koActor[i]
        if a != None
            if a.IsDead()
                ; Slot release — no wake anim, engine handles corpse.
                ; HealRate restore irrelevant on corpse; skip.
                koActor[i]    = None
                koHealRate[i] = -1.0
                koWakeHour[i] = 0.0
                koHpAtKO[i]   = -1.0
            ElseIf nowHour >= koWakeHour[i]
                WakeKOSlot(i)
            ElseIf kwMagicRestoreHealth != None && a.Is3DLoaded() && a.HasMagicEffectWithKeyword(kwMagicRestoreHealth)
                ; Heal SPELL (instant) — wake immediately.
                WakeKOSlot(i)
            ElseIf a.Is3DLoaded() && koHpAtKO[i] >= 0.0 && a.GetActorValue("Health") > koHpAtKO[i] + 5.0
                ; Health rose with regen zeroed -> an external heal (POTION /
                ; GiftByHand feed / ingested effect).  This is what the user's
                ; potion case needs — WakeKOSlot clears BOTH SetUnconscious and
                ; the Paralysis AV together, so she actually gets up.
                WakeKOSlot(i)
            Else
                ; Slot still in use — also defensively re-assert paralysis
                ; if it got cleared by something external (another mod
                ; dispelling, engine cell-reset edge cases).  Only meaningful
                ; when loaded.
                if a.Is3DLoaded() && a.GetActorValue("Paralysis") < 0.5
                    a.ForceActorValue("Paralysis", 1)
                    a.SetUnconscious(True)
                EndIf
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

        ; --- 7s: escalated panic-thought (UNVOICED, victim still choked) ---
        if elapsed >= 7.0 && !chokeFiredThought7
            chokeFiredThought7 = True
            if !modOff   ; OFF for a scene: consume the milestone, don't leak the thought
                SkyrimNetApi.GenerateNPCThought(a, "It has been too long now and " + playerRef.GetDisplayName() + "'s grip has only crushed down harder. Your chest is heaving against nothing, your lungs are screaming, and the edges of everything are starting to go grey and far away. There's a roaring in your ears. Somewhere under the pain a single thought has gone cold and clear — you could actually die here, in this grip, and you still can't scream, can't beg, can't do anything but claw and shake as your own strength drains out of your arms.")
            EndIf
        EndIf

        ; --- 7s: public witness reaction (bystanders, NEVER the victim) ---
        ; The victim is gagged (can't speak), but nearby onlookers SHOULD react to
        ; the violence.  SkyrimNet has no "audience minus actor" param, so we pick a
        ; surrounding witness and make THEM the speaker (DirectNarration originator).
        ; That fires the reaction to "everyone around minus the choked victim" — the
        ; victim is structurally excluded (never the one reacting).  No witness in
        ; range -> stays silent (a private choke draws no attention).  Fires once.
        if elapsed >= 7.0 && !chokeFiredWitnessed
            chokeFiredWitnessed = True
          if !modOff   ; OFF for a scene: consume the milestone, no witness narration
            Actor witness = FindChokeWitness(a)
            if witness != None
                String witName   = a.GetDisplayName()
                String witPlayer = playerRef.GetDisplayName()
                String witNarr   = witPlayer + " has " + witName + " by the throat in a brutal chokehold — " + \
                    witName + "'s face twists in pain and panic as they claw for air."
                SkyrimNetApi.DirectNarration(witNarr, witness, None)
                VTLog("CHOKE WITNESS reaction by " + witness.GetDisplayName() + " (victim " + witName + " excluded as speaker)")
            EndIf
          EndIf ; !modOff
        EndIf

        ; --- 15s milestone: passout ---
        if elapsed >= 15.0
            ; Stop sound (12s of audio started at 3s)
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

            ; The passout narration — the LAST event that was still routed
            ; through the dead trigger path, now a direct call like the rest.
            ;
            ; originatorActor is deliberately None: she has just been choked
            ; unconscious and cannot be the speaker, so SkyrimNet picks an
            ; appropriate bystander. targetActor None = addressed to everyone
            ; nearby, which is exactly what the old YAML's `audience:
            ; everyone` meant. No witness in range simply means silence — a
            ; private strangling draws no comment, which is correct.
            ;
            ; NOT a thought: the thought manager self-skips dead/unconscious/
            ; sleeping actors, so a thought here would be dropped by
            ; construction the moment StartKOSlot runs.
            VTLog("CHOKE PASSOUT at elapsed=" + elapsed + "s on " + a.GetDisplayName())
            SkyrimNetApi.DirectNarration( \
                a.GetDisplayName() + "'s eyes flutter and roll back as the last of their strength gives out — " + \
                "they go limp in " + playerRef.GetDisplayName() + "'s grasp, unconscious", None, None)

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
; Register the vrtouch_contact schema.  Called on every Setup() —
; RegisterEventSchema is idempotent (same pattern as the V2 schemas).
; ================================================================
Function RegisterV3Schema()
    String f = "[" + \
        "{\"name\":\"narration\",\"type\":0,\"required\":true,\"description\":\"Full third-person touch narration\"}," + \
        "{\"name\":\"hand\",\"type\":0,\"required\":false,\"description\":\"Primary wand L or R\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"part\",\"type\":0,\"required\":false,\"description\":\"Primary capsule name\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"sub\",\"type\":0,\"required\":false,\"description\":\"Primary sub-region name\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"source\",\"type\":0,\"required\":false,\"description\":\"FINGER/PALM/FIST/HAND/GRAB/WEAPON/OBJECT\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"source_name\",\"type\":0,\"required\":false,\"description\":\"Weapon or object base name\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"duration\",\"type\":0,\"required\":false,\"description\":\"Primary contact duration in seconds\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"depth\",\"type\":0,\"required\":false,\"description\":\"Sub-region depth level 0-3\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"dist\",\"type\":0,\"required\":false,\"description\":\"Deepest surface distance, negative = inside\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"intensity\",\"type\":0,\"required\":false,\"description\":\"Pressure verb graded from depth\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"clothing_name\",\"type\":0,\"required\":false,\"description\":\"Clothing or armor name\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"second_hand\",\"type\":0,\"required\":false,\"description\":\"Secondary wand L or R\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"second_part\",\"type\":0,\"required\":false,\"description\":\"Secondary capsule name\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"second_source\",\"type\":0,\"required\":false,\"description\":\"Secondary source kind\",\"defaultValue\":\"\"}," + \
        "{\"name\":\"escalation\",\"type\":0,\"required\":false,\"description\":\"1 = escalation re-emit\",\"defaultValue\":\"0\"}," + \
        "{\"name\":\"is_private\",\"type\":0,\"required\":false,\"description\":\"1 = intimate contact, private audience\",\"defaultValue\":\"0\"}" + \
        "]"
    String t = "{" + \
        "\"recent_events\":\"{{narration}} ({{hand}} {{source}}, {{sub}}, {{duration}}s) ({{time_desc}})\"," + \
        "\"raw\":\"{{narration}}\"," + \
        "\"compact\":\"{{hand}} {{source}} -> {{part}}\"," + \
        "\"verbose\":\"VRTouch V3: {{narration}} [{{hand}} {{source}} on {{part}} / {{sub}}, depth={{depth}}, dist={{dist}}, {{duration}}s, esc={{escalation}}]\"" + \
        "}"
    SkyrimNetApi.RegisterEventSchema("vrtouch_contact", "VRTouch V3 Coalesced Contact", \
        "Coalesced PPB touch contact (both hands, one interaction)", f, t, true, 15000, true, false)
EndFunction

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
    String[] f = V3Split16(strArg)
    V3ChokeStamp(npc, f)
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
        V3ChokeStamp(npc, V3Split16(strArg))
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
    String[] f = V3Split16(strArg)
    V3Dispatch(npc, f, numArg, True)
EndFunction

Function OnVRTEContactEnd(String eventName, String strArg, Float numArg, Form sender)
    Actor npc = sender as Actor
    if !npc
        return
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
; V3Dispatch — the single policy funnel for Contact + Update.
; fromUpdate=True means we are re-testing a pending dwell wait (stay
; quiet while still short; fire once the duration crosses the delay).
; ================================================================
Function V3Dispatch(Actor npc, String[] f, Float dur, Bool fromUpdate)
    String w1    = f[0]
    String src1  = f[1]
    String name1 = f[2]
    String part1 = f[3]
    String sub1  = f[4]
    Int    dep1  = f[5] as Int
    Float  dist1 = f[6] as Float
    String w2    = f[7]
    String src2  = f[8]
    String name2 = f[9]
    String part2 = f[10]
    String sub2  = f[11]
    Int    dep2  = 0
    if f[12] != ""
        dep2 = f[12] as Int
    EndIf
    Float  dist2 = 0.0
    if f[13] != ""
        dist2 = f[13] as Float
    EndIf
    Bool esc = (f[15] == "1")

    ; ================================================================
    ; ★ CHOKE ARMING (PART B1) — the choke now ARMS from PPB.
    ; ================================================================
    ; V2 armed the choke off a CBPC neck marker, which on a PPB-DRIVEN
    ; NPC can never fire: report 18 §3b measured 1 CBPC event on M'rissi
    ; against 188 on a non-driven NPC, so the V2 choke was effectively
    ; DEAD on exactly the actors V3 is built for.  PPB reports a throat
    ; grab cleanly and in-band as sub="Neck" + src="GRAB" (proven live,
    ; report 18 §3a), so arming moves here.
    ;
    ; ONLY the arming moves.  Everything after it is still V2's and is
    ; untouched: TickChoke polls HiggsVR.GetGrabbedObject on both hands
    ; plus the grab-tracking vars for liveness (proven to hold through
    ; the passout ragdoll) and owns every milestone, the passout, the
    ; KO slot and the kill.
    ;
    ; A throat grab NEVER produces a normal contact event — whichever
    ; branch runs, we clear any pending dwell and return.
    ;
    ; The scene test is duplicated here (it normally sits further down,
    ; after the key resolve) because this branch returns BEFORE reaching
    ; it and StartChoke is a heavy state change — mute, BlockActivation,
    ; PurgeDialogue, StartCombat at 5s — that would shatter a SexLab /
    ; OStim scene.  V2 was covered by OnCBPC's ScenesSuppress check, and
    ; on a PPB-driven NPC that check may never run (CBPC barely fires on
    ; them at all — that is the whole reason arming moved here).  The
    ; gates are stubs returning False in the base mod, so this costs
    ; nothing unless a scene patch is installed.
    ; The GRAB-SUPPRESSION GATE is consulted here for the same reason V2
    ; consults it in OnObjectGrabbed BEFORE its own choke detection: with
    ; the optional "No Follower Grab" patch installed, a protected actor
    ; must not be chokeable at all.  V2 returned before StartChoke; V3 now
    ; does the same, so the patch keeps its documented meaning ("grab
    ; triggers AND choke initiation suppressed for this actor") instead of
    ; being silently bypassed by the new arming path.  Base mod = stub
    ; returning False, so this costs one call and changes nothing.
    if sub1 == "Neck" && src1 == "GRAB"
        if VRTouch_GrabGate.ShouldSuppressGrab(npc)
            VTLog("[V3] CHOKE ARM SUPPRESSED (grab gate) on " + npc.GetDisplayName())
        ElseIf VRTouch_SexLabGate.IsInScene(npc) || VRTouch_SexLabGate.IsInScene(playerRef) \
        || VRTouch_OStimGate.IsInScene(npc)  || VRTouch_OStimGate.IsInScene(playerRef)
            VTLog("[V3] CHOKE ARM SUPPRESSED (scene gate) on " + npc.GetDisplayName())
        ElseIf V3LogOnly
            ; Shadow mode: log the candidate, never arm.
            VTLog("[V3] CHOKE-CANDIDATE (log-only — would arm StartChoke) on " + npc.GetDisplayName() + " dur=" + dur)
        ElseIf chokeActive && npc == chokeActor
            ; Already choking THIS actor — just refresh the contact stamp.
            chokeLastContact = Utility.GetCurrentRealTime()
        ElseIf !chokeActive
            ; StartChoke re-checks its own guards (re-arm lockout, KO-slot
            ; kill-run detection, hand latch) — we only gate on the state
            ; it cannot see from here.  Log the RESULT, not the intent: on
            ; the 1s re-arm lockout StartChoke returns without arming, and
            ; an "ARMED" line written beforehand would be a lie in the log.
            ;
            ; Seed the hand latch and the PPB liveness stamp from THIS tuple
            ; before arming.  StartChoke's HIGGS probes refine chokeIsLeft if
            ; they resolve; if they do not, the arming contact's own wand is
            ; the better answer (the old grabActor_L fallback is deleted).
            ; chokeLastContact must be fresh at t=0 or the 1s-settle liveness
            ; test would see a 2s-stale PPB witness and end the choke instantly.
            chokeIsLeft      = (w1 == "L")
            chokeLastContact = Utility.GetCurrentRealTime()
            StartChoke(npc)
            if chokeActive && chokeActor == npc
                v3nChokeArm += 1
                VTLog("[V3] CHOKE ARMED (PPB Neck/GRAB) on " + npc.GetDisplayName() + " dur=" + dur)
            Else
                VTLog("[V3] CHOKE ARM REJECTED by StartChoke (re-arm lockout) on " + npc.GetDisplayName() + " dur=" + dur)
            EndIf
        EndIf
        ; (chokeActive on a DIFFERENT actor: leave the running choke
        ;  alone and stay silent — one choke at a time, as in V2.)
        V3PendClear(npc)
        return
    EndIf

    ; --- Key resolve ---
    String key = VRTouch_TriggerLib.V3MapKey(sub1, part1)
    if key == ""
        v3nUnmapped += 1
        ; Shout a NEW unknown name once, loudly — it means PPB's sub-region
        ; vocabulary has moved and V3MapKey needs a row, which is otherwise
        ; invisible behind a 4 Hz stream of identical lines.
        if V3NoteUnmapped(sub1)
            VTLog("[V3] ★ UNMAPPED SUB-REGION '" + sub1 + "' (capsule '" + part1 + "') — no V3MapKey row. " \
                + "Every contact on it is being DROPPED; add it to V3MapKey + V3PartOf.")
        ElseIf !fromUpdate
            VTLog("[V3] UNMAPPED sub=" + sub1 + " part=" + part1 + " — dropped")
        EndIf
        V3PendClear(npc)
        return
    EndIf
    Bool isGrab = (src1 == "GRAB")

    ; --- Grab-suppression gate (parity with OnObjectGrabbed) ---
    ; src=GRAB IS a HIGGS grab (PpbTouchAPI.h kSourceGrab), so the same
    ; optional patch that stops V2 narrating a protected actor's grab must
    ; stop V3 narrating it.  Touch contacts are unaffected — exactly as in
    ; V2, where the gate sits in OnObjectGrabbed only.
    if isGrab && VRTouch_GrabGate.ShouldSuppressGrab(npc)
        v3nGrabGate += 1
        VTLog("[V3] SUPPRESSED (grab gate): " + key + " on " + npc.GetDisplayName())
        V3PendClear(npc)
        return
    EndIf

    ; ================================================================
    ; ★ THE COMBAT GATE — inherited from the deleted V2 weapon path, and
    ; the single most important thing that had to survive the CBPC removal.
    ; ================================================================
    ; PPB reports a weapon contact for ANY blade near a driven NPC, including
    ; one that is mid-swing and taking her health off.  Narrating that as a
    ; social touch would produce "Telord is pressing their Iron Sword into
    ; Carmella's chest" for every hit of a real fight.
    ;
    ; V2 caught this in FireWeaponTrigger via the plugin's TESHitEvent sink
    ; ("WEAPON SUPPRESSED (real hit, not a touch)" — seen working in the
    ; 2026-08-02 10:00 combat log).  That whole function is gone, so the gate
    ; moves here.  It is deliberately NOT applied to hands or GRAB: a punch
    ; registers as a hit too, but a hand on an NPC you are fighting is still
    ; a social act worth narrating, and that was V2's behaviour as well.
    ;
    ; A gentle blade-rest deals no damage, so WasHitRecently stays False and
    ; deliberate weapon-touch narration still works.  Returns False when the
    ; DLL is absent, which fails toward narrating rather than silence.
    if src1 == "WEAPON" || src1 == "OBJECT"
        if VRTouchEvents_Native.WasHitRecently(npc, 1.5)
            v3nCombatHit += 1
            VTLog("[V3] SUPPRESSED (real hit, not a touch): " + key + " src=" + src1 + " on " + npc.GetDisplayName())
            V3PendClear(npc)
            return
        EndIf
    EndIf

    ; --- Armor state (updates lastArmor -> GetLastArmorName) ---
    ; V3ArmorState, NOT GetArmorState(V3SlotKey(...)): the face family
    ; needs the 44->30 helmet chain and the interior ladder must probe
    ; the pelvis slots only (49->52), never body slot 32.  See PART D.
    Int arm = V3ArmorState(npc, key)
    String clothName = GetLastArmorName()

    ; --- Plausibility: interior contact through armor = detection artefact ---
    if VRTouch_TriggerLib.V3PlausibilityDrop(key, arm)
        v3nPlausibility += 1
        VTLog("[V3] PLAUSIBILITY DROP key=" + key + " arm=" + arm + " (interior contact through armor) on " + npc.GetDisplayName())
        V3PendClear(npc)
        return
    EndIf

    ; --- Per-(part,armor) delay vs the session's primary duration ---
    ; Escalations fire IMMEDIATELY (user rule 3) — no dwell wait.
    Float delay = VRTouch_TriggerLib.V3GetDelay(key, isGrab, arm) * DelayMultiplier
    if !esc && dur < delay
        if !fromUpdate
            v3nPending += 1
            V3PendAdd(npc)
            VTLog("[V3] PENDING key=" + key + " dur=" + dur + " < delay=" + delay + " on " + npc.GetDisplayName())
        EndIf
        return    ; a later VRTE_ContactUpdate re-tests with a fresh duration
    EndIf
    V3PendClear(npc)

    ; --- Gates, in order: scene, choke gag, cooldown (mirrors FireTrigger) ---
    if VRTouch_SexLabGate.IsInScene(npc) || VRTouch_SexLabGate.IsInScene(playerRef) \
    || VRTouch_OStimGate.IsInScene(npc)  || VRTouch_OStimGate.IsInScene(playerRef)
        v3nSceneGate += 1
        VTLog("[V3] SUPPRESSED (scene gate): " + key + " on " + npc.GetDisplayName())
        return
    EndIf
    if chokeActive && npc == chokeActor
        v3nChokeGag += 1
        ; ★ THE FREE-HAND EXCEPTION, preserved from the deleted FireGrabHold.
        ; A choked NPC is gagged — she cannot speak, so every reaction for her
        ; is suppressed.  But V2 made ONE exception worth keeping: if the
        ; player's OTHER hand grabs her while the first is on her throat, she
        ; still NOTICES it, as an unvoiced thought.  It is the only channel a
        ; strangled NPC has left.  Stated as bare fact, like every other
        ; narration — what the free hand did and where, nothing about how it
        ; feels (see V3Narration's rule).
        ; Guarded on isGrab so an incidental brush from the choking arm can
        ; never trip it, and on the wand differing from the choking hand.
        if isGrab && (w1 == "L") != chokeIsLeft && !modOff
            String freeNarr = playerRef.GetDisplayName() + "'s free hand takes hold of " \
                + npc.GetDisplayName() + VRTouch_TriggerLib.V3PartOf(sub1, part1) \
                + VRTouch_TriggerLib.V3PreciseOf(sub1, part1) + "."
            SkyrimNetApi.GenerateNPCThought(npc, freeNarr)
            VTLog("[V3] CHOKE free-hand thought on " + npc.GetDisplayName() + " | " + freeNarr)
            return
        EndIf
        VTLog("[V3] SUPPRESSED (choke gag): " + key + " on " + npc.GetDisplayName())
        return
    EndIf
    Bool interrupting = esc || VRTouch_TriggerLib.V3IsInterrupting(key, arm, isGrab)
    Bool asThought    = VRTouch_TriggerLib.V3IsThought(key, arm, isGrab)

    ; ================================================================
    ; THE GATE — two clocks, and thoughts are exempt entirely.
    ; ================================================================
    ; "Though" rows are NEVER gated by us.  A thought is unvoiced and
    ; internal, so it cannot talk over anything and does not need pacing
    ; from this side — and SkyrimNet already throttles them itself
    ; (config/NpcThoughts.yaml, perNPCCooldownSeconds: 60).  Gating them
    ; here just meant a touch could be swallowed twice over.
    ;
    ; Speak rows consult the NORMAL clock.
    ; Speak (Interrupt) rows consult the INTIMATE clock ONLY — they cut
    ; through an ordinary reaction, but never through their own, so
    ; hammering one breast cannot outrun the LLM's ability to answer.
    ;
    ; ★ ESCALATIONS BYPASS EVERY CLOCK (report 16 §16.3 #4: "deeper-than-
    ; last-fired bypasses the tract cooldown — escalation is new
    ; information; same-or-shallower respects the cooldown").
    ; Observed 2026-08-08 11:00:21 before this carve-out existed: the
    ; opening fired, then `SUPPRESSED (intimate cooldown): uterus` one
    ; second later — the anti-spam rule had swallowed the ladder, and
    ; going from brushing the entrance to reaching the womb went unsaid.
    ;
    ; This is NOT a spam hole, and the reason is structural rather than a
    ; tuning judgement: the C++ bridge sets ESC only when the sub-region
    ; priority STRICTLY EXCEEDS the last one emitted in that session, and
    ; priority is capped (uterus 100). So a session can escalate at most a
    ; few times, only ever upward, and never twice at the same depth.
    ; Repeating the same contact re-emits with esc=0 and is gated normally,
    ; and a NEW session starts at emittedPriority -1 so its first emit is
    ; never an escalation.
    if !asThought && !esc && V3IsOnCooldown(npc, interrupting)
        v3nCooldown += 1
        String cdWhich = "normal"
        if interrupting
            cdWhich = "intimate"
        EndIf
        VTLog("[V3] SUPPRESSED (" + cdWhich + " cooldown): " + key + " on " + npc.GetDisplayName())
        return
    EndIf

    ; --- Compose ---
    String narr = VRTouch_TriggerLib.V3Narration(npc.GetDisplayName(), playerRef.GetDisplayName(), \
        sub1, part1, w1, src1, name1, dist1, dep1, \
        sub2, part2, w2, src2, name2, dist2, dep2, dur)
    String privStr = "0"
    if VRTouch_TriggerLib.V3IsPrivate(key, arm)
        privStr = "1"
    EndIf
    ; V3EffectiveDepth, not dep1 raw — the under-jaw capsule reports depth 2
    ; from OUTSIDE the head, and this field is what the schema's `intensity`
    ; shows the LLM.  Must match the verb inside V3Narration.
    String intensity = VRTouch_TriggerLib.V3IntensityVerb(dist1, \
        VRTouch_TriggerLib.V3EffectiveDepth(sub1, dep1))

    ; --- Shadow mode: log-only while V3LogOnly is set ---
    ; The cooldown is still recorded so the log models live pacing.
    ; (Gate is V3LogOnly, not !V3Live — see the property block: V3Live
    ;  is an Auto Property whose value lives in the save, so it could
    ;  never be flipped for an existing game.)
    if V3LogOnly
        String mode = "SPEAK"
        if asThought
            mode = "THOUGHT"
        EndIf
        VTLog("[V3] WOULD FIRE (" + mode + ") key=" + key + " arm=" + arm + " esc=" + f[15] + " priv=" + privStr \
            + " | " + w1 + "/" + src1 + " part=" + part1 + " sub=" + sub1 + " dep=" + dep1 + " dist=" + f[6] + " dur=" + dur \
            + " | second=" + w2 + "/" + src2 + "/" + part2 \
            + " | skel=" + f[14] + " cloth=" + clothName + " intensity=" + intensity \
            + " | " + narr)
        ; Shadow mode models live pacing, including which clock would be
        ; stamped — a thought stamps neither (see the live branches).
        if !asThought
            V3RecordFire(npc, interrupting)
        EndIf
        return
    EndIf

    ; ================================================================
    ; --- LIVE dispatch — THE THREE TIERS OF THE SCHEMA SHEET ---
    ; ================================================================
    ; `VRTouchEvents Triggers Shema.xlsx`, column "Though/Speak", is the
    ; specification.  Each of its three values is a DIFFERENT SkyrimNet
    ; delivery mechanism, and they must not be confused:
    ;
    ;   Though (34 rows)  -> GenerateNPCThought.  Unvoiced.  The NPC just
    ;                        notices; it colours their later lines.
    ;   Speak  (38 rows)  -> DirectNarration.  They talk about it when
    ;                        nothing else is happening.
    ;   Speak (Interrupt) -> DirectNarration, preceded by cutting whatever
    ;         (30 rows)      they are currently saying, so a hand on a bare
    ;                        breast is acknowledged NOW, not eventually.
    ;
    ; ★ WHY THIS IS A DIRECT CALL AND NOT A TRIGGER (2026-08-08)
    ; Speak used to be delivered by registering a `vrtouch_contact` event and
    ; letting the trigger YAML answer it with `response: direct_narration`.
    ; That is the same end result by a longer road, and the road closed:
    ; SkyrimNet's TriggerManager stopped evaluating events on this load order.
    ; Measured 2026-08-08 — 30 triggers loaded from several mods, an event
    ; type index built, the processing loop started, and then ZERO events
    ; evaluated in 45 minutes.  Our own event registered fine
    ; (`SceneContextBuilder: Processed event 'vrtouch_contact'`) and simply
    ; never reached a trigger.
    ;
    ; The tell was that Though kept working while both Speak tiers went
    ; silent: GenerateNPCThought is a direct API call, and so is the choke's
    ; DirectNarration — which is exactly why chokes still reacted when
    ; touches did not.  Calling DirectNarration here restores the sheet's
    ; behaviour and makes all three tiers independent of TriggerManager.
    ;
    ; The audience split is native to the API and replaces what the two
    ; pass-through YAMLs were emulating:
    ;   targetActor = the player -> she answers the player  (private)
    ;   targetActor = None       -> she addresses everyone nearby (public)
    if asThought
        ; ★ A thought stamps NEITHER clock.  It is transparent to the
        ; cooldown system in both directions: it is not gated by it (above)
        ; and it does not consume anyone else's turn.  It is unvoiced and
        ; internal, so it cannot talk over a Speak — and SkyrimNet's own
        ; 60s per-NPC thought throttle already paces it.  Letting a thought
        ; block a later Speak would mean brushing an arm silences a grope.
        v3nThought += 1
        SkyrimNetApi.GenerateNPCThought(npc, narr)
        VTLog("[V3] THOUGHT key=" + key + " part='" + part1 + "' on " + npc.GetDisplayName() + " | " + narr)
    Else
        ; --- SPEAK (INTERRUPT): cut the line she is saying right now. ---
        ; TriggerInterruptDialogue is the non-blocking twin of PurgeDialogue
        ; (StartChoke uses the pair for the same purpose).  `false` = also
        ; interrupt audio mid-playback rather than letting it finish, which
        ; is the whole point of the tier.
        ; ⚠ It is GLOBAL — it clears every actor's queue, not just hers.
        ; SkyrimNet has no per-actor speech-stop, so a second NPC talking
        ; nearby also gets cut.  Accepted: this only runs for the 30 sheet
        ; rows marked "Speak (Interrupt)", all of them intimate contact.
        String mode = "SPEAK"
        if interrupting
            SkyrimNetApi.TriggerInterruptDialogue(false)
            mode = "SPEAK-INTERRUPT"
        EndIf

        ; --- SPEAK: force the reaction. ---
        ; Private -> she answers the player directly.  Public -> she
        ; addresses everyone nearby.  Both are DirectNarration's own
        ; targetActor semantics; no trigger, no YAML, no event matching.
        if privStr == "1"
            SkyrimNetApi.DirectNarration(narr, npc, playerRef)
        Else
            SkyrimNetApi.DirectNarration(narr, npc, None)
        EndIf

        v3nSpoken += 1
        ; An interrupt stamps BOTH clocks; an ordinary Speak stamps only the
        ; normal one, so intimate contact can still cut in immediately.
        V3RecordFire(npc, interrupting)
        ; part1 is logged RAW (exactly as PPB sent it) beside the finished
        ; narration.  That one pairing is what makes a casing or naming bug
        ; diagnosable from the user log alone, without cross-referencing the
        ; SKSE bridge log — which truncates on every launch.
        VTLog("[V3] " + mode + " key=" + key + " esc=" + f[15] + " priv=" + privStr \
            + " part='" + part1 + "' on " + npc.GetDisplayName() + " | " + narr)
    EndIf
    V3ReportMaybe()

    ; Optional arousal — reuse the existing pipeline (gates, cooldown, LLM)
    ; with the V3 report-14 baseline for the resolved key; the V2-mapped key
    ; keeps the vocabulary the arousal prompt/logs already know.
    MaybeArousal(npc, VRTouch_TriggerLib.V3ArousalKey(key), isGrab, arm, narr, \
        VRTouch_TriggerLib.V3GetArousal(key, isGrab, arm))
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
        + " combathit=" + v3nCombatHit \
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
    if f[1] == "GRAB" || f[8] == "GRAB"
        chokeLastContact = Utility.GetCurrentRealTime()
    EndIf
EndFunction

; Split the 16-field VRTE strArg on '|'.  Base-SKSE StringUtil only
; (no PapyrusUtil Split dependency at compile time).  Missing tail
; fields stay "" — new String[16] elements default to empty.
; NOTE: Substring(s, start, 0) means "to end of string", so empty
; fields (p == start) must be skipped explicitly, not sliced.
String[] Function V3Split16(String s)
    String[] out = new String[16]
    Int idx = 0
    Int start = 0
    Int slen = StringUtil.GetLength(s)
    while idx < 15
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
        out[15] = StringUtil.Substring(s, start)
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
            return (Utility.GetCurrentRealTime() - stamp) < GlobalCooldown
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
