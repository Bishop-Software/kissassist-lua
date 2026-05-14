local mq     = require('mq')
local Config = require('modules.config')

local Heal = {}

local _state, _utils, _cast

-- Mirrors Bind_Settings heals/cures/general-med sections (kissassist.mac:14750).
-- Defaults match LoadIni defaults in the mac.
function Heal.init(state, utils, cast)
    _state = state
    _utils = utils
    _cast  = cast

    -- [General] medding + group-watch (GroupWatchOn may encode pct as "1|20")
    _state.heal.medOn           = Config.get('General', 'MedOn',     '1') == '1'
    _state.heal.medStart        = tonumber(Config.get('General', 'MedStart',   '20'))  or 20
    _state.heal.medStop         = tonumber(Config.get('General', 'MedStop',    '100')) or 100
    _state.heal.medCombat       = Config.get('General', 'MedCombat', '0') == '1'
    _state.heal.corpsRecoveryOn = Config.get('General', 'CorpseRecoveryOn', '0') ~= '0'

    local gwRaw = Config.get('General', 'GroupWatchOn', '0') or '0'
    if gwRaw:find('|', 1, true) then
        local gwOn, gwPct = gwRaw:match('^([^|]+)|(.+)$')
        _state.heal.groupWatchOn  = (gwOn or '0') ~= '0'
        _state.heal.groupWatchPct = tonumber(gwPct) or _state.heal.groupWatchPct
    else
        _state.heal.groupWatchOn = gwRaw ~= '0'
    end

    -- [Heals]
    _state.heal.healsOn         = tonumber(Config.get('Heals', 'HealsOn', '0')) or 0
    _state.heal.healInterval    = tonumber(Config.get('Heals', 'HealInterval', '0'))  or 0
    _state.heal.autoRezOn       = Config.get('Heals', 'AutoRezOn',       '0') == '1'
    _state.heal.xTarHeal        = Config.get('Heals', 'XTarHeal',        '0') == '1'
    _state.heal.xTarHealList    = Config.get('Heals', 'XTarHealList',    '')  or ''
    _state.heal.healGroupPetsOn = Config.get('Heals', 'HealGroupPetsOn', '0') == '1'
    _state.heal.rezMeLast       = Config.get('Heals', 'RezMeLast',       '0') == '1'

    local healsRaw = Config.get('Heals', 'Heals', nil)
    if type(healsRaw) == 'table' then
        for _, v in ipairs(healsRaw) do
            if v and v ~= '' and v ~= 'NULL' and v ~= 'null' then
                _state.heal.healsArray[#_state.heal.healsArray + 1] = v
            end
        end
    end

    -- Derive singleHealPoint/MA/Range from healsArray (mirrors FindSingleHeals, mac:12012)
    for _, entry in ipairs(_state.heal.healsArray) do
        local spell = entry:match('^([^|]+)') or ''
        local pct   = tonumber(entry:match('^[^|]+|([^|]+)')) or 0
        local tag   = entry:match('^[^|]+|[^|]+|([^|]*)') or ''
        if tag == 'MA' then
            if pct > _state.heal.singleHealPointMA then _state.heal.singleHealPointMA = pct end
        else
            if pct > _state.heal.singleHealPoint then _state.heal.singleHealPoint = pct end
        end
        local r = mq.TLO.Spell(spell).Range() or 0
        if r > _state.heal.singleHealPointRange then _state.heal.singleHealPointRange = r end
    end
    if _state.heal.singleHealPoint    == 0 then _state.heal.singleHealPoint    = 99  end
    if _state.heal.singleHealPointMA  == 0 then _state.heal.singleHealPointMA  = _state.heal.singleHealPoint end
    if _state.heal.singleHealPointRange == 0 then _state.heal.singleHealPointRange = 200 end
    -- Wire session flag used by castMem guard (cast.lua:488)
    _state.session.heals = _state.heal.healsOn > 0

    -- Build groupHealArray from healsArray (mirrors FindGroupHeals mac:12075).
    -- Include spells whose TargetType contains 'group' (catches Group v2/v3 etc.)
    -- or TargetType 'Targeted AE' when the entry tag is not 'MA' or 'ME'.
    for _, entry in ipairs(_state.heal.healsArray) do
        local spell = entry:match('^([^|]+)') or ''
        local tag   = entry:match('^[^|]+|[^|]+|([^|]*)') or ''
        if spell ~= '' then
            local tt    = mq.TLO.Spell(spell).TargetType() or ''
            local ttLow = tt:lower()
            local isGroup = ttLow:find('group', 1, true) ~= nil
            local isAE    = tt == 'Targeted AE' and tag ~= 'MA' and tag ~= 'ME'
            local isSingleSelf = ttLow == 'self' or ttLow == 'single'
            if (isGroup or isAE) and not isSingleSelf then
                local n = #_state.heal.groupHealArray + 1
                _state.heal.groupHealArray[n]  = entry
                _state.heal.groupHealTimers[n] = 0
            end
        end
    end

    -- Derive medStat from class once (Mana for casters, Endurance for melee/hybrids without mana; mirrors DoWeMed mac:3852)
    local MANA_CLASSES = {BST=true,BRD=true,CLR=true,DRU=true,ENC=true,MAG=true,NEC=true,PAL=true,RNG=true,SHM=true,SHD=true,WIZ=true}
    local initClass = mq.TLO.Me.Class.ShortName() or ''
    _state.heal.medStat = MANA_CLASSES[initClass] and 'Mana' or 'Endurance'

    -- [Cures]
    _state.heal.curesOn = Config.get('Cures', 'CuresOn', '0') == '1'

    local curesRaw = Config.get('Cures', 'Cures', nil)
    if type(curesRaw) == 'table' then
        for _, v in ipairs(curesRaw) do
            if v and v ~= '' and v ~= 'NULL' and v ~= 'null' then
                _state.heal.curesArray[#_state.heal.curesArray + 1] = v
            end
        end
    end

    _utils.debug('heals', string.format(
        'Heal.init done — healsOn=%d(%d spells) groupHeals=%d curesOn=%s(%d) medOn=%s medStat=%s medStart=%d medStop=%d sHP=%d sHPma=%d sHPrange=%d',
        _state.heal.healsOn, #_state.heal.healsArray, #_state.heal.groupHealArray,
        tostring(_state.heal.curesOn), #_state.heal.curesArray,
        tostring(_state.heal.medOn), _state.heal.medStat, _state.heal.medStart, _state.heal.medStop,
        _state.heal.singleHealPoint, _state.heal.singleHealPointMA, _state.heal.singleHealPointRange))
end

-- Classes that can cast heals on others (mirrors mac:6393 Select list)
local HEALING_CLASSES = {BST=true, CLR=true, ENC=true, SHM=true, DRU=true, RNG=true, PAL=true}

-- Classes that can cast group heals (mac:6522)
local GROUP_HEAL_CLASSES = {BST=true, CLR=true, SHM=true, DRU=true, PAL=true}

-- Iterate healsArray to find and cast the first spell whose threshold covers hpPct.
-- Mirrors Sub SingleHeal dispatch (mac:6546). targetID must already be resolved.
local function singleHeal(name, targetID, hpPct, sentFrom)
    if mq.TLO.Me.Moving() or mq.TLO.Me.Hovering() then return end
    if mq.TLO.Me.Invis() and _state.combat.aggroTargetID == '' then return end
    if not targetID or targetID == 0 then return end

    for _, entry in ipairs(_state.heal.healsArray) do
        local spell     = entry:match('^([^|]+)') or ''
        local threshold = tonumber(entry:match('^[^|]+|([^|]+)')) or 0
        if spell ~= '' and threshold > 0 and hpPct <= threshold then
            _utils.debug('heals', string.format('singleHeal: %s (%d%%) -> %s', name, hpPct, spell))
            _cast.castWhat(spell, targetID, sentFrom)
            return
        end
    end
end

-- Port of Sub CheckHealth (mac:6368). Identifies who needs healing and dispatches singleHeal.
-- sentFrom: caller tag ('MainLoop', 'CheckForCombat', etc.)
function Heal.checkHealth(sentFrom)
    if _state.heal.healsOn == 0 then return end
    if mq.TLO.Me.Invis() and _state.combat.aggroTargetID == '' then return end
    if _state.heal.medding and not _state.heal.medCombat then return end

    _utils.debug('heals', 'checkHealth enter ' .. sentFrom)

    local healsOnVal = _state.heal.healsOn

    -- Self-heal check
    local selfPct = mq.TLO.Me.PctHPs() or 100
    if selfPct < _state.heal.singleHealPoint then
        singleHeal(mq.TLO.Me.CleanName(), mq.TLO.Me.ID(), selfPct, 'SingleHeal')
    end

    -- Self-only mode: stop here
    if healsOnVal == 4 then
        _utils.debug('heals', 'checkHealth leave (self-only) ' .. sentFrom)
        return
    end

    local myClass = mq.TLO.Me.Class.ShortName() or ''
    if not HEALING_CLASSES[myClass] then
        _utils.debug('heals', 'checkHealth leave (non-healer class) ' .. sentFrom)
        return
    end

    -- MA out-of-group heal (healsOn 1 or 3)
    if healsOnVal == 1 or healsOnVal == 3 then
        local maName = _state.session.mainAssist
        if maName ~= '' then
            ---@diagnostic disable-next-line: undefined-field
            local maID  = mq.TLO.Spawn(maName .. ' PC').ID()  or 0
            ---@diagnostic disable-next-line: undefined-field
            local maPct = mq.TLO.Spawn(maName .. ' PC').PctHPs() or 100
            ---@diagnostic disable-next-line: undefined-field
            local maType = mq.TLO.Spawn(maName .. ' PC').Type() or ''
            if maID ~= 0 and maType ~= 'corpse' and maID ~= mq.TLO.Me.ID()
                    and maPct < _state.heal.singleHealPointMA then
                singleHeal(maName, maID, maPct, 'SingleHeal')
            end
        end
    end

    -- Group scan: find most-hurt member (healsOn 1 or 2)
    if (healsOnVal == 1 or healsOnVal == 2) and (mq.TLO.Group.Members() or 0) > 0 then
        local mostHurtName = ''
        local mostHurtID   = 0
        local mostHurtPct  = 100

        for i = 0, 5 do
            local m = mq.TLO.Group.Member(i)
            ---@diagnostic disable-next-line: undefined-field
            local mID   = m and m.ID()       or 0
            ---@diagnostic disable-next-line: undefined-field
            local mType = m and m.Type()     or ''
            ---@diagnostic disable-next-line: undefined-field
            local mPct  = m and m.PctHPs()   or 100
            ---@diagnostic disable-next-line: undefined-field
            local mDist = m and m.Distance() or 9999

            if mID > 0 and mType ~= 'corpse' and mPct >= 1
                    and mDist <= _state.heal.singleHealPointRange then
                ---@diagnostic disable-next-line: undefined-field
                local mClass = m and m.Class.ShortName() or ''
                ---@diagnostic disable-next-line: undefined-field
                local mLevel = m and m.Level() or 0
                -- Berserkers at 95+ only healed below 70% (mac:6418)
                local eligible = (mClass ~= 'BER') or (mLevel < 95) or (mPct < 70)
                if eligible and mPct < mostHurtPct then
                    ---@diagnostic disable-next-line: undefined-field
                    mostHurtName = m.CleanName() or ''
                    mostHurtID   = mID
                    mostHurtPct  = mPct
                end

                -- Pet check (mac:6435)
                if _state.heal.healGroupPetsOn then
                    ---@diagnostic disable-next-line: undefined-field
                    local petID  = m.Pet.ID()     or 0
                    ---@diagnostic disable-next-line: undefined-field
                    local petPct = m.Pet.PctHPs() or 100
                    if petID > 0 and petPct < mostHurtPct then
                        ---@diagnostic disable-next-line: undefined-field
                        mostHurtName = m.Pet.CleanName() or ''
                        mostHurtID   = petID
                        mostHurtPct  = petPct
                    end
                end
            end
        end

        if mostHurtID ~= 0 and mostHurtPct < _state.heal.singleHealPoint then
            singleHeal(mostHurtName, mostHurtID, mostHurtPct, 'SingleHeal')
        end
    end

    -- Group heal dispatch: only for group-heal-capable classes when 2+ members are below 90% HP (mac:6522-6530)
    if GROUP_HEAL_CLASSES[myClass] then
        ---@diagnostic disable-next-line: undefined-field
        local avgHPs = mq.TLO.Group.AvgHPs() or 100
        ---@diagnostic disable-next-line: undefined-field
        local injured90 = mq.TLO.Group.Injured(90) or 0
        if avgHPs < 100 and (mq.TLO.Group.Members() or 0) > 0 and injured90 > 1 then
            Heal.doGroupHealStuff()
        end
    end

    -- Step 5.4: Heal.checkCures()       — debuff removal + WriteDebuffs
    -- Step 5.5: Heal.rezCheck()         — rez dead group members via MQ2Rez

    _utils.debug('heals', 'checkHealth leave ' .. sentFrom)
end

-- Port of Sub DoGroupHealStuff (mac:6739). Iterates groupHealArray (group-target spells filtered
-- from healsArray at init). Fires the first spell whose threshold covers 2+ injured members and
-- whose per-slot HoT timer has expired. sentFrom='GroupHeal' bypasses the invis guard in castWhat.
function Heal.doGroupHealStuff()
    _utils.debug('heals', 'doGroupHealStuff enter')

    mq.doevents()

    for i, entry in ipairs(_state.heal.groupHealArray) do
        local spell = entry:match('^([^|]+)') or ''
        local pct   = tonumber(entry:match('^[^|]+|([^|]+)')) or 0
        -- Mac returns on first empty/zero-threshold entry (mac:6749)
        if spell == '' or pct == 0 then break end

        if os.clock() >= _state.heal.groupHealTimers[i] then
            ---@diagnostic disable-next-line: undefined-field
            local injured = mq.TLO.Group.Injured(pct) or 0
            if injured > 1 then
                _utils.debug('heals', string.format('doGroupHealStuff: %s pct=%d injured=%d', spell, pct, injured))
                _cast.castWhat(spell, mq.TLO.Me.ID(), 'GroupHeal')
                if _state.cast.castReturn == 'CAST_SUCCESS' then
                    local dur = mq.TLO.Spell(spell).MyDuration.TotalSeconds() or 0
                    _state.heal.groupHealTimers[i] = os.clock() + dur
                    _state.heal.healAgain = true
                    _utils.debug('heals', string.format('doGroupHealStuff: %s cast ok, timer=%ds', spell, dur))
                    return
                end
            end
        end
    end

    _utils.debug('heals', 'doGroupHealStuff leave')
end

-- Simplified port of Sub DoWeMed (mac:3836). Manages sit-to-med when out of combat.
-- Full MeddingInterrupted state machine and bard twist-med are deferred (Step 5.6).
-- Called from the main loop out-of-combat (init.lua, Step 5.6).
function Heal.doWeMed()
    if not _state.heal.medOn then return end
    -- Only med in combat if medCombat is on (mac:3838)
    if not _state.heal.medCombat and _state.combat.aggroTargetID ~= '' then return end
    if mq.TLO.Me.Moving() then return end

    local stat = _state.heal.medStat
    if stat == '' then return end

    local pct
    if stat == 'Mana' then
        pct = mq.TLO.Me.PctMana() or 100
    else
        pct = mq.TLO.Me.PctEndurance() or 100
    end

    if not _state.heal.medding then
        if pct < _state.heal.medStart then
            _state.heal.medding = true
            _utils.debug('heals', string.format('doWeMed: start medding %s at %d%%', stat, pct))
            if not mq.TLO.Me.Sitting() then
                mq.cmd('/sit')
            end
        end
    else
        if pct >= _state.heal.medStop then
            _state.heal.medding = false
            _utils.debug('heals', string.format('doWeMed: done medding %s at %d%%', stat, pct))
            if mq.TLO.Me.Sitting() then
                mq.cmd('/stand')
            end
        elseif not mq.TLO.Me.Sitting() then
            -- Re-sit if something stood us up mid-med
            mq.cmd('/sit')
        end
    end
end

return Heal
