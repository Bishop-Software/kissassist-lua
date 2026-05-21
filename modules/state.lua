-- All runtime state, organized into domain sub-tables.
-- Defaults sourced directly from DeclareOuters pre/main/post/global in kissassist.mac.
-- No logic here — pure data. Every other module imports this and reads/writes State fields.
-- Cross-module communication happens through State exclusively (star topology, no circular deps).

local State = {
    terminate = false,  -- main loop exit flag

    session = {
        role            = 'assist',
        assistAt        = 95,
        mainAssist      = '',
        mainAssistClass = '',
        mainAssistType  = '',
        originalRole    = '',
        iAmABard        = false,  -- set at startup from Me.Class
        iAmMA           = false,
        iAmDead         = false,
        zoneName        = '',
        iniFileName     = '',
        iniSet          = false,
        buffFileName    = 'KissAssist_Buffs.ini',
        infoFileName    = 'KissAssist_Info.ini',
        kissRevision    = '039',
        macroVer        = '1.0.0',
        macroName       = 'KissAssist',
        kissAssistVer   = '',
        loadFromIni     = false,
        forceAlias      = true,
        broadcastSay    = 'bc',
        danNetOn        = false,
        bindActive      = false,
        mercInGroup     = false,
        mercAssisting   = false,
        chaseAssist     = false,
        pullPath        = 'null',
        parseDPSTimer   = 0,
        heals           = false,  -- set by Heal.init; mirrors healsOn > 0; guards castMem
    },

    debug = {
        general   = false,
        all       = false,
        buffs     = false,
        cast      = false,
        chainpull = false,
        combat    = false,
        heals     = false,
        logging   = false,
        mez       = false,
        move      = false,
        pet       = false,
        pull      = false,
        rk        = false,
        time      = false,
    },

    combat = {
        aggroTargetID      = '',
        aggroTargetID2     = '0',
        attacking          = false,
        burnActive         = false,
        burnCalled         = false,
        burnOn             = true,
        burnID             = 0,
        calledTargetID     = 0,
        combatStart        = false,
        eventByPass        = false,
        eventFlag          = false,
        gotHitToggle       = false,
        lastCalledTargetID = 0,
        lastTargetID       = 0,
        missingComponent   = false,
        mobCount           = 0,
        mobFlag            = true,
        myTargetID         = 0,
        myTargetName       = '0',
        assistAt           = 95,
        autoBurnTimer      = 0,
        burnArray          = {},
        burnAllNamed       = 0,
        dpsArray           = {},
        dpsOn              = false,
        meleeDistance      = 30,
        meleeOn            = false,
        namedCheck         = false,
        namedWatchList     = {},
        targetSwitchingOn  = false,
        useTribute         = false,
        raidAssistEntry    = 1,
        raidTargetID       = '0',
        validTarget        = false,
        xSlotTotal         = 20,
        xTSlot             = 0,
        xTSlot2            = 0,
        xTarAutoSet        = true,
        -- Step 4.8
        aggroArray         = {},
        aggroOn            = false,
        slotTimers         = {},   -- per-DPS-slot os.clock() expiry (0=expired); mac ABTimer/DPSTimer
        dpsSkip            = 20,  -- stop DPS rotation when mob HP% is at or below this (mac DPSSkip)
        dpsInterval        = 2,   -- fallback timer (seconds) for zero-duration spells (mac DPSInterval)
        dpsOnOoc           = false, -- DPSOn==2: run DPS rotation out of combat
        autoFireOn         = 0,    -- 0=off, 1=ranged autofire, 2=paused-this-fight (mob too close)
        addSpamTimer       = 0,    -- os.clock() expiry for add-detection announce debounce
    },

    cast = {
        status           = 'IDLE',  -- IDLE/CASTING/SUCCESS/FIZZLE/INTERRUPT/RESIST/TIMEOUT
        castReturn       = 'CAST_CANCELLED',
        castResult       = '',
        castCheck        = '',
        checkResisted    = false,
        failCounter      = 0,
        failMax          = 3,
        gemSlots         = 8,
        miscGem          = 0,
        miscGemLW        = 0,
        miscGemRemem     = 0,   -- 0=off, 1=both, 2=short only, 3=LW only
        iamCastingID     = 0,
        lastResisted     = false,
        reMemCast        = false,
        reMemCastLW      = false,
        reMemWaitLong    = 'null',
        reMemWaitShort   = 'null',
        reMemMiscSpell   = '',  -- set post-ini: Me.Gem[miscGem].Name
        reMemMiscSpellLW = '',  -- set post-ini: Me.Gem[miscGemLW].Name
        spellReadyL      = false,
        checkStuckGem    = false,  -- [Spells] CheckStuckGem: verify gem slot before cast
    },

    pull = {
        aggroTargetID    = '',
        ammo             = 'NULL',
        beginMobID       = '',
        chainPullTemp    = '',
        chainPull        = 0,      -- 0=off 1=on 2=just-finished (mac int, not bool)
        heading          = 0.0,
        hold             = false,
        holdCond         = '0',
        ignore1          = 'NULL',
        ignore2          = 'NULL',
        ignore3          = 'NULL',
        item             = 'NULL',
        lastMobPullID    = 0,
        lSide            = 0.0,
        rSide            = 0.0,
        max              = 0,
        maxCount         = 500,
        maxRadius        = 0,      -- set from INI [Pull] MaxRadius
        maxZRange        = 0,      -- set from INI [Pull] MaxZRange
        maxWpRange       = 0,      -- set from INI [PullAdvanced] MaxWpRange
        min              = 0,
        mob              = 0,
        mobsNotAllowed   = 'null', -- set from INI [Pull] MobsNotAllowed
        mobsToIgnore     = 'null', -- set from INI [Pull] MobsToIgnore (names)
        mobsToIgnoreByID = 'null',
        mobsToPullFirst  = 'all',
        mobsToPullRaw    = 'null',
        moveUse          = '',
        navDistance      = 0,
        on               = false,  -- set from INI [Pull] PullOn
        pathWpCount      = 0,
        pullArcWidth     = 0,      -- set from INI [Pull] PullArcWidth
        pullLocX         = {},     -- set from INI [PullAdvanced] PullLocX1..N
        pullLocY         = {},
        pullLocZ         = {},
        pullLocsOn       = false,  -- set from INI [PullAdvanced] PullLocsOn
        pullOnReturn     = false,  -- set from INI [Pull] PullOnReturn
        pullWait         = 0,      -- set from INI [Pull] PullWait (seconds)
        pulled           = false,
        pulling          = false,
        range            = 0,
        ranking          = 0,
        searchIter       = 1,
        searchType       = '',     -- set from INI [Pull] SearchType
        tempMaxRadius    = 0,
        tooFar           = false,
        waitRemaining    = 0,
        waypointZRange   = 0,      -- set post-ini: mirrors MaxZRange
        withAlt          = 'Melee',
        xpCheck          = true,
    },

    movement = {
        advpathPoint    = 0,
        advpathX        = 0.0,
        advpathY        = 0.0,
        advpathZ        = 0.0,
        campRadius       = 50,
        campRadiusExceed = 0,   -- 0=disabled; >0=leash distance that disables ReturnToCamp
        campX           = 0,
        campY           = 0,
        campZ           = 0,
        campZone        = 0,
        cantHit         = false,
        cantSee         = false,
        chaseOnValue    = 1,
        checkOnReturn   = false,
        dontMoveMe      = false,
        dStickHow       = '0',
        locDelayCheckUW = false,
        lookForward     = 0,
        navPathHelper   = true,
        rememberCamp    = false,
        returnToCamp    = false,
        stayPut         = false,
        stickDist       = 13,
        stickDistUW     = 10,
        faceMobOn       = 0,   -- 0=off 1=fast nolook 2=nolook (mac FaceMobOn)
        scatterOn       = false,
        scatterDistance = 20,
        toClose         = false,
        whoToChase      = '',
        zDist           = 0.0,
    },

    heal = {
        autoRezAll          = false,
        autoRezArray        = {},
        autoRezOn           = 0,   -- 0=off 1=normal 2=OOC-only (mac AutoRezOn)
        battleRezTimers     = {0,0,0,0,0},  -- per group slot 1-5; os.clock() expiry
        corpseRezCheck      = 'null',
        oocRezTimers        = {},            -- [corpseID] = os.clock() expiry
        groupWatchPct       = 20,
        healAgain           = false,
        healRemChk1         = 'Divine Barrier',
        healRemChk2         = 'Touch of the Divine',
        healRemChk3         = 'null',
        medding             = false,
        meddingInterrupted  = false,
        medStat             = '',
        medStat2            = 'Endurance',
        needCuring          = false,
        sHealPct            = 0,
        singleHealPoint     = 0,
        singleHealPointMA   = 0,
        singleHealPointRange = 0,
        -- Step 5.1 — INI-loaded fields (defaults mirror Bind_Settings mac defaults)
        healsOn         = 0,   -- integer: 0=off 1=self+group+MA 2=self+group 3=MA-OOG+self 4=self-only
        healsArray      = {},
        -- Step 5.3 — group heal dispatch (built from healsArray at init by FindGroupHeals logic)
        groupHealArray  = {},  -- group-target spells only (TargetType contains 'group' or 'Targeted AE')
        groupHealTimers = {},  -- per-slot os.clock() expiry; 0=expired (mirrors SpellGH${j} mac timers)
        curesOn         = 0,    -- 0=off 1=everyone 2=self-only 3=group-only
        curesArray      = {},
        healInterval    = 0,
        xTarHeal        = false,
        xTarHealList    = '',
        healGroupPetsOn = false,
        rezMeLast       = false,
        medOn           = true,   -- mac default: 1
        medStart        = 20,
        medStop         = 100,
        medCombat       = false,
        groupWatchOn    = false,
        corpsRecoveryOn = false,
    },

    buffs = {
        blockedCount       = 0,
        durationMod        = 1.0,
        extendedList       = '',
        forceBuffs         = false,
        globalExtendedList = '',
        hasBuffDuration    = false,
        kaBegActive        = false,
        kaBegForList       = '',
        kaPetBegActive     = false,
        kaBegForPetList    = '',
        -- Step 6.1
        buffsOn            = false,
        buffsArray         = {},
        rebuffOn           = false,
        checkBuffsTimer    = 15,   -- seconds between buff check passes (INI CheckBuffsTimer)
        powerSource        = '',
        petBuffsOn         = false,
        petBuffsArray      = {},
        blockedBuffsCount  = 30,   -- 30 emu / 40 live
        slotTimers         = {},   -- [i][j]: per-slot per-member os.clock() expiry; replaces mac Buff${i}GM${j}
        remote             = {},   -- [charName] = BUFFS payload table; populated by Comms actors broadcast
    },

    pet = {
        activeState   = false,
        assistAt      = 100,   -- PetAssistAt: mob HP% threshold to send pet (set from INI)
        attackRange   = 0,
        combatOn      = false, -- PetCombatOn: actively send pet to attack mobs (set from INI)
        focus         = '',    -- PetFocus: pipe-delimited focusItem|focusSlot|focusBuff (set from INI)
        focusOn       = false, -- PetFocusOn (set from INI)
        globalToysGave = '',
        holdOn        = false, -- PetHoldOn: send /pet hold before summoning (set from INI)
        on            = false, -- PetOn: pet features enabled (set from INI)
        shrinkOn      = false, -- PetShrinkOn (set from INI)
        shrinkSpell   = '',    -- PetShrinkSpell (set from INI)
        spell         = '',    -- PetSpell: spell name used to summon pet (set from INI)
        suspend       = false, -- PetSuspend: suspend pet when not in combat (set from INI)
        suspendState  = false, -- runtime: true when pet is currently suspended
        tanking       = false,
        targetSwitch  = false,
        totCount      = 0,
        toyList       = '',
        toysArray     = {},    -- PetToys array (set from INI)
        toysOn        = false, -- PetToysOn (set from INI)
        petRampageOn  = false, -- PetRampPullWait: wait for rampage pets before pulling (set from INI)
    },

    mez = {
        on             = 0,      -- 0=Off 1=Single&AE 2=Single 3=AE
        broke          = false,
        immuneIDs      = '',
        mobCount       = 0,
        mobAECount     = 0,
        aeClosest      = 0,
        singleCount    = 1,
        aeCount        = 2,
        mobDone        = false,
        mobFlag        = false,
        spell          = '',
        aeSpell        = '',
        petBreakSpell  = '',
        mezDebuffSpell = '',
        mezDebuffOnResist = false,
        radius         = 40,
        minLevel       = 1,
        maxLevel       = 115,
        stopHPs        = 50,
    },

    bard = {
        burnMedley     = 'burn',     -- MQ2Medley set name for burn phase (INI BurnMedley)
        dpsTwisting    = false,
        gomActive      = false,
        gomByPass      = false,
        gomMedley      = 'gomSong',  -- MQ2Medley one-shot set for GoM proc (INI GoMMedley)
        meleeMedley    = 'melee',    -- MQ2Medley set name for combat (INI MeleeMedley)
        meleeTwistOn   = 0,          -- 0=off, 1=swap to melee set, 2=swap when aggro (INI MeleeTwistOn)
        oorMedley      = 'oor',      -- MQ2Medley set name for OOC (INI OORMedley)
        pullTwistOn    = false,      -- pause medley during pull (INI PullTwistOn)
        startTwist     = false,
        twistHold      = false,
        twistOn        = false,      -- OOC medley enabled (INI TwistOn)
        twisting       = false,
        wasTwisting    = 'null',
        wasTwistingBool = false,
    },

    loot = {
        on             = 1,
        radius         = 100,
        spamInfo       = 1,
        bagNum         = 0,
        bagNumLast     = 0,
        cursorID       = 0,
        cursorIDCount  = 0,
        dragCorpse     = false,
        looterAssigned = false,
    },

    cond = {
        on          = false,  -- set from INI [KConditions] ConOn
        size        = 5,      -- set from INI [KConditions] CondSize
        expressions = {},     -- [n] = TLO expression string (1-indexed)
    },

    debuff = {
        on     = 0,   -- DebuffAllOn: 0=off 1=in-combat only 2=OOC also
        count  = 0,   -- number of debuff slots parsed from [DPS] array
        slots  = {},  -- array of slot defs: { spell, tag1, tag2, condNo }
        timers = {},  -- slot index → expiry timestamp (os.clock())
        lists  = {},  -- slot index → string of "|id|id..." already-debuffed mobs
    },

    dps = {
        lastCast   = '',
        parseTimer = 0,
        paused     = false,
        spam       = false,
        target     = 0,
        writeOn    = false,
    },

    -- All .mac timer variables stored as os.clock() expiry timestamps; 0 = expired/unset.
    timers = {
        addSpam        = 0,
        aggroOff       = 0,
        campOnDeath    = 0,
        campfire       = 0,
        campfireClick  = 0,
        cleanBuffs     = 0,
        cursorID       = 0,
        debugTicker    = 0,
        engageWait     = 0,
        eventTimer     = 0,
        gomTimer       = 0,
        iniNext        = 0,
        joinedParty    = 0,
        justZoned      = 0,
        lastHealCheck  = 0,
        maSit          = 0,
        mezAE          = 0,
        petAttack      = 0,
        petBuffCheck   = 0,
        petFollow      = 60,  -- .mac default: 60s
        pullAlert      = 0,
        pullTimer      = 0,
        pullWait1      = 0,
        pullWait2      = 0,
        readBuffs      = 0,
        sitToMed       = 0,   -- .mac default: 6s, set at runtime
        spam           = 0,
        spam1          = 0,
        spam2          = 0,
        spam3          = 0,
        tank           = 0,
        tribute        = 0,
        waitTimer      = 0,
        writeBuffs     = 0,
        writeBuffsMerc = 0,
        writeBuffsPet  = 0,
    },

    misc = {
        aeDisplayMobInfo     = false,
        ammoSwitch           = false,
        banestrike           = '',
        colorIdx             = 0,
        colorList            = 'tWgtuwyr',
        conColor             = 't',
        dmz                  = false,  -- set at runtime: Zone.ID in {345,344,202,203,279,151,33506}
        dnOut                = 'null',
        globalIndex          = 0,
        itemsGiven           = 0,
        lastZone             = 0,
        macroReturn          = '',
        mapSet               = false,
        mountOn              = true,
        mq2castReload        = false,
        mq2meleeReload       = false,
        mq2spawnMasterReload = false,
        myAAExp              = 0.0,
        myExp                = 0.0,
        myMerc               = '0',
        origRanged           = '',
        rangedSwitch         = false,
        redguides            = true,
        searchType           = '',
        tempAmmo             = '',
        campfireOn           = false,
        myCmd                = '',  -- custom command string from INI [General] MyCmd
        winTitleText         = 'null',
    },

    arrays = {
        beforeArray  = {'null','null','null','null','null'},
        mashArray    = {'null','null','null','null','null','null','null','null','null','null'},
        weaveArray   = {},  -- [50]  string, 'null'
        mezArray     = {},  -- [50][3] string, 'NULL'
        xTarToHeal   = {},  -- [20]  int, 0
        pullPathX    = {},  -- [999] float, 0.0
        pullPathY    = {},
        pullPathZ    = {},
    },
}

-- Initialize variable-length arrays to their .mac defaults.
for i = 1, 50  do State.arrays.weaveArray[i] = 'null' end
for i = 1, 50  do State.arrays.mezArray[i]   = {'NULL','NULL','NULL'} end
for i = 1, 20  do State.arrays.xTarToHeal[i] = 0 end
for i = 1, 999 do
    State.arrays.pullPathX[i] = 0.0
    State.arrays.pullPathY[i] = 0.0
    State.arrays.pullPathZ[i] = 0.0
end

-- slotTimers[i][j]: per-spell-slot (1..20) per-group-member (0..5) rebuff expiry.
-- Replaces .mac's dynamic Buff${i}GM${j} variable pattern.
for i = 1, 20 do
    State.buffs.slotTimers[i] = {}
    for j = 0, 5 do State.buffs.slotTimers[i][j] = 0 end
end

return State
