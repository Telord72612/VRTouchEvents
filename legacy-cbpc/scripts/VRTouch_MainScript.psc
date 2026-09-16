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
Float Property BackWindow      = 1.0   Auto
Float Property MarkerWindow    = 1.5   Auto

; Optional: set via CK to a SNDR record pointing to a choking sound WAV.
; Leave None to skip sound playback. Null-safe throughout.
Sound Property ChokingSound Auto

; ================================================================
; Correlation markers — most recent actor + timestamp
; ================================================================
Actor  backActor
Float  backTime = 0.0

Actor  breastActor
Float  breastTime = 0.0
String breastSide = ""

Actor  bellyActor
Float  bellyTime = 0.0

Actor  buttActor
Float  buttTime = 0.0

Actor  faceActor
Float  faceTime = 0.0
Actor  faceExprActor             ; NPC whose arousal facial expression is currently set
Float  faceExprClearAt = 0.0     ; realtime at which to auto-clear it (15s after apply)

; ================================================================
; HIGGS grab memory — one slot per hand
; grabStart_*  = realtime when grip first pressed on this actor/node
; grabFireAt_* = realtime when the hold-duration dwell expires (= start + delay)
;                The trigger fires AT THIS TIME during the hold, not on release.
; grabFired_*  = True once the hold-fire has been emitted, so OnObjectDropped
;                won't double-fire on release.
; ================================================================
Actor  grabActor_L
String grabNode_L
Float  grabStart_L  = 0.0
Float  grabFireAt_L = 0.0
Bool   grabFired_L  = False
Actor  grabActor_R
String grabNode_R
Float  grabStart_R  = 0.0
Float  grabFireAt_R = 0.0
Bool   grabFired_R  = False

; ================================================================
; Pending event queue (single slot — Papyrus has one OnUpdate timer)
;
; Dwell-time semantics:
;   - pendFireAt      = earliest time we're allowed to fire
;                       (= contact-start + required dwell delay)
;   - pendLastContact = most recent CBPC event on this actor+region
;   - At pendFireAt we check (now - pendLastContact); if contact went
;     stale before the dwell expired, the event is silently cancelled.
; ================================================================
Bool   pendActive = False
Bool   sceneActive  = False  ; cached SexLab/OStim scene state (scene-suppression)
Float  sceneCheckAt = 0.0    ; realtime the scene state was last re-tested
Bool   modOff       = False  ; TRUE while the mod is fully unregistered for a scene
Actor  sceneActor            ; the in-scene actor that triggered the shutdown
Int    sceneEndGrace = 0     ; consecutive "scene ended" polls before re-arming
Actor  pendActor
String pendTrigger
String pendReaction
String pendRegion
Bool   pendIsGrab
Bool   pendInterrupting
Float  pendFireAt
Float  pendLastContact = 0.0    ; last CBPC refresh during dwell
Bool   pendIsTailTouch = False  ; true when pending event is a tail touch
Bool   pendThought     = False  ; true = fire as unvoiced thought, not a spoken reaction

; ================================================================
; Per-NPC cooldown registry
;
; One fire on actor X blocks further non-interrupting touch/grab
; events on X for GlobalCooldown seconds.  Scoped per-actor so
; touching NPC_A never cools down NPC_B.  16 slots is plenty —
; realistic play touches a handful of distinct actors in any 15s
; window; when full we evict the oldest entry (LRU).
; ================================================================
Actor[] cdActor
Float[] cdTime

; ================================================================
; Cached armor form from last GetArmorState call
; ================================================================
Armor lastArmor

; ================================================================
; Mutex
; ================================================================
Bool busy = False

; ================================================================
; Choke mechanic state
; ================================================================
Actor  neckActor            = None   ; last actor whose CME Neck was touched by player
Float  neckTime             = 0.0    ; realtime of that contact

Bool   chokeActive          = False  ; choke state machine running
Actor  chokeActor           = None   ; NPC being choked
Float  chokeStartTime       = 0.0    ; realtime when choke began
Float  chokeLastContact     = 0.0    ; last CME Neck contact refresh
Int    chokeSoundHandle     = -1     ; Sound.Play() handle, -1 = not playing
Bool   chokePassedOut       = False  ; has the NPC hit the 15s passout?
Float  chokeNextTick        = 0.0    ; realtime of next TickChoke call
Bool   chokeFiredSustained  = False  ; have we fired the 5s sustained event?
Bool   chokeFiredWitnessed  = False  ; 7s public-witness trigger fired?
Bool   chokeWarnedNoSound   = False  ; warned once that ChokingSound property is unset?
Bool   chokeIsKillRun       = False  ; choke target is already KO'd — count toward kill, not passout
Bool   chokeIsLeft          = False  ; which hand's controller grip holds the throat (liveness poll)
Bool   chokeFiredThought3   = False  ; 3s choke fear-thought pushed to victim?
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
; Wand/source tag buffer — fed by the VRTouchEvents.dll CBPC hook
; via the "VRTouchEvents_CBPCTouch" mod event.  Each entry records,
; for one (actor,node) touch, WHICH player wand (L/R) and whether it
; was a HAND or a WEAPON.  OnCBPC reads the freshest matching entry to
; (a) SUPPRESS the stock hand-touch when a node is weapon-occupied and
; route it to the weapon path instead, and (b) tag genuine hand touches
; with L/R internally.  Ring buffer, 16 slots.  If the DLL is absent the
; buffer stays empty -> GetTouchTag returns -1 -> everything degrades to
; today's hand-only behavior (no suppression).
; tagCode encoding (matches the event's numArg): 1=R hand, 2=L hand,
;   11=R weapon, 12=L weapon, 13=both weapons, 10=unknown weapon.
;   isWeapon = tagCode >= 10 ; wand = tagCode % 10.
; ================================================================
Actor[]  tagActor
String[] tagNode
Int[]    tagCode
Float[]  tagTime
Int      tagNext = 0
Float    TagFreshWindow = 0.5    ; a tag is valid for this many seconds

; ================================================================
; Weapon-touch dwell — a SEPARATE single slot, driven entirely by the
; DLL's weapon events (NOT the stock-CBPC hand-touch slot above, which
; is untouched).  A weapon must stay against one body region for a full
; uninterrupted second before the event fires; if contact lapses (no
; refresh within 0.4s) the whole thing drops.  Throat contact (any
; weapon) or any sharp/bladed weapon fires an INTERRUPTING event; all
; other weapon touches are non-interrupting context.
; ================================================================
Bool   wpnActive       = False
Actor  wpnActor        = None
String wpnRegion       = ""      ; weapon body-part CATEGORY (also the dwell key)
Bool   wpnIsLeft       = False   ; which hand's weapon to name (BOTH/unknown -> right)
Float  wpnStart        = 0.0     ; realtime contact began
Float  wpnLastContact  = 0.0     ; last weapon-event refresh
Float  WeaponDwell     = 1.0     ; required uninterrupted contact (seconds)

; Alert (throat / sharp-weapon) re-fire throttle.  Alerts BYPASS the normal
; per-NPC cooldown (a blade to the throat must get through even if the NPC was
; just touched) but use this dedicated throttle so a held blade doesn't spam.
Actor  lastAlertActor  = None
Float  lastAlertTime   = 0.0
Float  AlertCooldown   = 8.0     ; min seconds between alerts on the same NPC

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

    ; Clear correlation markers
    backActor   = None
    backTime    = 0.0
    breastActor = None
    breastTime  = 0.0
    breastSide  = ""
    bellyActor  = None
    bellyTime   = 0.0
    buttActor   = None
    buttTime    = 0.0
    faceActor   = None
    faceTime    = 0.0
    grabActor_L  = None
    grabNode_L   = ""
    grabStart_L  = 0.0
    grabFireAt_L = 0.0
    grabFired_L  = False
    grabActor_R  = None
    grabNode_R   = ""
    grabStart_R  = 0.0
    grabFireAt_R = 0.0
    grabFired_R  = False

    ; Release any active tail block before resetting state
    if pendIsTailTouch && pendActor != None
        pendActor.BlockActivation(false)
    EndIf
    pendActive       = False
    pendIsTailTouch  = False
    pendLastContact  = 0.0
    lastArmor    = None
    busy         = False

    ; Initialize per-NPC cooldown arrays.  Preserves entries on
    ; OnPlayerLoadGame (in-flight cooldowns carry across a save).
    if cdActor.Length < 16
        cdActor = new Actor[16]
        cdTime  = new Float[16]
    EndIf

    ; Initialize the wand/source tag buffer (fed by VRTouchEvents.dll).
    if tagActor.Length < 16
        tagActor = new Actor[16]
        tagNode  = new String[16]
        tagCode  = new Int[16]
        tagTime  = new Float[16]
    EndIf
    ; Clear the tag ring on EVERY load (not just first alloc).  GetCurrentRealTime
    ; resets toward 0 each launch, so a tag persisted from a prior session keeps its
    ; old (large) timestamp — (now - oldTime) goes large-negative, which passes the
    ; "<= TagFreshWindow" freshness test and would let a phantom weapon tag wrongly
    ; suppress the first real hand touch on that node.  Zero them so nothing pre-reload
    ; can ever read as fresh.
    Int ti = 0
    while ti < tagActor.Length
        tagActor[ti] = None
        tagNode[ti]  = ""
        tagCode[ti]  = 0
        tagTime[ti]  = 0.0
        ti += 1
    EndWhile
    tagNext = 0

    ; Drop any stale weapon-touch dwell + alert throttle from a previous session.
    wpnActive      = False
    wpnActor       = None
    wpnRegion      = ""
    wpnLastContact = 0.0
    lastAlertActor = None
    lastAlertTime  = 0.0

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
    neckActor           = None
    neckTime            = 0.0
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

    ; CBPC physics collision events
    RegisterForModEvent("CBPCPlayerCollisionWithFemaleEvent",        "OnCBPC")
    RegisterForModEvent("CBPCPlayerCollisionWithMaleEvent",          "OnCBPC")
    RegisterForModEvent("CBPCPlayerGenitalCollisionWithFemaleEvent", "OnCBPC")
    RegisterForModEvent("CBPCPlayerGenitalCollisionWithMaleEvent",   "OnCBPC")

    ; VRTouchEvents.dll CBPC hook — per-touch wand (L/R) + hand/weapon.
    ; If the DLL isn't installed this simply never fires (graceful no-op).
    RegisterForModEvent("VRTouchEvents_CBPCTouch", "OnVRTouchEvent")

    ; HIGGS grab / release — unregister first, 2s wait (Gift by Hand VR pattern)
    Debug.Trace("[VRTouch] Setup: registering HIGGS grab/drop events")
    HiggsVR.UnregisterForGrabEvent(Self)
    HiggsVR.UnregisterForDropEvent(Self)
    Utility.Wait(2.0)
    HiggsVR.RegisterForGrabEvent(Self)
    HiggsVR.RegisterForDropEvent(Self)
    Debug.Trace("[VRTouch] Setup: HIGGS register calls returned (no API failure indication)")

    ; Register SkyrimNet event schema for YAML trigger matching
    Debug.Trace("[VRTouch] Setup: calling RegisterVRTouchSchema")
    RegisterVRTouchSchema()
    RegisterWeaponSchemas()
    Debug.Trace("[VRTouch] Setup: RegisterVRTouchSchema returned")

    ; Open the dedicated Papyrus user log -> Documents\My Games\Skyrim VR\Logs\Script\User\VRTouchEvents.0.log
    ; (NOT the Steam/base-game folder — that must stay pristine.)
    Debug.OpenUserLog("VRTouchEvents")
    VTLog("===== VRTouchEvents ready (schema + HIGGS registered) | " + WeaponStateStr() + " =====")

    if EnableDebug || EnableDebugGrab
        Debug.Notification("VRTouch: Ready (73 triggers + choke)")
    EndIf
EndFunction

; ================================================================
; Register SkyrimNet event schema for vrtouch_event type.
; Called on every Setup() — RegisterEventSchema is idempotent.
; ================================================================
Function RegisterVRTouchSchema()
    String f = "[" + \
        "{\"name\":\"trigger_name\",\"type\":0,\"required\":true,\"description\":\"VRTouch trigger ID\"}," + \
        "{\"name\":\"touched\",\"type\":0,\"required\":true,\"description\":\"NPC being touched\"}," + \
        "{\"name\":\"toucher\",\"type\":0,\"required\":true,\"description\":\"Person touching\"}," + \
        "{\"name\":\"clothing_name\",\"type\":0,\"required\":false,\"description\":\"Clothing or armor name\",\"defaultValue\":\"\"}" + \
        "]"
    String t = "{" + \
        "\"recent_events\":\"**{{toucher}}** touched {{touched}} ({{time_desc}})\",\"raw\":\"{{toucher}} touched {{touched}} ({{trigger_name}})\",\"compact\":\"{{toucher}}->{{touched}}\",\"verbose\":\"VRTouch: {{toucher}} triggered {{trigger_name}} on {{touched}}\"" + \
        "}"
    SkyrimNetApi.RegisterEventSchema("vrtouch_event", "VRTouch Physical Event", \
        "VR physical touch or grab event", f, t, true, 15000, true, false)
EndFunction

; ================================================================
; Register the two weapon-touch schemas.  SkyrimNet's interrupt flag
; is set per-SCHEMA (not per-event), so we register the same shape
; twice: a non-interrupting one for ordinary weapon contact, and an
; interrupting "alert" one used when a weapon is held to the throat or
; the weapon is sharp/bladed.  Idempotent — safe to call every Setup().
; ================================================================
Function RegisterWeaponSchemas()
    String f = "[" + \
        "{\"name\":\"weapon_type\",\"type\":0,\"required\":true,\"description\":\"Kind of weapon (sword, mace, dagger...)\"}," + \
        "{\"name\":\"body_part\",\"type\":0,\"required\":true,\"description\":\"Body region the weapon is held against\"}," + \
        "{\"name\":\"touched\",\"type\":0,\"required\":true,\"description\":\"NPC the weapon is held against\"}," + \
        "{\"name\":\"toucher\",\"type\":0,\"required\":true,\"description\":\"Person holding the weapon\"}" + \
        "]"
    String t = "{" + \
        "\"recent_events\":\"**{{toucher}}** held a {{weapon_type}} against {{touched}}'s {{body_part}} ({{time_desc}})\"," + \
        "\"raw\":\"{{toucher}} held a {{weapon_type}} against {{touched}}'s {{body_part}}\"," + \
        "\"compact\":\"{{toucher}}->{{touched}} ({{weapon_type}})\"," + \
        "\"verbose\":\"VRTouch weapon: {{toucher}} pressed a {{weapon_type}} to {{touched}}'s {{body_part}}\"" + \
        "}"
    ; Non-interrupting: ordinary weapon contact (last bool = interrupt = false).
    SkyrimNetApi.RegisterEventSchema("vrtouch_weapon", "VRTouch Weapon Contact", \
        "Player holds a weapon against an NPC's body", f, t, true, 15000, true, false)
    ; Interrupting alert: throat contact (any weapon) or a sharp weapon
    ; (last bool = interrupt = true).
    SkyrimNetApi.RegisterEventSchema("vrtouch_weapon_alert", "VRTouch Weapon Threat", \
        "Player holds a weapon to an NPC's throat, or a blade against them", f, t, true, 15000, true, true)
EndFunction

; ================================================================
; CBPC Touch Handler
; ================================================================
Function OnCBPC(String evtName, String nodeName, Float duration, Form actorForm)
    if busy
        return
    EndIf
    Actor akActor = actorForm as Actor
    if !akActor
        return
    EndIf
    if akActor == playerRef || akActor.IsChild()
        return
    EndIf
    ; --- Scene shutdown -------------------------------------------------
    ; The first CBPC contact during a SexLab/OStim scene detects it and turns
    ; the WHOLE mod off (EnterSceneOff unregisters every sink), so subsequent
    ; collisions don't even reach Papyrus.  ScenesSuppress is throttled so the
    ; detection lookups aren't themselves a cost; the bail also covers the brief
    ; window before the unregister takes effect.
    if ScenesSuppress(akActor)
        EnterSceneOff(akActor)
        return
    EndIf

    ; --- Wand/source filter (VRTouchEvents.dll hook) -------------------
    ; The DLL tags each touch with the player wand + whether it came from a
    ; HAND or a WEAPON.  CBPC raises this stock event for weapon contacts
    ; too (it can't tell them apart), so if the freshest tag for this exact
    ; (actor,node) says WEAPON, suppress the entire hand-touch path here —
    ; markers, choke-by-neck, dwell — and let the dedicated weapon path
    ; (OnVRTouchEvent -> weapon dwell) handle it instead.  A HAND tag (or no
    ; tag at all, e.g. the DLL isn't installed) falls through to the
    ; unchanged hand-touch logic below.  touchTag stays in scope so the
    ; genuine hand touch can be tagged L/R internally further down.
    Int touchTag = GetTouchTag(akActor, nodeName, Utility.GetCurrentRealTime())
    if touchTag >= 10
        if EnableDebug
            Debug.Trace("[VRTouch] OnCBPC weapon-suppressed (handled by weapon path): actor=" + akActor.GetDisplayName() + " node=" + nodeName + " code=" + touchTag)
        EndIf
        return
    EndIf

    ; Raw CBPC entry trace — high volume, gated behind EnableDebug
    ; so it's available for future diagnosis without spamming logs.
    if EnableDebug
        Debug.Trace("[VRTouch] OnCBPC RAW: evt=" + evtName + " node=" + nodeName + " actor=" + akActor.GetDisplayName() + " dist=" + akActor.GetDistance(playerRef))
    EndIf

    ; Cache the grab-active state for this actor.  Used below to keep
    ; markers refreshed during a grab (so ResolveGrab works on release)
    ; while still suppressing the touch-trigger queue (so we don't fire
    ; spurious "butt" or "genitals" touches via the COM correlation
    ; path while the hand is in the lower-body region).
    Bool isGrabbingThis = (grabActor_L == akActor || grabActor_R == akActor)

    Float now = Utility.GetCurrentRealTime()

    ; --- Back marker ---
    if nodeName == "CME Back [Back]"
        backActor = akActor
        backTime  = now
        if EnableDebug
            Debug.Notification("VRTouch MARKER: back [" + akActor.GetDisplayName() + "]")
        EndIf
        return
    EndIf

    ; --- Neck marker (choke detection) ---
    ; Any CBPC collision on a neck node sets the neck marker, refreshes
    ; active choke contact, AND reverse-triggers StartChoke if the player
    ; is already grabbing this actor's chest/Spine2. This handles the
    ; common VR case where the CBPC sphere (radius 3) is missed on the
    ; hand's initial approach but catches once the grip is established
    ; and the hand drifts onto the throat.
    if nodeName == "CME Neck [Neck]" || nodeName == "NPC Neck [Neck]" || nodeName == "NPC Neck"
        neckActor = akActor
        neckTime  = now

        if chokeActive && chokeActor == akActor
            chokeLastContact = now
        ElseIf !chokeActive && IsGrabbingChest(akActor)
            ; Reverse trigger — grab was already in progress when neck
            ; CBPC finally fired. Start the choke immediately.
            if EnableDebug || EnableDebugGrab
                Debug.Notification("VRTouch: CHOKE reverse-trigger (neck during grab)")
            EndIf
            StartChoke(akActor)
        EndIf

        if EnableDebug || EnableDebugGrab
            Debug.Notification("VRTouch NECK MARKER: [" + akActor.GetDisplayName() + "] node=" + nodeName)
        EndIf
        Debug.Trace("[VRTouch] Neck marker set: actor=" + akActor.GetDisplayName() + " node=" + nodeName + " time=" + now)
        return
    EndIf

    ; --- Resolve body part ---
    String bodyPart = NodeToBodyPart(nodeName)
    if bodyPart == ""
        if EnableDebug
            Debug.Notification("VRTouch: unmapped [" + nodeName + "]")
        EndIf
        return
    EndIf

    ; --- Tail contact trace: REMOVED 2026-09-15 (V2.1 CBPC build) ---
    ; Tails are no longer mapped, so this trace could never fire.

    ; --- Set correlation markers BEFORE resolving ---
    ; Markers MUST keep refreshing even during a grab so ResolveGrab
    ; can use them on release (the grab resolver leans on back/butt/
    ; breast/belly markers to disambiguate front vs back, butt vs
    ; genitals, etc.).  Only the trigger-queue path is gated below.
    SetMarkers(akActor, bodyPart, now)

    ; --- Grab-active gate: refresh markers (above) but stop here.
    ; The release event on the held hand will produce the canonical
    ; trigger via ResolveGrab; firing touches in parallel would just
    ; spam unrelated body parts brushed by the hand sphere. ---
    if isGrabbingThis
        if EnableDebug
            Debug.Trace("[VRTouch] CBPC marker-only (grabbing): actor=" + akActor.GetDisplayName() + " bodyPart=" + bodyPart)
        EndIf
        return
    EndIf

    ; --- Apply cross-node correlation for touch ---
    bodyPart = ResolveTouch(akActor, bodyPart, now)
    if bodyPart == ""
        return
    EndIf

    ; --- Armor state ---
    Int armorState = GetArmorState(akActor, bodyPart)

    ; --- Trigger lookup ---
    String triggerName = VRTouch_TriggerLib.GetTriggerName(bodyPart, False, armorState)
    if triggerName == ""
        if EnableDebug
            Debug.Notification("VRTouch: no trigger [" + bodyPart + " touch arm=" + armorState + "]")
        EndIf
        return
    EndIf

    Float delay = VRTouch_TriggerLib.GetDelay(bodyPart, False, armorState) * DelayMultiplier
    Bool interrupting = VRTouch_TriggerLib.IsInterrupting(bodyPart, False, armorState)
    String region = VRTouch_TriggerLib.GetRegion(bodyPart)

    ; --- Refresh dwell: if a pending touch exists for the same actor+region,
    ;     just bump pendLastContact and exit (do NOT re-queue). This is the
    ;     heartbeat CBPC gives us while the hand is still in contact. ---
    if pendActive && !pendIsGrab && pendActor == akActor && pendRegion == region
        pendLastContact = now
        return
    EndIf

    ; --- Per-NPC cooldown ---
    if !interrupting && IsOnNpcCooldown(akActor)
        return
    EndIf

    ; --- Build reaction ---
    String armorName = GetLastArmorName()
    String npcName    = akActor.GetDisplayName()
    String playerName = playerRef.GetDisplayName()
    String reaction   = VRTouch_TriggerLib.GetReaction(bodyPart, False, armorState, npcName, playerName, armorName)

    if EnableDebug
        Debug.Notification("VRTouch DWELL start: " + triggerName + " needs " + delay + "s")
    EndIf

    ; --- Queue (or fire if zero-dwell) ---
    VTLog("TOUCH " + bodyPart + " arm=" + armorState + " hand=" + WandStr(touchTag) + " -> " + triggerName + " (dwell " + delay + "s) | " + WeaponStateStr())
    Bool isThg = VRTouch_TriggerLib.IsThought(bodyPart, False, armorState)
    busy = True
    QueueEvent(akActor, triggerName, reaction, region, False, delay, interrupting, bodyPart, isThg)
    busy = False

    ; Optional arousal: intimate touches ask the LLM for a relationship-adjusted
    ; arousal delta + face (no-op for non-intimate parts / if the feature is off).
    MaybeArousal(akActor, bodyPart, False, armorState, reaction)
EndFunction

; ================================================================
; VRTouchEvents.dll CBPC hook handler
; ================================================================
; Fired once per detected touch with the player wand + hand/weapon source.
;   strArg = "<WAND>|<SOURCE>|<NODE>"   numArg = code (see tag-buffer notes)
; We ALWAYS record the tag so OnCBPC can read wand/source for this
; (actor,node).  For a WEAPON touch we additionally drive the dedicated
; weapon dwell here; OnCBPC will then suppress its own hand-touch for the
; same node (GetTouchTag returns a weapon code).  Hand touches need nothing
; more from us — OnCBPC owns them, unchanged, and just reads the L/R tag.
; ================================================================
Function OnVRTouchEvent(String eventName, String strArg, Float numArg, Form sender)
    Actor npc = sender as Actor
    if !npc || npc == playerRef || npc.IsChild()
        return
    EndIf
    ; Scene shutdown: first weapon contact in a scene turns the whole mod off.
    if ScenesSuppress(npc)
        EnterSceneOff(npc)
        return
    EndIf

    ; Extract NODE from "WAND|SOURCE|NODE" (the node string has no '|').
    Int p1 = StringUtil.Find(strArg, "|", 0)
    Int p2 = StringUtil.Find(strArg, "|", p1 + 1)
    if p1 < 0 || p2 < 0
        return
    EndIf
    String node = StringUtil.Substring(strArg, p2 + 1)

    Int   code = numArg as Int
    Float now  = Utility.GetCurrentRealTime()

    ; Record the tag for OnCBPC's wand/source lookup (hand AND weapon).
    StoreTouchTag(npc, node, code, now)

    ; Hand touch (code < 10): done — OnCBPC handles it.
    if code < 10
        return
    EndIf

    ; --- Weapon touch: drive the 1-second dwell ---
    String category = NodeToWeaponCategory(node)
    if category == ""
        return    ; weapon on an unmapped node — ignore
    EndIf
    Bool isLeft = (code % 10 == 2)    ; wand 2 = LEFT; RIGHT/BOTH/unknown -> right hand

    if wpnActive && wpnActor == npc && wpnRegion == category
        ; Same contact continuing — refresh the heartbeat + the hand currently in
        ; contact (F6: so FireWeaponTrigger names the right hand's weapon at fire time).
        wpnLastContact = now
        wpnIsLeft      = isLeft
    ElseIf !wpnActive
        ; A sharp edge on face/head/throat is an INTERRUPT: it must get through even if
        ; this NPC is on the normal cooldown (e.g. from a prior touch).  Interrupts use
        ; their own short throttle (AlertCooldown); thought + speak tiers still respect
        ; the per-NPC cooldown so a held weapon doesn't re-react every second.
        Bool isInterrupt = IsSharpWeapon(playerRef.GetEquippedWeapon(isLeft)) && IsHeadZone(category)
        if isInterrupt
            if lastAlertActor == npc && (now - lastAlertTime) < AlertCooldown
                return
            EndIf
        ElseIf IsOnNpcCooldown(npc)
            return
        EndIf
        wpnActive      = True
        wpnActor       = npc
        wpnRegion      = category
        wpnIsLeft      = isLeft
        wpnStart       = now
        wpnLastContact = now
        if EnableDebug || EnableDebugGrab
            Debug.Notification("VRTouch WEAPON dwell start: " + category)
        EndIf
        ScheduleNextUpdate()
    EndIf
    ; A different weapon dwell already active -> ignore until it frees
    ; (you press one spot at a time; the active one drops after 0.4s of
    ; no refresh, then a new region can start).
EndFunction

; ================================================================
; HIGGS Grab — record which node on grip, then check for choke
; ================================================================
Event OnObjectGrabbed(ObjectReference refr, Bool isLeft)
    Actor akActor = refr as Actor
    Debug.Trace("[VRTouch] OnObjectGrabbed FIRED: isLeft=" + isLeft + " refr=" + refr + " actor=" + akActor)
    if !akActor || akActor == playerRef || akActor.IsChild()
        Debug.Trace("[VRTouch] OnObjectGrabbed: rejected (not a valid actor target)")
        return
    EndIf

    ; --- Grab-suppression gate -----------------------------------------
    ; VRTouch_GrabGate is a STUB that returns False by default — so out of
    ; the box NOTHING is suppressed (everyone, incl. followers, is grabbed
    ; and reacts normally).  An OPTIONAL patch overrides VRTouch_GrabGate.pex
    ; to return True for certain actors (e.g. active followers).  Returning
    ; HERE — before grab-record / choke detection / fire-scheduling —
    ; suppresses every grab consequence (grab triggers AND choke-by-grab)
    ; for that actor; the event never reaches SkyrimNet.  HIGGS's own
    ; physical grab is unaffected (you can still reposition them) and TOUCH
    ; still fires.  No hard dependency: without a patch this is a no-op.
    if VRTouch_GrabGate.ShouldSuppressGrab(akActor)
        if EnableDebugGrab
            Debug.Notification("VRTouch: grab suppressed by gate [" + akActor.GetDisplayName() + "]")
        EndIf
        Debug.Trace("[VRTouch] OnObjectGrabbed: grab suppressed by VRTouch_GrabGate, actor=" + akActor.GetDisplayName())
        return
    EndIf

    String nodeName = HiggsVR.GetGrabbedNodeName(isLeft)
    Debug.Trace("[VRTouch] OnObjectGrabbed: actor=" + akActor.GetDisplayName() + " node=" + nodeName + " hand=" + isLeft)

    if EnableDebugGrab
        String hand = "R"
        if isLeft
            hand = "L"
        EndIf
        Debug.Notification("VRTouch GRAB [" + hand + "]: [" + nodeName + "]")
    EndIf

    ; Record grab (needed for "still held" kill check in TickChoke,
    ; and for hold-duration measurement on release)
    Float grabTime = Utility.GetCurrentRealTime()
    if isLeft
        grabActor_L = akActor
        grabNode_L  = nodeName
        grabStart_L = grabTime
    Else
        grabActor_R = akActor
        grabNode_R  = nodeName
        grabStart_R = grabTime
    EndIf

    ; --- Choke detection: chest-region grab + recent neck CBPC contact ---
    ; Uses NodeToBodyPart to match ANY chest/Spine2 variant HIGGS may report
    ; (the chest-grab path already works, so matching on its body part key
    ; guarantees we catch every nodeName the rest of the script recognizes).
    ; Window extended to 5.0s to tolerate slow grip formation in VR.
    if !chokeActive && NodeToBodyPart(nodeName) == "chest"
        Float now    = Utility.GetCurrentRealTime()
        Float neckAge = now - neckTime
        Bool  sameActor = (neckActor == akActor)

        ; Always-on diagnostic — helps diagnose why choke isn't firing
        if EnableDebug || EnableDebugGrab
            String nm = "none"
            if neckActor
                nm = neckActor.GetDisplayName()
            EndIf
            Debug.Notification("VRTouch: chest-grab check neck=" + nm + " sameActor=" + sameActor + " age=" + neckAge)
        EndIf
        if EnableDebug || EnableDebugGrab
            Debug.Trace("[VRTouch] Choke check: node=" + nodeName + " grabActor=" + akActor.GetDisplayName() + " neckActor=" + neckActor + " sameActor=" + sameActor + " neckAge=" + neckAge)
        EndIf

        if sameActor && neckAge <= 5.0
            StartChoke(akActor)
            return  ; Skip normal grab trigger processing
        EndIf
    EndIf

    ; --- NO weapon-hand grab filter here (intentional, do NOT re-add) ----
    ; A HIGGS grab of a body part can ONLY fire on a physically EMPTY hand:
    ; HIGGS shares the grip button with weapon-holding, so CanGrabObject
    ; requires "no weapon in the hand" before OnObjectGrabbed ever fires.
    ; An earlier filter gated on GetEquippedWeapon(hand) && IsWeaponDrawn(),
    ; but in VR BOTH legs are false-positive prone:
    ;   * IsWeaponDrawn() is a GLOBAL combat-stance flag, true for readied
    ;     MAGIC too (not just weapons) — combat stance != hand busy in VR.
    ;   * GetEquippedWeapon() returns a weapon merely equipped/SHEATHED on
    ;     the body, not one physically in this hand.
    ; Together they wrongly suppressed legit bare-hand grabs (sheathed sword
    ; + fire readied in the other hand) and BROKE CHOKING.  The case the
    ; filter meant to catch — grabbing with a weapon IN the grabbing hand —
    ; is unreachable (HIGGS won't grab with an occupied hand), so there is
    ; nothing to filter.  Removed deliberately.  See KNOWLEDGEBASE.md.

    ; --- Cancel pending touch in same region (grab supersede) ---
    String bodyPart = NodeToBodyPart(nodeName)
    if bodyPart != ""
        String region = VRTouch_TriggerLib.GetRegion(bodyPart)
        if pendActive && !pendIsGrab && pendRegion == region && pendActor == akActor
            pendActive = False
            if EnableDebugGrab
                Debug.Notification("VRTouch: grab superseded pending touch")
            EndIf
        EndIf
    EndIf

    ; --- Schedule fire-during-hold ---
    ; Resolve body part NOW (correlation markers are fresh from the
    ; approach phase) and compute the dwell delay.  The trigger will
    ; fire DURING the hold once the dwell has elapsed — not on release.
    ; OnObjectDropped checks grabFired_* and skips re-firing.
    String resolvedBP = ""
    if bodyPart != ""
        resolvedBP = ResolveGrab(akActor, bodyPart, grabTime)
    EndIf
    if resolvedBP != ""
        Int armorState = GetArmorState(akActor, resolvedBP)
        String triggerName = VRTouch_TriggerLib.GetTriggerName(resolvedBP, True, armorState)
        if triggerName != ""
            Float delay = VRTouch_TriggerLib.GetDelay(resolvedBP, True, armorState) * DelayMultiplier
            if isLeft
                grabFireAt_L = grabTime + delay
                grabFired_L  = False
            Else
                grabFireAt_R = grabTime + delay
                grabFired_R  = False
            EndIf
            ScheduleNextUpdate()
            Debug.Trace("[VRTouch] Grab dwell scheduled: hand=" + isLeft + " bp=" + resolvedBP + " delay=" + delay + "s trigger=" + triggerName)
            VTLog("GRAB " + resolvedBP + " hand=" + isLeft + " -> " + triggerName + " (dwell " + delay + "s) | " + WeaponStateStr())
        EndIf
    EndIf
EndEvent

; ================================================================
; HIGGS Release — check for choke release, then fire grab trigger
; ================================================================
Event OnObjectDropped(ObjectReference refr, Bool isLeft)
    Debug.Trace("[VRTouch] OnObjectDropped FIRED: isLeft=" + isLeft + " refr=" + refr)
    Actor  droppedActor
    String droppedNode
    Float  grabStartTime
    Bool   alreadyFiredDuringHold

    if isLeft
        droppedActor   = grabActor_L
        droppedNode    = grabNode_L
        grabStartTime  = grabStart_L
        alreadyFiredDuringHold = grabFired_L
        grabActor_L    = None
        grabNode_L     = ""
        grabStart_L    = 0.0
        grabFireAt_L   = 0.0
        grabFired_L    = False
    Else
        droppedActor   = grabActor_R
        droppedNode    = grabNode_R
        grabStartTime  = grabStart_R
        alreadyFiredDuringHold = grabFired_R
        grabActor_R    = None
        grabNode_R     = ""
        grabStart_R    = 0.0
        grabFireAt_R   = 0.0
        grabFired_R    = False
    EndIf

    if !droppedActor
        Debug.Trace("[VRTouch] OnObjectDropped: rejected (no recorded grab actor on this hand)")
        return
    EndIf

    ; If the trigger already fired during the hold (dwell elapsed
    ; while still gripping), the release is a no-op.  Choke release
    ; logic below still runs since chest grabs don't follow the
    ; fire-during-hold path (they go through StartChoke instead).
    if alreadyFiredDuringHold
        Debug.Trace("[VRTouch] OnObjectDropped: already fired during hold, release is silent")
        ; Still fall through for choke-release detection
    EndIf

    Float holdDuration = Utility.GetCurrentRealTime() - grabStartTime
    Debug.Trace("[VRTouch] OnObjectDropped: actor=" + droppedActor.GetDisplayName() + " node=" + droppedNode + " held=" + holdDuration + "s")

    ; --- Choke release ---
    ; Any chest-region release while choke is active matters:
    ;   - Pre-passout:  cancel the choke (EndChoke tears everything down,
    ;                   fires the release LLM trigger, restores HP/regen).
    ;   - Post-passout: DO NOT call EndChoke — we still need TickChoke to
    ;                   keep running so the wake timer and heal-to-wake
    ;                   polling fire.  EndChoke sets chokeActive=False,
    ;                   which kills the OnUpdate tick loop entirely —
    ;                   the bug that made passed-out NPCs stay down
    ;                   forever.  Instead just note the release (grab
    ;                   slots are already cleared above) and let the
    ;                   tick loop continue.  Kill-at-25s already gates
    ;                   on stillHeld, so letting go correctly stops the
    ;                   kill countdown without stopping the wake watch.
    if chokeActive && chokeActor == droppedActor
        if NodeToBodyPart(droppedNode) == "chest"
            if !chokePassedOut
                EndChoke(False)  ; pre-passout cancel
            EndIf
            return               ; Skip normal grab trigger regardless
        EndIf
    EndIf

    ; If we already fired during the hold, skip the release-fire path.
    ; Choke detection above (chest+neck) already returned early; from
    ; here on it's only the regular release-trigger logic.
    if alreadyFiredDuringHold
        return
    EndIf

    Float now = Utility.GetCurrentRealTime()

    ; --- Resolve body part ---
    String bodyPart = NodeToBodyPart(droppedNode)
    if bodyPart == ""
        bodyPart = "body"
    EndIf

    ; --- Apply cross-node correlation for grab ---
    bodyPart = ResolveGrab(droppedActor, bodyPart, now)
    if bodyPart == ""
        return
    EndIf

    ; --- Armor state ---
    Int armorState = GetArmorState(droppedActor, bodyPart)

    ; --- Trigger lookup ---
    String triggerName = VRTouch_TriggerLib.GetTriggerName(bodyPart, True, armorState)
    if triggerName == ""
        if EnableDebugGrab
            String hand = "R"
            if isLeft
                hand = "L"
            EndIf
            Debug.Notification("VRTouch RELEASE [" + hand + "]: no trigger [" + bodyPart + "]")
        EndIf
        return
    EndIf

    Float delay = VRTouch_TriggerLib.GetDelay(bodyPart, True, armorState) * DelayMultiplier
    Bool interrupting = VRTouch_TriggerLib.IsInterrupting(bodyPart, True, armorState)

    ; --- Per-NPC cooldown ---
    if !interrupting && IsOnNpcCooldown(droppedActor)
        return
    EndIf

    ; --- Build reaction ---
    String armorName = GetLastArmorName()
    String npcName    = droppedActor.GetDisplayName()
    String playerName = playerRef.GetDisplayName()
    String reaction   = VRTouch_TriggerLib.GetReaction(bodyPart, True, armorState, npcName, playerName, armorName)

    ; --- Dwell check for grab ---
    ; Grab must have been held for at least `delay` seconds before release.
    ; Hold too short (brief brush of hand) -> silently suppress, no trigger.
    if holdDuration < delay
        Debug.Trace("[VRTouch] OnObjectDropped: rejected (held " + holdDuration + "s < required " + delay + "s) trigger=" + triggerName)
        VTLog("GRAB released too short: " + triggerName + " held=" + holdDuration + "s need=" + delay + "s")
        if EnableDebugGrab
            String hshort = "R"
            if isLeft
                hshort = "L"
            EndIf
            Debug.Notification("VRTouch grab too short [" + hshort + "]: " + triggerName + " held=" + holdDuration + "s need=" + delay + "s")
        EndIf
        return
    EndIf
    Debug.Trace("[VRTouch] OnObjectDropped: FIRING grab trigger=" + triggerName + " held=" + holdDuration + "s required=" + delay + "s")

    if EnableDebugGrab
        String hand2 = "R"
        if isLeft
            hand2 = "L"
        EndIf
        Debug.Notification("VRTouch FIRED grab [" + hand2 + "]: " + triggerName + " held " + holdDuration + "s")
    EndIf

    ; Held long enough -> fire immediately (dwell already satisfied)
    Bool isThg = VRTouch_TriggerLib.IsThought(bodyPart, True, armorState)
    FireTrigger(droppedActor, triggerName, reaction, interrupting, isThg)
EndEvent

; ================================================================
; Pending event queue + OnUpdate
; ================================================================
Function QueueEvent(Actor akActor, String trigger, String reaction, String region, Bool isGrab, Float delay, Bool interrupting, String bodyPart, Bool asThought = False)
    ; Immediate fire for zero delay
    if delay <= 0.01
        if EnableDebug || EnableDebugGrab
            Debug.Notification("VRTouch PATH=IMMEDIATE (delay=" + delay + ")")
        EndIf
        FireTrigger(akActor, trigger, reaction, interrupting, asThought)
        return
    EndIf

    ; Grab supersede: if pending touch in same region, cancel it
    if pendActive && !pendIsGrab && isGrab && pendRegion == region && pendActor == akActor
        ; Release tail activation block if the superseded event was a tail touch
        if pendIsTailTouch
            pendActor.BlockActivation(false)
        EndIf
        pendIsTailTouch = False
        pendActive      = False
    EndIf

    ; Can't queue if already pending
    if pendActive
        return
    EndIf

    pendActor        = akActor
    pendTrigger      = trigger
    pendReaction     = reaction
    pendRegion       = region
    pendIsGrab       = isGrab
    pendInterrupting = interrupting
    Float nowTime    = Utility.GetCurrentRealTime()
    pendFireAt       = nowTime + delay
    pendLastContact  = nowTime   ; initial contact heartbeat
    ; 2026-09-15 (V2.1 CBPC build): tails are not mapped, so a pending event can
    ; never be a tail touch.  Held False so the BlockActivation path stays dormant
    ; (it is still released correctly on reset, exactly as before).
    pendIsTailTouch  = False
    pendThought      = asThought
    pendActive       = True

    ; Block NPC activation while a tail touch is pending
    if pendIsTailTouch
        akActor.BlockActivation(true)
    EndIf

    ; Schedule wake considering both pending event and any active choke tick
    ScheduleNextUpdate()
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

    if pendActive
        Float w = pendFireAt - now
        if w < 0.05
            w = 0.05
        EndIf
        if w < nextWake
            nextWake = w
        EndIf
    EndIf

    if chokeActive
        Float w = chokeNextTick - now
        if w < 0.05
            w = 0.05
        EndIf
        if w < nextWake
            nextWake = w
        EndIf
    EndIf

    ; Grab dwell: fire-during-hold for each hand
    if grabActor_L != None && !grabFired_L
        Float w = grabFireAt_L - now
        if w < 0.05
            w = 0.05
        EndIf
        if w < nextWake
            nextWake = w
        EndIf
    EndIf
    if grabActor_R != None && !grabFired_R
        Float w = grabFireAt_R - now
        if w < 0.05
            w = 0.05
        EndIf
        if w < nextWake
            nextWake = w
        EndIf
    EndIf

    ; Weapon-touch dwell deadline
    if wpnActive
        Float w = (wpnStart + WeaponDwell) - now
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

    ; --- Pending event ---
    if pendActive
        if now >= (pendFireAt - 0.05)
            ; Time to fire — but first verify the player is still in contact.
            ; If no CBPC refresh in the last 0.4s, contact was broken before
            ; the dwell expired -> silently cancel (no trigger fires).
            ; Grabs skip this check; their dwell is measured on release.
            Bool  contactOK = True
            if !pendIsGrab
                if (now - pendLastContact) > 0.4
                    contactOK = False
                EndIf
            EndIf

            if pendIsTailTouch
                pendActor.BlockActivation(false)
            EndIf
            Actor  a    = pendActor
            String t    = pendTrigger
            String r    = pendReaction
            Bool   intrp = pendInterrupting
            Bool   thg   = pendThought
            pendIsTailTouch = False
            pendActive      = False

            if contactOK
                if EnableDebug || EnableDebugGrab
                    Debug.Notification("VRTouch DWELL complete -> " + t)
                EndIf
                FireTrigger(a, t, r, intrp, thg)
            Else
                if EnableDebug || EnableDebugGrab
                    Debug.Notification("VRTouch DWELL cancel (contact lost): " + t)
                EndIf
            EndIf
        Else
            Float w = pendFireAt - now
            if w < nextWake
                nextWake = w
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

    ; --- Grab dwell fire (per hand) ---
    ; Fires the grab trigger AS SOON AS the hold-duration dwell elapses,
    ; while the player is still gripping.  OnObjectDropped checks
    ; grabFired_* and skips re-firing on release.
    if grabActor_L != None && !grabFired_L && now >= (grabFireAt_L - 0.05)
        FireGrabHold(True)
    ElseIf grabActor_L != None && !grabFired_L
        Float w = grabFireAt_L - now
        if w < nextWake
            nextWake = w
        EndIf
    EndIf
    if grabActor_R != None && !grabFired_R && now >= (grabFireAt_R - 0.05)
        FireGrabHold(False)
    ElseIf grabActor_R != None && !grabFired_R
        Float w = grabFireAt_R - now
        if w < nextWake
            nextWake = w
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

    ; --- Weapon-touch dwell ---
    ; Fires once the weapon has held one region for WeaponDwell seconds of
    ; uninterrupted contact; drops the whole event if contact lapsed (>0.4s
    ; with no refresh) before the second was up.
    if wpnActive
        if (now - wpnLastContact) > 0.4
            if EnableDebug || EnableDebugGrab
                Debug.Notification("VRTouch WEAPON dwell cancel (contact lost): " + wpnRegion)
            EndIf
            VTLog("WEAPON dwell cancel (contact lost): " + wpnRegion)
            wpnActive = False
        ElseIf now >= (wpnStart + WeaponDwell - 0.05)
            Actor  a   = wpnActor
            String cat = wpnRegion
            Bool   il  = wpnIsLeft
            wpnActive  = False
            FireWeaponTrigger(a, cat, il)
        Else
            Float w = (wpnStart + WeaponDwell) - now
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
; FireGrabHold — fire the grab trigger DURING the hold (not on release)
; once the per-bodypart dwell has elapsed.  Marks grabFired_* so
; OnObjectDropped doesn't double-fire on release.
; ================================================================
Function FireGrabHold(Bool isLeft)
    Actor  a
    String node
    if isLeft
        a    = grabActor_L
        node = grabNode_L
        grabFired_L = True
    Else
        a    = grabActor_R
        node = grabNode_R
        grabFired_R = True
    EndIf
    if a == None
        return
    EndIf

    String bodyPart = NodeToBodyPart(node)
    if bodyPart == ""
        bodyPart = "body"
    EndIf
    Float now = Utility.GetCurrentRealTime()
    bodyPart = ResolveGrab(a, bodyPart, now)
    if bodyPart == ""
        return
    EndIf

    Int armorState = GetArmorState(a, bodyPart)
    String triggerName = VRTouch_TriggerLib.GetTriggerName(bodyPart, True, armorState)
    if triggerName == ""
        return
    EndIf

    Bool interrupting = VRTouch_TriggerLib.IsInterrupting(bodyPart, True, armorState)
    String armorName  = GetLastArmorName()
    String npcName    = a.GetDisplayName()
    String playerName = playerRef.GetDisplayName()
    String reaction   = VRTouch_TriggerLib.GetReaction(bodyPart, True, armorState, npcName, playerName, armorName)

    Debug.Trace("[VRTouch] Grab dwell ELAPSED -> firing during hold: hand=" + isLeft + " trigger=" + triggerName)
    if EnableDebugGrab
        String h = "R"
        if isLeft
            h = "L"
        EndIf
        Debug.Notification("VRTouch FIRED grab [" + h + "] (during hold): " + triggerName)
    EndIf

    ; --- Choke gag for grabs ---
    ; While this NPC is being strangled, a normal VOICED grab reaction must
    ; not fire (they can't speak).  The CHOKING hand's own grab is part of
    ; the choke — silent.  The OTHER hand grabbing them becomes an UNVOICED
    ; thought: it registers in their mind without producing speech.
    ; (GenerateNPCThought self-skips if they're unconscious/dead.)
    if chokeActive && a == chokeActor
        if isLeft != chokeIsLeft && !modOff   ; !modOff: don't leak the thought mid-scene
            SkyrimNetApi.GenerateNPCThought(a, playerName + "'s free hand seizes your " + bodyPart + " while their other hand stays locked around your throat")
        EndIf
        return
    EndIf

    Bool isThg = VRTouch_TriggerLib.IsThought(bodyPart, True, armorState)
    FireTrigger(a, triggerName, reaction, interrupting, isThg)

    ; Optional arousal for intimate grabs (squeeze / grope / penetrate).
    MaybeArousal(a, bodyPart, True, armorState, reaction)
EndFunction

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
        RegisterForModEvent("CBPCPlayerCollisionWithFemaleEvent",        "OnCBPC")
        RegisterForModEvent("CBPCPlayerCollisionWithMaleEvent",          "OnCBPC")
        RegisterForModEvent("CBPCPlayerGenitalCollisionWithFemaleEvent", "OnCBPC")
        RegisterForModEvent("CBPCPlayerGenitalCollisionWithMaleEvent",   "OnCBPC")
        RegisterForModEvent("VRTouchEvents_CBPCTouch", "OnVRTouchEvent")
        HiggsVR.RegisterForGrabEvent(Self)
        HiggsVR.RegisterForDropEvent(Self)
    Else
        UnregisterForModEvent("CBPCPlayerCollisionWithFemaleEvent")
        UnregisterForModEvent("CBPCPlayerCollisionWithMaleEvent")
        UnregisterForModEvent("CBPCPlayerGenitalCollisionWithFemaleEvent")
        UnregisterForModEvent("CBPCPlayerGenitalCollisionWithMaleEvent")
        UnregisterForModEvent("VRTouchEvents_CBPCTouch")
        HiggsVR.UnregisterForGrabEvent(Self)
        HiggsVR.UnregisterForDropEvent(Self)
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
; Fire trigger to SkyrimNet via YAML trigger system.
; ================================================================
Function FireTrigger(Actor akActor, String triggerName, String reaction, Bool interrupting, Bool asThought = False)
    ; Scene gate: suppress ALL triggers (including interrupting ones)
    ; while either the NPC or the player is in a SexLab or OStim scene.
    ; The base mod ships stub gates that always return False; optional
    ; patches override those stubs to consult the real scene state —
    ; see VRTouch_SexLabGate.psc and VRTouch_OStimGate.psc.
    if VRTouch_SexLabGate.IsInScene(akActor) || VRTouch_SexLabGate.IsInScene(playerRef) \
    || VRTouch_OStimGate.IsInScene(akActor)  || VRTouch_OStimGate.IsInScene(playerRef)
        VTLog("SUPPRESSED (scene gate): " + triggerName)
        if EnableDebug || EnableDebugGrab
            Debug.Notification("VRTouch SUPPRESSED (scene): " + triggerName)
        EndIf
        return
    EndIf

    ; Final per-NPC cooldown check (may have changed since queuing)
    if !interrupting && IsOnNpcCooldown(akActor)
        VTLog("SUPPRESSED (cooldown): " + triggerName)
        if EnableDebug || EnableDebugGrab
            Debug.Notification("VRTouch SUPPRESSED (cooldown): " + triggerName)
        EndIf
        return
    EndIf

    ; Gag gate: while an NPC is being choked, suppress every trigger
    ; targeting them EXCEPT the choke-chain triggers themselves (Short /
    ; Sustained / Severe / Passout).  During a choke the player's hands
    ; are physically on the NPC and will incidentally brush chest/arms/
    ; etc — those would otherwise fire touch events and make the
    ; supposedly-gagged NPC narrate lines.  SkyrimNet's actor blacklist
    ; faction only blocks *autonomous* LLM; explicit RegisterShortLived-
    ; Event calls like ours bypass it, so we need this script-side gate.
    if chokeActive && akActor == chokeActor
        if StringUtil.Find(triggerName, "VRTouch_Neck_Choke_") != 0
            VTLog("SUPPRESSED (choke gag): " + triggerName)
            if EnableDebug || EnableDebugGrab
                Debug.Notification("VRTouch SUPPRESSED (choked): " + triggerName)
            EndIf
            return
        EndIf
    EndIf

    ; --- Schema-designated THOUGHT (column 7 = "Though") ---
    ; Light / incidental / over-armor contact: the NPC just NOTICES it
    ; internally.  Fire an unvoiced GenerateNPCThought (the reaction text
    ; becomes the hint) instead of a spoken RegisterShortLivedEvent — it
    ; colors their later lines without making them blurt something out.
    ; Still gated by scene / cooldown / choke-gag above.  Self-skips if
    ; the NPC is unconscious/dead.
    if asThought
        SkyrimNetApi.GenerateNPCThought(akActor, reaction)
        RecordCdFire(akActor)
        VTLog("THOUGHT " + triggerName + " on " + akActor.GetDisplayName() + " | " + WeaponStateStr())
        return
    EndIf

    ; Build structured event data for YAML template variables
    String npcName   = akActor.GetDisplayName()
    String plrName   = playerRef.GetDisplayName()
    String clothName = GetLastArmorName()
    String d = "{\"trigger_name\":\"" + triggerName + "\"," + \
               "\"touched\":\"" + npcName + "\"," + \
               "\"toucher\":\"" + plrName + "\"," + \
               "\"clothing_name\":\"" + clothName + "\"}"

    String eid = "vrtouch_" + akActor.GetFormID() + "_" + (Utility.GetCurrentRealTime() as Int)

    SkyrimNetApi.RegisterShortLivedEvent(eid, "vrtouch_event", "*" + reaction + "*", d, 15000, akActor, playerRef)
    RecordCdFire(akActor)
    VTLog("FIRED " + triggerName + " on " + npcName + " | clothing=" + clothName + " | " + WeaponStateStr())

    if EnableDebug || EnableDebugGrab
        Debug.Notification("VRTouch FIRED -> " + triggerName)
    EndIf
EndFunction

; ================================================================
; Wand/source tag buffer helpers (fed by VRTouchEvents.dll)
; ================================================================
; Store one (actor,node)->code tag in the ring buffer.
Function StoreTouchTag(Actor a, String node, Int code, Float now)
    if tagActor.Length < 16
        return
    EndIf
    tagActor[tagNext] = a
    tagNode[tagNext]  = node
    tagCode[tagNext]  = code
    tagTime[tagNext]  = now
    tagNext += 1
    if tagNext >= 16
        tagNext = 0
    EndIf
EndFunction

; Return the freshest tag code for (actor,node) within TagFreshWindow,
; or -1 if none.  code>=10 means WEAPON; code%10 is the wand.
Int Function GetTouchTag(Actor a, String node, Float now)
    if a == None || tagActor.Length < 16
        return -1
    EndIf
    Int   best     = -1
    Float bestTime = -1.0
    Int i = 0
    while i < 16
        if tagActor[i] == a && tagNode[i] == node
            if (now - tagTime[i]) <= TagFreshWindow && tagTime[i] > bestTime
                best     = tagCode[i]
                bestTime = tagTime[i]
            EndIf
        EndIf
        i += 1
    EndWhile
    return best
EndFunction

; Human-readable wand from a tag code (internal logging only).
String Function WandStr(Int code)
    if code < 0
        return "?"
    EndIf
    Int w = code % 10
    if w == 1
        return "R"
    ElseIf w == 2
        return "L"
    ElseIf w == 3
        return "both"
    EndIf
    return "?"
EndFunction

; ================================================================
; Weapon-touch helpers
; ================================================================
; Map a CBPC node to a CATEGORY-level body region for weapon narration
; (coarser than NodeToBodyPart — weapons are gesture-level, not specific).
; Includes the neck -> "throat" (weapon awareness; never the choke).
; Order matters: backside is tested before leg so RearThigh isn't caught
; as a leg.  Returns "" for unmapped nodes (e.g. tails, COM) -> ignored.
String Function NodeToWeaponCategory(String n)
    if n == "CME Neck [Neck]" || n == "NPC Neck [Neck]" || n == "NPC Neck"
        return "throat"
    EndIf
    if n == "CME Face [Face]"
        return "face"
    EndIf
    if n == "CME Head [Head]" || n == "NPC Head [Head]" || n == "NPC Head" || n == "NPCEyeBone"
        return "head"
    EndIf
    if StringUtil.Find(n, "Breast") >= 0
        return "chest"
    EndIf
    if n == "CME Spine2 [Spn2]" || n == "NPC Spine2 [Spn2]" || n == "NPC Spine2"
        return "chest"
    EndIf
    if n == "CME Spine1 [Spn1]" || n == "NPC Spine1 [Spn1]" || n == "NPC Spine1" || n == "HDT Belly"
        return "stomach"
    EndIf
    if n == "CME Back [Back]"
        return "back"
    EndIf
    if StringUtil.Find(n, "Butt") >= 0 || StringUtil.Find(n, "RearThigh") >= 0
        return "backside"
    EndIf
    if n == "NPC Pelvis [Pelv]" || n == "NPC Pelvis" || StringUtil.Find(n, "Genitals") >= 0
        return "groin"
    EndIf
    if StringUtil.Find(n, "UpperArm") >= 0 || StringUtil.Find(n, "Forearm") >= 0
        return "arm"
    EndIf
    if StringUtil.Find(n, "Hand") >= 0 || StringUtil.Find(n, "Finger") >= 0
        return "hand"
    EndIf
    if StringUtil.Find(n, "Thigh") >= 0 || StringUtil.Find(n, "Calf") >= 0
        return "leg"
    EndIf
    if StringUtil.Find(n, "Foot") >= 0
        return "foot"
    EndIf
    return ""
EndFunction

; Human-readable weapon word.  Keyword-first (per KB: splits a type-6
; battleaxe from a type-6 warhammer, and works for modded weapons that
; carry the vanilla WeapType* keywords); falls back to GetWeaponType.
String Function WeaponWord(Weapon w)
    if w == None
        return "weapon"
    EndIf
    if w.HasKeywordString("WeapTypeSword")
        return "sword"
    ElseIf w.HasKeywordString("WeapTypeGreatsword")
        return "greatsword"
    ElseIf w.HasKeywordString("WeapTypeDagger")
        return "dagger"
    ElseIf w.HasKeywordString("WeapTypeWarAxe")
        return "war axe"
    ElseIf w.HasKeywordString("WeapTypeBattleaxe")
        return "battleaxe"
    ElseIf w.HasKeywordString("WeapTypeMace")
        return "mace"
    ElseIf w.HasKeywordString("WeapTypeWarhammer")
        return "warhammer"
    ElseIf w.HasKeywordString("WeapTypeBow")
        return "bow"
    ElseIf w.HasKeywordString("WeapTypeCrossbow")
        return "crossbow"
    ElseIf w.HasKeywordString("WeapTypeStaff")
        return "staff"
    EndIf
    Int wt = w.GetWeaponType()
    if wt == 1
        return "sword"
    ElseIf wt == 2
        return "dagger"
    ElseIf wt == 3
        return "war axe"
    ElseIf wt == 4
        return "mace"
    ElseIf wt == 5
        return "greatsword"
    ElseIf wt == 6
        return "battleaxe"
    ElseIf wt == 7
        return "bow"
    ElseIf wt == 8
        return "staff"
    ElseIf wt == 9
        return "crossbow"
    EndIf
    return "weapon"
EndFunction

; Sharp = bladed/edged.  Keyword-first so a type-6 battleaxe (sharp)
; splits from a type-6 warhammer (blunt).  Drives the interrupting alert.
Bool Function IsSharpWeapon(Weapon w)
    if w == None
        return False
    EndIf
    if w.HasKeywordString("WeapTypeSword") || w.HasKeywordString("WeapTypeGreatsword") \
    || w.HasKeywordString("WeapTypeDagger") || w.HasKeywordString("WeapTypeWarAxe") \
    || w.HasKeywordString("WeapTypeBattleaxe")
        return True
    EndIf
    if w.HasKeywordString("WeapTypeMace") || w.HasKeywordString("WeapTypeWarhammer")
        return False
    EndIf
    Int wt = w.GetWeaponType()
    ; 1 sword, 2 dagger, 3 war axe, 5 greatsword, 6 axe -> sharp.
    if wt == 1 || wt == 2 || wt == 3 || wt == 5 || wt == 6
        return True
    EndIf
    return False
EndFunction

; Fire a weapon-touch event to SkyrimNet.  Non-interrupting by default;
; throat contact (any weapon) or a sharp weapon uses the interrupting
; "alert" schema.  Same scene/gag/cooldown gating as the hand path.
Function FireWeaponTrigger(Actor akActor, String category, Bool isLeft)
    if akActor == None
        return
    EndIf
    ; Scene gate — suppress during SexLab/OStim scenes (either party).
    if VRTouch_SexLabGate.IsInScene(akActor) || VRTouch_SexLabGate.IsInScene(playerRef) \
    || VRTouch_OStimGate.IsInScene(akActor)  || VRTouch_OStimGate.IsInScene(playerRef)
        VTLog("WEAPON SUPPRESSED (scene gate): " + category)
        return
    EndIf
    ; Gag gate — never fire on an actively-choked NPC.
    if chokeActive && akActor == chokeActor
        VTLog("WEAPON SUPPRESSED (choke gag): " + category)
        return
    EndIf
    Weapon w         = playerRef.GetEquippedWeapon(isLeft)
    String word      = WeaponWord(w)
    Bool   sharp     = IsSharpWeapon(w)
    Bool   headZone  = IsHeadZone(category)        ; face / head / throat
    Bool   interrupt = sharp && headZone           ; the only "barge in now" case
    ; Schema (col 7) thought/speak for a weapon resting on a body region:
    ;   arms / hands / legs / feet / back        -> THOUGHT (any weapon, sharp or blunt)
    ;   chest / stomach (belly)                  -> THOUGHT only if blunt (sharp = speak)
    ;   head / face / throat / groin / backside  -> SPEAK (sharp head-zone = interrupt)
    Bool   wThought  = (category == "arm" || category == "hand" || category == "leg" || category == "foot" || category == "back")
    if !wThought && (category == "chest" || category == "stomach") && !sharp
        wThought = True
    EndIf
    Float  now       = Utility.GetCurrentRealTime()

    ; Cooldown: an INTERRUPT (sharp edge on face/head/throat) bypasses the general
    ; per-NPC cooldown so a real threat always lands, gated only by AlertCooldown.
    ; Thought + speak tiers respect the normal per-NPC cooldown to avoid spam.
    if interrupt
        if lastAlertActor == akActor && (now - lastAlertTime) < AlertCooldown
            VTLog("WEAPON interrupt SUPPRESSED (throttle): " + category)
            return
        EndIf
    ElseIf IsOnNpcCooldown(akActor)
        VTLog("WEAPON SUPPRESSED (cooldown): " + category)
        return
    EndIf

    String npcName = akActor.GetDisplayName()
    String plrName = playerRef.GetDisplayName()

    ; --- Tier 1 — THOUGHT (schema col 7: arms/hands/legs/feet/back, or blunt chest/belly) ---
    ; Unvoiced: colors the NPC's later lines, no immediate spoken reaction.
    if wThought
        String hint = plrName + " is resting the " + word + " they hold against your " + category + "."
        SkyrimNetApi.GenerateNPCThought(akActor, hint)
        RecordCdFire(akActor)
        VTLog("WEAPON THOUGHT " + word + " -> " + category + " on " + npcName + " | " + WeaponStateStr())
        return
    EndIf

    ; --- Tier 2/3 — the NPC reacts ALOUD (DirectNarration: originator speaks/responds) ---
    String content = plrName + " holds a " + word + " against " + npcName + "'s " + category + "."
    if category == "throat"
        content = plrName + " holds the " + word + " to " + npcName + "'s throat."
    EndIf

    if interrupt
        ; Tier 3 — sharp edge on face/head/throat: cut off whatever they're doing
        ; and make them answer NOW.
        content = plrName + " presses the edge of a " + word + " against " + npcName + "'s " + category + "."
        if category == "throat"
            content = plrName + " presses the blade of a " + word + " to " + npcName + "'s throat."
        EndIf
        SkyrimNetApi.TriggerInterruptDialogue(false)
        SkyrimNetApi.DirectNarration(content, akActor, playerRef)
        lastAlertActor = akActor
        lastAlertTime  = now
        VTLog("WEAPON INTERRUPT " + word + " -> " + category + " on " + npcName + " | " + WeaponStateStr())
    Else
        ; Tier 2 — speak aloud (blunt on face/head/throat, OR sharp elsewhere):
        ; the NPC reacts verbally without barging in.
        SkyrimNetApi.DirectNarration(content, akActor, playerRef)
        RecordCdFire(akActor)
        VTLog("WEAPON SPEAK " + word + " -> " + category + " on " + npcName + " | " + WeaponStateStr())
    EndIf
    if EnableDebug || EnableDebugGrab
        Debug.Notification("VRTouch WEAPON -> " + word + " on " + category)
    EndIf
EndFunction

; Face / head / throat — the "react aloud" zone for weapons.
Bool Function IsHeadZone(String category)
    return category == "throat" || category == "face" || category == "head"
EndFunction

; ================================================================
; Arousal feature (optional)
; ================================================================
; Called when a touch/grab reaction fires.  For intimate body parts (baseline
; arousal > 0) it asks the LLM, via the vrtouch_arousal prompt, for a
; personality/relationship-adjusted arousal delta + a facial expression, then
; the callback applies them.  Cooldown-gated + single-in-flight so it never
; spams.  No-op entirely if the arousal backend isn't installed.
Function MaybeArousal(Actor akActor, String bp, Bool isGrab, Int arm, String narration)
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
    Float baseline = VRTouch_TriggerLib.GetArousal(bp, isGrab, arm)
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

; Player weapon context at the moment of an interaction — the key datum
; for diagnosing "the NPC reacted to my weapon as if it were my hand".
String Function WeaponStateStr()
    String drawn = "sheathed"
    if playerRef.IsWeaponDrawn()
        drawn = "DRAWN"
    EndIf
    Weapon wr = playerRef.GetEquippedWeapon(False)   ; right hand
    Weapon wl = playerRef.GetEquippedWeapon(True)    ; left hand
    String rs = "empty"
    if wr
        rs = wr.GetName()
    EndIf
    String ls = "empty"
    if wl
        ls = wl.GetName()
    EndIf
    return "weapons[" + drawn + " R=" + rs + " L=" + ls + "]"
EndFunction

; ================================================================
; Per-NPC cooldown helpers
; ================================================================
Int Function FindCdSlot(Actor akActor)
    Int i = 0
    while i < 16
        if cdActor[i] == akActor
            return i
        EndIf
        i += 1
    EndWhile
    return -1
EndFunction

; True if akActor has a recorded fire inside the GlobalCooldown window.
Bool Function IsOnNpcCooldown(Actor akActor)
    if akActor == None
        return False
    EndIf
    Int idx = FindCdSlot(akActor)
    if idx < 0
        return False
    EndIf
    return (Utility.GetCurrentRealTime() - cdTime[idx]) < GlobalCooldown
EndFunction

; Stamp akActor's slot with the current real time.  Overwrites the
; existing slot, claims an empty one, or evicts the oldest.
Function RecordCdFire(Actor akActor)
    if akActor == None
        return
    EndIf
    Float now = Utility.GetCurrentRealTime()
    Int idx = FindCdSlot(akActor)
    if idx >= 0
        cdTime[idx] = now
        return
    EndIf
    Int i = 0
    while i < 16
        if cdActor[i] == None
            cdActor[i] = akActor
            cdTime[i]  = now
            return
        EndIf
        i += 1
    EndWhile
    ; All slots full — evict oldest (lowest cdTime).
    Int oldestIdx = 0
    Float oldestTime = cdTime[0]
    i = 1
    while i < 16
        if cdTime[i] < oldestTime
            oldestTime = cdTime[i]
            oldestIdx  = i
        EndIf
        i += 1
    EndWhile
    cdActor[oldestIdx] = akActor
    cdTime[oldestIdx]  = now
EndFunction

; ================================================================
; IsGrabbingChest — True if either hand is currently gripping the
; given actor's chest/Spine2. Used by the OnCBPC neck reverse-trigger
; to start a choke when the grab was established BEFORE the CBPC
; neck sphere finally registered a hit.
; ================================================================
Bool Function IsGrabbingChest(Actor a)
    if grabActor_L == a && NodeToBodyPart(grabNode_L) == "chest"
        return True
    EndIf
    if grabActor_R == a && NodeToBodyPart(grabNode_R) == "chest"
        return True
    EndIf
    return False
EndFunction

; ================================================================
; Set correlation markers (called before resolve)
; ================================================================
Function SetMarkers(Actor akActor, String bodyPart, Float now)
    if bodyPart == "left_breast"
        breastActor = akActor
        breastTime  = now
        breastSide  = "L"
    ElseIf bodyPart == "right_breast"
        breastActor = akActor
        breastTime  = now
        breastSide  = "R"
    ElseIf bodyPart == "belly"
        bellyActor = akActor
        bellyTime  = now
    ElseIf bodyPart == "butt"
        buttActor = akActor
        buttTime  = now
    ElseIf bodyPart == "face"
        faceActor = akActor
        faceTime  = now
    EndIf
EndFunction

; ================================================================
; Correlation: resolve TOUCH body part
; ================================================================
String Function ResolveTouch(Actor akActor, String bodyPart, Float now)
    if bodyPart == "chest"
        ; 2026-09-15 (V2.1 CBPC build): BACK TOUCH REMOVED.  The back correlation
        ; marker is no longer supported on CBPC, so a chest contact stays a chest
        ; contact and never promotes to "upper_back".
        if breastActor == akActor && (now - breastTime) <= MarkerWindow
            return ""
        EndIf
        return "chest"
    EndIf

    if bodyPart == "belly"
        ; 2026-09-15 (V2.1 CBPC build): BACK TOUCH REMOVED - no "lower_back".
        return "belly"
    EndIf

    if bodyPart == "com"
        if buttActor == akActor && (now - buttTime) <= MarkerWindow
            return "butt"
        EndIf
        if backActor == akActor && (now - backTime) <= BackWindow
            return "butt"
        EndIf
        return "genitals"
    EndIf

    if bodyPart == "genitals"
        ; Pelvis / Genitals01 is front by default.  If the back was
        ; touched recently for the same actor, the hand approached
        ; from behind — promote to butt.
        if backActor == akActor && (now - backTime) <= BackWindow
            return "butt"
        EndIf
        return "genitals"
    EndIf

    return bodyPart
EndFunction

; ================================================================
; Correlation: resolve GRAB body part
; ================================================================
String Function ResolveGrab(Actor akActor, String bodyPart, Float now)
    if bodyPart == "head"
        if faceActor == akActor && (now - faceTime) <= MarkerWindow
            return "face_hold"
        EndIf
        return "head"
    EndIf

    if bodyPart == "chest"
        if breastActor == akActor && (now - breastTime) <= MarkerWindow
            if breastSide == "L"
                return "left_breast"
            EndIf
            return "right_breast"
        EndIf
        ; 2026-09-15 (V2.1 CBPC build): BACK TOUCH REMOVED - no "upper_back".
        return ""
    EndIf

    if bodyPart == "belly"
        if bellyActor == akActor && (now - bellyTime) <= MarkerWindow
            return "belly"
        EndIf
        ; 2026-09-15 (V2.1 CBPC build): BACK TOUCH REMOVED - no "lower_back".
        return ""
    EndIf

    if bodyPart == "com"
        if buttActor == akActor && (now - buttTime) <= MarkerWindow
            return "butt"
        EndIf
        if backActor == akActor && (now - backTime) <= BackWindow
            return "butt"
        EndIf
        return "genitals"
    EndIf

    if bodyPart == "genitals"
        if backActor == akActor && (now - backTime) <= BackWindow
            return "butt"
        EndIf
        return "genitals"
    EndIf

    return bodyPart
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

String Function GetLastArmorName()
    if lastArmor
        return lastArmor.GetName()
    EndIf
    return ""
EndFunction

; ================================================================
; Node -> Body Part mapping
; ================================================================
String Function NodeToBodyPart(String n)
    ; --- Breasts ---
    if n == "L Breast01" || n == "L Breast02" || n == "L Breast03" || n == "NPC L Breast"
        return "left_breast"
    EndIf
    if n == "R Breast01" || n == "R Breast02" || n == "R Breast03" || n == "NPC R Breast"
        return "right_breast"
    EndIf

    ; --- Butt ---
    if n == "NPC L Butt" || n == "NPC R Butt" || n == "NPC L RearThigh" || n == "NPC R RearThigh"
        return "butt"
    EndIf

    ; --- Belly (physics node) ---
    if n == "HDT Belly"
        return "belly"
    EndIf

    ; --- Genitals (single node only — Genitals01) ---
    ; Only the primary CME Genitals01 bone fires "genitals" — the other
    ; nearby genital bones (GenitalsBase, GenitalsScrotum, Genitals02-06)
    ; are too close together and would spam events for a single touch.
    ; SexLab/OStim spam is now handled by the scene gates (VRTouch_SexLabGate
    ; / VRTouch_OStimGate), so it's safe to map this directly.  ResolveTouch
    ; promotes "genitals" to "butt" via the back-marker correlation.
    if n == "CME Genitals01 [Gen01]" || n == "NPC Genitals01"
        return "genitals"
    EndIf

    ; --- Face ---
    if n == "CME Face [Face]"
        return "face"
    EndIf

    ; --- Head ---
    if n == "CME Head [Head]" || n == "NPC Head [Head]" || n == "NPC Head" || n == "NPCEyeBone"
        return "head"
    EndIf

    ; --- Chest / Spine2 ---
    if n == "CME Spine2 [Spn2]" || n == "NPC Spine2 [Spn2]" || n == "NPC Spine2"
        return "chest"
    EndIf

    ; --- Belly / Spine1 ---
    if n == "CME Spine1 [Spn1]" || n == "NPC Spine1 [Spn1]" || n == "NPC Spine1"
        return "belly"
    EndIf

    ; --- COM (grab: genitals or butt via correlation) ---
    ; HIGGS returns the bone name with a TRAILING SPACE inside the
    ; brackets — "NPC COM [COM ]", not "NPC COM [COM]".  Both forms
    ; covered to be safe.  CBPC never fires touch events on this bone;
    ; this branch is reached only via OnObjectGrabbed/OnObjectDropped.
    if n == "NPC COM [COM ]" || n == "NPC COM [COM]" || n == "NPC COM"
        return "com"
    EndIf

    ; --- Pelvis (front-facing region — promoted to "butt" via back marker) ---
    ; CBPC fires "NPC Pelvis [Pelv]" reliably for the lower-front body.
    ; ResolveTouch checks the back marker: if the back was just touched,
    ; pelvis becomes "butt"; otherwise it stays "genitals".  SexLab/OStim
    ; spam is gated upstream by the scene gates.
    if n == "NPC Pelvis [Pelv]" || n == "NPC Pelvis"
        return "genitals"
    EndIf

    ; --- Arms ---
    if n == "CME L UpperArm [LUar]" || n == "NPC L UpperArm [LUar]" || n == "NPC L UpperArm"
        return "arms"
    EndIf
    if n == "CME L Forearm [LLar]" || n == "NPC L Forearm [LLar]" || n == "NPC L Forearm"
        return "arms"
    EndIf
    if n == "CME R UpperArm [RUar]" || n == "NPC R UpperArm [RUar]" || n == "NPC R UpperArm"
        return "arms"
    EndIf
    if n == "CME R Forearm [RLar]" || n == "NPC R Forearm [RLar]" || n == "NPC R Forearm"
        return "arms"
    EndIf

    ; --- Hands ---
    if n == "CME L Hand [LHnd]" || n == "CME L Finger21 [LF21]" || n == "NPC L Hand [LHnd]"
        return "hands"
    EndIf
    if n == "CME R Hand [RHnd]" || n == "CME R Finger21 [RF21]" || n == "NPC R Hand [RHnd]"
        return "hands"
    EndIf

    ; --- Legs ---
    if n == "CME L Thigh [LThg]" || n == "NPC L Thigh [LThg]" || n == "NPC L Thigh"
        return "legs"
    EndIf
    if n == "CME L Calf [LClf]" || n == "NPC L Calf [LClf]"
        return "legs"
    EndIf
    if n == "CME R Thigh [RThg]" || n == "NPC R Thigh [RThg]" || n == "NPC R Thigh"
        return "legs"
    EndIf
    if n == "CME R Calf [RClf]" || n == "NPC R Calf [RClf]"
        return "legs"
    EndIf

    ; --- Feet ---
    if n == "CME L Foot [Lft ]" || n == "NPC L Foot [Lft ]" || n == "NPC L Foot"
        return "feet"
    EndIf
    if n == "CME R Foot [Rft ]" || n == "NPC R Foot [Rft ]" || n == "NPC R Foot"
        return "feet"
    EndIf

    ; --- Tails: REMOVED 2026-09-15 (V2.1 CBPC build) ---
    ; Tail contact is no longer supported on CBPC.  The tail bones now fall
    ; through to the final `return ""` below and are ignored exactly like any
    ; other unmapped node, so nothing downstream ever sees tail_base/tail_tip.
    ; CBPCollisionConfig_Tails.txt and the two tail trigger YAMLs are not shipped.

    ; --- Neck / Spine0 — no trigger (handled as markers in OnCBPC) ---
    if n == "CME Neck [Neck]" || n == "NPC Neck [Neck]" || n == "NPC Neck"
        return ""
    EndIf
    if n == "NPC Spine [Spn0]" || n == "NPC Spine"
        return ""
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
    chokeFiredThought3  = False
    chokeFiredThought7  = False
    chokeWarnedNoSound  = False
    chokeIsKillRun      = isKillRun

    ; Which hand's controller grip is on the throat?  Liveness (TickChoke)
    ; polls THIS hand via HiggsVR.GetGrabbedObject so the choke holds until
    ; the grip is physically released — NOT until CBPC stops reporting the
    ; neck node.  Detect from HIGGS; fall back to the grab-tracking vars.
    if HiggsVR.GetGrabbedObject(True) == akActor
        chokeIsLeft = True
    ElseIf HiggsVR.GetGrabbedObject(False) == akActor
        chokeIsLeft = False
    Else
        chokeIsLeft = (grabActor_L == akActor)
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

    ; Cancel any locally-queued touch/grab event targeting the choked
    ; actor (the FireTrigger gag gate catches anything still in flight,
    ; but dropping it here avoids the SUPPRESSED spam at fire time).
    if pendActive && pendActor == akActor
        if pendIsTailTouch
            akActor.BlockActivation(False)  ; will be re-blocked below
        EndIf
        pendIsTailTouch = False
        pendActive      = False
    EndIf

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

    ; --- KILL-RUN short-circuit ---
    ; In kill-run mode the victim is already a KO-slot resident: voice
    ; is silenced, they're in the mute faction, activation is blocked.
    ; The slot (not the choke state machine) owns all of that.  On
    ; release (pre-25s) or death we must NOT touch NPC state — just
    ; reset the choke flags.  Slot cleanup on death is handled by
    ; TickKO's IsDead branch on the next 5s poll.
    if chokeIsKillRun
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
            Debug.Notification("VRTouch: KILL RUN END")
        EndIf
        return
    EndIf

    ; Note: EndChoke only runs for PRE-passout cancels now.  At 15s
    ; passout the quest hands off to the per-victim AME and resets
    ; chokeActive inline — so we never see chokePassedOut==True here.
    ; All wake/HealRate/unconscious logic lives in the AME's
    ; OnEffectFinish.

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

        FireTrigger(a, releaseTrigger, releaseNarr, True)
        ; Force the gasping reaction NOW: the passive vrtouch_event alone gets
        ; swallowed after a choke, so DirectNarration makes her actually respond.
        SkyrimNetApi.DirectNarration(releaseNarr, a, playerRef)
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
        ; single latched chokeIsLeft.
        if elapsed >= 1.0 && HiggsVR.GetGrabbedObject(True) != a && HiggsVR.GetGrabbedObject(False) != a \
        && grabActor_L != a && grabActor_R != a
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

        ; --- Liveness: the CONTROLLER GRIP, not the CBPC neck contact ---
        ; The neck node only ARMS the choke (hard to start, by design).  Once
        ; armed it holds until the player physically RELEASES the grip
        ; (HiggsVR.GetGrabbedObject stops returning the victim for the choking
        ; hand), the victim dies, or 15s passout.  The old 0.8s neck-freshness
        ; check ended the choke every time CBPC reported a node other than the
        ; neck (Spine2/breast as the victim squirms) — cancel+re-arm churn that
        ; fired a release tier on EVERY cycle (the "all three tiers fired" bug)
        ; and re-opened the gag gate so incidental touches leaked through.
        ; GetGrabbedObject is also immune to a missed OnObjectDropped.  The 1s
        ; settle guards against a hand-detection race right at StartChoke.
        ; End only when the victim is held by NEITHER hand AND is no longer
        ; grab-tracked.  Polling BOTH hands (not the single latched chokeIsLeft)
        ; fixes a VR mis-latch where HIGGS resolved the throat grab to the other
        ; hand than grab-tracking recorded — which false-ended the choke every
        ; tick and let the neck reverse-trigger re-arm it (the multi-fire bug).
        if elapsed >= 1.0 && HiggsVR.GetGrabbedObject(True) != a && HiggsVR.GetGrabbedObject(False) != a \
        && grabActor_L != a && grabActor_R != a
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

        ; --- 3s: first fear-thought (UNVOICED, private to the victim) ---
        ; A strangled NPC can't speak (gagged), so instead of a spoken line we
        ; push an internal THOUGHT that builds fear in their mind.  It surfaces
        ; in their later prompts, so the panic is already loaded when they're
        ; released and CAN finally react.  GenerateNPCThought is private to the
        ; thinker and self-skips if they're unconscious.  Backstop: the release
        ; narration still fires, so even if SkyrimNet's thought-cooldown drops
        ; this one, fear still lands.
        if elapsed >= 3.0 && !chokeFiredThought3
            chokeFiredThought3 = True
            ; While OFF for a scene we still CONSUME the milestone (so it can't fire
            ; late, all-at-once, on scene-end) but must NOT leak the thought to
            ; SkyrimNet — these direct SkyrimNetApi calls bypass FireTrigger's gate.
            if !modOff
                SkyrimNetApi.GenerateNPCThought(a, playerRef.GetDisplayName() + "'s hand is clamped tight around your throat, choking you — you can't break free, you're gasping and clawing for air, and fear is starting to take hold")
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

        ; --- 7s: escalated panic-thought (UNVOICED, victim still choked) ---
        if elapsed >= 7.0 && !chokeFiredThought7
            chokeFiredThought7 = True
            if !modOff   ; OFF for a scene: consume the milestone, don't leak the thought
                SkyrimNetApi.GenerateNPCThought(a, "The grip around your throat has only tightened — you still can't break free, your lungs are burning for air, and the pain and suffocation are spiking into raw panic and terror; you genuinely fear you might die")
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

            ; Fire passout narrative event BEFORE StartKOSlot so the
            ; gag gate (chokeActive && akActor==chokeActor) still
            ; permits the choke-chain trigger through.
            VTLog("CHOKE PASSOUT at elapsed=" + elapsed + "s on " + a.GetDisplayName())
            FireTrigger(a, "VRTouch_Neck_Choke_Passout", \
                a.GetDisplayName() + "'s eyes flutter and roll back as the last of their strength gives out — " + \
                "they go limp in " + playerRef.GetDisplayName() + "'s grasp, unconscious", True)

            StartKOSlot(a)

            chokeEndTime = Utility.GetCurrentRealTime()   ; arm re-arm lockout (passout end)
            ; Free the quest's single-slot choke state IMMEDIATELY so
            ; the player can choke another NPC and normal touches on
            ; OTHER actors keep working.  The AME owns the victim now.
            chokeActive         = False
            chokeActor          = None
            chokePassedOut      = False
            chokeFiredSustained = False
            chokeFiredWitnessed = False
            chokeWarnedNoSound  = False
            ; (chokeNextTick not rescheduled — tick loop exits on next
            ; OnUpdate because chokeActive is now False)
            return
        EndIf

        ; Active phase: tick every 0.5s to catch milestones promptly
        chokeNextTick = now + 0.5
    EndIf
    ; NOTE: No post-passout Else branch.  At 15s we cast the paralyze
    ; spell, hand off to the per-victim AME (VRTouch_ChokeEffectScript),
    ; and reset chokeActive=False — the AME owns wake-timer, heal-to-
    ; wake, kill-at-25s is dropped (player releases on passout in
    ; normal play; if they hold past 15s the NPC is just a ragdoll).
EndFunction
