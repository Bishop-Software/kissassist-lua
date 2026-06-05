local mq     = require('mq')
local Config = require('modules.config')

local Mez = {}
local _state, _utils, _cast

function Mez.init(state, utils, cast)
    _state = state
    _utils = utils
    _cast  = cast

    -- [Mez] INI section — mirrors LoadIni Mez block (kissassist.mac:14861-14874)
    _state.mez.on               = tonumber(Config.get('Mez', 'MezOn',             '0')) or 0
    _state.mez.radius           = tonumber(Config.get('Mez', 'MezRadius',         '50')) or 50
    _state.mez.minLevel         = tonumber(Config.get('Mez', 'MezMinLevel',       '1')) or 1
    _state.mez.maxLevel         = tonumber(Config.get('Mez', 'MezMaxLevel',       '115')) or 115
    _state.mez.stopHPs          = tonumber(Config.get('Mez', 'MezStopHPs',        '80')) or 80
    _state.mez.spell            = Config.get('Mez', 'MezSpell',          '') or ''
    _state.mez.mezDebuffOnResist = Config.get('Mez', 'MezDebuffOnResist', '0') == '1'
    _state.mez.mezDebuffSpell   = Config.get('Mez', 'MezDebuffSpell',    '') or ''
    _state.mez.aeSpell          = Config.get('Mez', 'MezAESpell',        '') or ''
    -- PetBreakMezSpell lives in [Pet] section (mac:14822)
    _state.mez.petBreakSpell    = Config.get('Pet', 'PetBreakMezSpell',  '') or ''
end

-- Scan XTarget haters within MezRadius; populate mezArray, mobCount, mobAECount, aeClosest.
-- Port of Sub MezRadar (kissassist.mac:7190).
local function mezRadar()
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end

    local radius = _state.mez.radius

    -- Total hater count (all XTarget haters)
    local mobCount   = mq.TLO.SpawnCount('xtarhater')() or 0
    local mobAECount = mq.TLO.SpawnCount('xtarhater radius ' .. radius)() or 0

    -- XTSlot non-auto-hater adds one to each count (mac:7199-7202)
    local xtSlot = _state.combat.xTSlot or 0
    if xtSlot > 0 then
        local xt = mq.TLO.Me.XTarget(xtSlot)
        if xt and (xt.ID() or 0) > 0 and (xt.TargetType() or '') ~= 'Auto Hater' then
            mobCount   = mobCount   + 1
            mobAECount = mobAECount + 1
        end
    end

    _state.mez.mobCount   = mobCount
    _state.mez.mobAECount = mobAECount

    -- Build mezArray from nearby haters not already tracked (mac:7203-7211)
    local arr = _state.arrays.mezArray
    if mobAECount > 0 then
        for i = 1, mobAECount do
            local sp = mq.TLO.NearestSpawn(i, 'xtarhater radius ' .. radius)
            if sp then
                local id = sp.ID() or 0
                if id > 0 then
                    -- Check if already in array
                    local found = false
                    for _, entry in ipairs(arr) do
                        if tostring(entry[1]) == tostring(id) then found = true; break end
                    end
                    if not found then
                        -- Add to first empty slot
                        for _, entry in ipairs(arr) do
                            if entry[1] == 'NULL' then
                                entry[1] = id
                                entry[2] = sp.Level() or 0
                                entry[3] = sp.CleanName() or ''
                                _utils.debug('mez', 'mezRadar: adding %s (ID:%d)', entry[3], id)
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Track closest hater in radius for AE mez (mac:7213)
    local closest = mq.TLO.NearestSpawn(1, 'xtarhater radius ' .. radius)
    _state.mez.aeClosest = closest and (closest.ID() or 0) or 0

    _utils.debug('mez', 'mezRadar: mobCount=%d mobAECount=%d aeClosest=%d',
        mobCount, mobAECount, _state.mez.aeClosest)
end

-- AE mez cast dispatch. Port of Sub MezMobsAE (kissassist.mac:7440).
local function mezMobsAE(aeTargetID)
    local spell   = _state.mez.aeSpell
    if spell == '' or spell == 'null' then return end

    local myClass = (mq.TLO.Me.Class.ShortName() or ''):upper()
    local isBard  = myClass == 'BRD'
    local isEnc   = myClass == 'ENC'

    if not isBard and not isEnc then return end

    if not mq.TLO.Me.AltAbility(spell)() and not mq.TLO.Me.Book(spell)() then
        printf('\ay[Mez] Invalid AEMezSpell "%s" — check spelling.', spell)
        return
    end

    if isBard then
        local tid = (mq.TLO.Target.ID() or 0) ~= 0 and mq.TLO.Target.ID() or aeTargetID
        _cast.castWhat(spell, tid, 'Mez', 0, 0)
        printf('\ay[Mez] AE Mezzing (Bard) -> %s', spell)
        _state.timers.mezAE = mq.gettime() + 300000  -- 5 min default
    elseif isEnc then
        local wasChasing = _state.session.chaseAssist
        if wasChasing then
            _state.session.chaseAssist = false
            mq.cmd('/squelch /stick off')
            mq.cmd('/squelch /moveto off')
            mq.delay(3000, function() return not mq.TLO.Me.Moving() end)
        end
        printf('\ay[Mez] AE Mezzing (Enc) -> %s', spell)
        while not mq.TLO.Me.SpellReady(spell)() do mq.delay(200) end
        _cast.castWhat(spell, aeTargetID, 'Mez', 0, 0)
        local dur = (mq.TLO.Spell(spell).Duration() and
                     mq.TLO.Spell(spell).Duration.TotalSeconds() or 0)
        _state.timers.mezAE = mq.gettime() + (dur > 0 and dur * 1000 or 30000)
        -- Reset all per-slot mez timers after AE (mac:7484-7486)
        for i = 1, 30 do _state.timers['mezTimer' .. i] = 0 end
        if wasChasing then _state.session.chaseAssist = true end
    end
end

-- Port of Sub MezMobs (kissassist.mac:7491) — cast single mez on one mob.
local function mezMobs(mobID, slotIndex)
    local spell = _state.mez.spell
    _utils.debug('mez', 'mezMobs: casting %s on ID:%d', spell, mobID)

    if mq.TLO.Me.Invis() then mq.cmd('/makemevisible') end

    -- Stop attack before mezzing (mac:7496-7498)
    if mq.TLO.Me.Combat() then
        mq.cmd('/attack off')
        mq.delay(2500, function() return not mq.TLO.Me.Combat() end)
    end

    _cast.castWhat(spell, mobID, 'Mez', 0, 0)

    -- Set per-slot timer to spell duration (mac:7492-style)
    local dur = (mq.TLO.Spell(spell).Duration() and
                 mq.TLO.Spell(spell).Duration.TotalSeconds() or 60)
    _state.timers['mezTimer' .. slotIndex] = mq.gettime() + (dur * 1000)
end

-- Core mez loop. Port of Sub MezCheck / DoMezStuff (kissassist.mac:8074 / 7256).
-- sentFrom: 'CheckForCombat' | 'Combat' | 'Combat1' | 'CombatCast' | 'CheckBeforeCombat'
function Mez.check(sentFrom)
    if _state.mez.on == 0 then return end
    if mq.TLO.Me.Hovering() then return end
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end

    -- No combat target and MA is alive → nothing to mez around yet (mac:7271)
    local maSpawn = mq.TLO.Spawn('=' .. (_state.session.mainAssist or ''))
    local maID    = maSpawn and (maSpawn.ID() or 0) or 0
    local maAlive = maID > 0
    if _state.combat.myTargetID == 0 and maAlive
       and (maSpawn.Type() or ''):lower() ~= 'mercenary' then
        return
    end

    _state.mez.broke = false
    _utils.debug('mez', 'Mez.check: enter sentFrom=%s', sentFrom)

    mezRadar()

    -- Return if mob count is below single-mez threshold (mac:7283-7287)
    if _state.mez.mobCount < _state.mez.singleCount and maAlive then
        _state.mez.mobDone = true
        return
    end

    local myClass = (mq.TLO.Me.Class.ShortName() or ''):upper()
    local canAE   = myClass == 'BRD' or myClass == 'ENC'

    -- AE mez: modes 1 (single+AE) or 3 (AE only), BRD/ENC only (mac:7290-7297)
    if canAE and (_state.mez.on == 1 or _state.mez.on == 3)
       and _state.mez.aeCount > 0
       and _state.mez.mobAECount >= _state.mez.aeCount
       and (_state.timers.mezAE or 0) < mq.gettime()
       and _state.mez.aeClosest > 0 then
        mezMobsAE(_state.mez.aeClosest)
    end

    -- Single mez: modes 1 or 2 only (mac:7411)
    if _state.mez.on ~= 1 and _state.mez.on ~= 2 then return end

    local spell = _state.mez.spell
    if spell == '' or spell == 'null' then return end

    -- Spell ready check (mac:7304-7313); bards skip this gate
    if not _state.session.iAmABard and not mq.TLO.Me.SpellReady(spell)() then return end

    local arr = _state.arrays.mezArray
    for i = 1, math.min(#arr, 13) do
        local entry   = arr[i]
        local mobID   = entry[1]
        local mobLvl  = tonumber(entry[2]) or 0
        local mobName = entry[3]

        if mobID == 'NULL' or mobID == nil then goto continue_mez end

        local mob = mq.TLO.Spawn('id ' .. tostring(mobID))

        -- Dead or despawned (mac:7320-7323)
        if not mob or (mob.ID() or 0) == 0 or (mob.Type() or ''):lower() == 'corpse' then
            entry[1] = 'NULL'; entry[2] = 'NULL'; entry[3] = 'NULL'
            goto continue_mez
        end

        -- Out of mez radius (mac:7326-7329)
        if (mob.Distance() or 999) >= _state.mez.radius then
            entry[1] = 'NULL'; entry[2] = 'NULL'; entry[3] = 'NULL'
            goto continue_mez
        end

        -- MA's current target — let group kill it (mac:7332-7335)
        if (mob.ID() or 0) == _state.combat.myTargetID and maAlive then
            entry[1] = 'NULL'; entry[2] = 'NULL'; entry[3] = 'NULL'
            goto continue_mez
        end

        -- Skip first target when MA is a merc with no mytarget (mac:7338-7341)
        if (tonumber(_state.combat.aggroTargetID) or 0) ~= 0
           and _state.combat.myTargetID == 0 and maAlive
           and (maSpawn.Type() or ''):lower() == 'mercenary' then
            entry[1] = 'NULL'; entry[2] = 'NULL'; entry[3] = 'NULL'
            goto continue_mez
        end

        -- HP threshold — mob too low to bother re-mezzing (mac:7344-7347)
        if (mob.PctHPs() or 100) < _state.mez.stopHPs then
            entry[1] = 'NULL'; entry[2] = 'NULL'; entry[3] = 'NULL'
            goto continue_mez
        end

        -- Level range filter (mac:7350-7353)
        if mobLvl > _state.mez.maxLevel or (mobLvl > 0 and mobLvl < _state.mez.minLevel) then
            entry[1] = 'NULL'; entry[2] = 'NULL'; entry[3] = 'NULL'
            goto continue_mez
        end

        -- Line of sight (mac:7356-7358)
        if not mob.LineOfSight() then goto continue_mez end

        -- Giant body type — always immune (mac:7366-7368)
        if (mob.Body.Name() or '') == 'Giant' then goto continue_mez end

        -- Runtime immune IDs (mac:7405-7408)
        local ids = _state.mez.immuneIDs or ''
        if ids ~= '' and ids:find('|' .. tostring(mobID), 1, true) then
            entry[1] = 'NULL'; entry[2] = 'NULL'; entry[3] = 'NULL'
            goto continue_mez
        end

        -- Mana check (mac:7387-7389)
        local manaCost = mq.TLO.Spell(spell).Mana() or 0
        if (mq.TLO.Me.CurrentMana() or 0) < manaCost then goto continue_mez end

        -- Per-slot cooldown timer (mac:7392-7394)
        local timerKey = 'mezTimer' .. i
        if (_state.timers[timerKey] or 0) > mq.gettime() then goto continue_mez end

        -- Stop mezzing last mob when MA is a merc/pet (they won't attack a mezzed mob) (mac:7397-7399)
        if _state.mez.mobCount <= 1 and maAlive then
            local maType = (maSpawn.Type() or ''):lower()
            if maType == 'mercenary' or maType == 'pet' then goto continue_mez end
        end

        -- Cast single mez (mac:7419)
        mezMobs(tonumber(mobID) or 0, i)
        _state.mez.mobDone = true

        ::continue_mez::
    end

    _utils.debug('mez', 'Mez.check: leave')
end

-- Port of Sub AECheck (kissassist.mac:12473) — simplified for mez AE threshold gate.
function Mez.aeCheck()
    if _state.mez.on == 0 then return end
    if (mq.TLO.Target.Type() or ''):lower() == 'corpse' then return end
    if (tonumber(_state.combat.aggroTargetID) or 0) == 0 then return end

    local radius = _state.mez.radius
    local count  = mq.TLO.SpawnCount('npc xtarhater targetable los radius ' .. radius)() or 0
    if count <= 0 then return end

    if _state.mez.aeSpell ~= '' and _state.mez.aeCount > 0 and count >= _state.mez.aeCount
       and (_state.timers.mezAE or 0) < mq.gettime() then
        mezMobsAE(_state.mez.aeClosest > 0 and _state.mez.aeClosest
                  or (_state.combat.myTargetID ~= 0 and _state.combat.myTargetID
                      or (mq.TLO.Target.ID() or 0)))
    end
end

-- Port of Sub BreakMez (kissassist.mac:2123) — pettank roles only.
function Mez.breakMez()
    local spell = _state.mez.petBreakSpell
    if spell == '' or spell == 'null' then return end

    local tID = _state.combat.myTargetID
    if tID == 0 then tID = mq.TLO.Target.ID() or 0 end
    if tID == 0 then return end

    _utils.debug('mez', 'Mez.breakMez: breaking mez on ID:%d with %s', tID, spell)
    printf('\aw[Mez] Breaking mez on %s (ID:%d) with %s',
        mq.TLO.Spawn('id ' .. tID).CleanName() or '?', tID, spell)
    _cast.castWhat(spell, tID, 'BreakMez', 0, 0)
end

return Mez
