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
    _state.heal.autoRezOn       = tonumber(Config.get('Heals', 'AutoRezOn', '0')) or 0
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
    _state.heal.curesOn = tonumber(Config.get('Cures', 'CuresOn', '0')) or 0

    local curesRaw = Config.get('Cures', 'Cures', nil)
    if type(curesRaw) == 'table' then
        for _, v in ipairs(curesRaw) do
            if v and v ~= '' and v ~= 'NULL' and v ~= 'null' then
                _state.heal.curesArray[#_state.heal.curesArray + 1] = v
            end
        end
    end

    -- [Heals] AutoRez entries: SpellName|arg2|RezType (rez/rezooc/rezcombat)
    local autoRezRaw = Config.get('Heals', 'AutoRez', nil)
    if type(autoRezRaw) == 'table' then
        for _, v in ipairs(autoRezRaw) do
            if v and v ~= '' and v ~= 'NULL' and v ~= 'null' then
                _state.heal.autoRezArray[#_state.heal.autoRezArray + 1] = v
            end
        end
    end

    _utils.debug('heals', string.format(
        'Heal.init done — healsOn=%d(%d spells) groupHeals=%d curesOn=%d(%d) autoRezOn=%d(%d) medOn=%s medStat=%s medStart=%d medStop=%d sHP=%d sHPma=%d sHPrange=%d',
        _state.heal.healsOn, #_state.heal.healsArray, #_state.heal.groupHealArray,
        _state.heal.curesOn, #_state.heal.curesArray,
        _state.heal.autoRezOn, #_state.heal.autoRezArray,
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

    -- Note: Heal.checkCures() is called from the combat loop (Step 5.6), not here,
    --       because checkCures() calls checkHealth() internally (mac:12617,12763).
    if _state.heal.autoRezOn > 0 then Heal.rezCheck() end

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

-- Port of Sub RezWithCheck (mac:6799). Selects the first ready rez spell from autoRezArray
-- that is legal for the current combat state. Returns spell name string or nil.
-- who='status': skip condition evaluation (just probe readiness).
-- RezType field (arg3): rez=always, rezooc=OOC-only, rezcombat=combat-only.
local function rezWithCheck()
    local inCombat = _state.combat.combatStart
        or (mq.TLO.SpawnCount('xtarhater radius ' .. (_state.combat.meleeDistance or 30))() or 0) > 0

    for _, entry in ipairs(_state.heal.autoRezArray) do
        if entry == '' or entry == 'null' or entry == 'NULL' then break end
        local parts = {}
        for p in (entry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
        local spellName = parts[1] or ''
        local rezType   = (parts[3] or ''):lower()
        if spellName == '' then break end

        -- Validate rez type; stop on first unknown (mac:6807-6810)
        if rezType ~= 'rez' and rezType ~= 'rezooc' and rezType ~= 'rezcombat' then
            if rezType ~= '' and rezType ~= 'null' then
                _utils.debug('heals', 'rezWithCheck: invalid rez type ' .. rezType)
            end
            break
        end

        -- Filter by combat state, then check readiness (mac:6811-6817)
        local combatFiltered = (inCombat and rezType == 'rezooc')
                            or (not inCombat and rezType == 'rezcombat')
        if not combatFiltered then
            local rankName = mq.TLO.Spell(spellName).RankName() or spellName
            local ready = mq.TLO.Me.SpellReady(rankName)()
                or mq.TLO.Me.AltAbilityReady(spellName)()
                or mq.TLO.Me.ItemReady(spellName)()
            -- ConOn / condition eval simplified (deferred to Step 6+); return first ready spell
            if ready then return spellName end
        end
    end
    return nil
end

-- Port of Sub WriteDebuffs (mac:12569). Writes self-debuff state to KissAssist_Buffs.ini
-- for cross-character healer awareness. Called from main loop and after self-cures.
-- Only the non-DanNet path is implemented (DanNet is deprecated in the Lua port).
function Heal.writeDebuffs()
    local buffFile = _state.session.buffFileName
    local meID     = mq.TLO.Me.ID()

    ---@diagnostic disable-next-line: undefined-field
    local poison   = mq.TLO.Me.Poisoned.ID()   or 0
    ---@diagnostic disable-next-line: undefined-field
    local disease  = mq.TLO.Me.Diseased.ID()   or 0
    ---@diagnostic disable-next-line: undefined-field
    local cursed   = mq.TLO.Me.Cursed.ID()     or 0
    ---@diagnostic disable-next-line: undefined-field
    local restless = mq.TLO.Me.Song('Restless Curse').ID() or 0
    ---@diagnostic disable-next-line: undefined-field
    local corrupt  = mq.TLO.Me.Corrupted.ID()  or 0
    ---@diagnostic disable-next-line: undefined-field
    local mezzed   = mq.TLO.Me.Mezzed.ID()     or 0

    local curseTotal  = cursed + restless
    local debuffTotal = poison + disease + curseTotal + corrupt + mezzed

    if debuffTotal > 0 then
        if not _state.heal.needCuring then
            _state.heal.needCuring = true
            local debuffList = string.format('%d|%d|%d|%d|%d|%d',
                debuffTotal, poison, disease, curseTotal, corrupt, mezzed)
            mq.cmdf('/ini "%s" "%s" Debuffs "%s"', buffFile, tostring(meID), debuffList)
            _utils.debug('heals', 'writeDebuffs: writing ' .. debuffList)
        end
    else
        if _state.heal.needCuring then
            _state.heal.needCuring = false
            mq.cmdf('/ini "%s" "%s" Debuffs ""', buffFile, tostring(meID))
            _utils.debug('heals', 'writeDebuffs: cleared')
        end
    end
end

-- Port of Sub CheckCures (mac:12596). Iterates curesArray, checks targets for matching debuffs
-- via KissAssist_Buffs.ini (non-DanNet path), calls castWhat with sentFrom='Cure'.
-- CuresOn: 0=off 1=everyone-in-zone 2=self-only 3=group-only.
-- Also wires MezBroke timer reset that was deferred from Step 2.2 events.lua.
function Heal.checkCures()
    if _state.heal.curesOn == 0 then return end
    if mq.TLO.Me.Invis() and _state.combat.aggroTargetID == '' then return end
    -- mac:12599: return when medding AND medCombat (don't interrupt combat-med for cures)
    if _state.heal.medding and _state.heal.medCombat then return end

    _utils.debug('heals', 'checkCures enter')

    local curesOnVal = _state.heal.curesOn
    local buffFile   = _state.session.buffFileName
    local meID       = mq.TLO.Me.ID()

    -- Build target ID list (mac:12624-12644, non-DanNet path only).
    -- CuresOn=2: self only. Otherwise read section names from KissAssist_Buffs.ini.
    local idList = {}
    if curesOnVal == 2 then
        idList[1] = meID
    else
        local sections = mq.TLO.Ini(buffFile)() or ''
        for id in sections:gmatch('[^|\n,]+') do
            local n = tonumber(id)
            if n and n > 0 then idList[#idList + 1] = n end
        end
        if #idList == 0 then idList[1] = meID end
    end

    for _, targetID in ipairs(idList) do
        local spawn     = mq.TLO.Spawn('id ' .. tostring(targetID))
        local spawnType = spawn and spawn.Type() or ''
        if spawnType == '' or spawnType == 'Corpse' then goto next_target end
        local dist = spawn.Distance() or 9999
        if dist > 100 then goto next_target end

        -- CuresOn=3: skip targets not in our group (mac:12657)
        if curesOnVal == 3 then
            local inGroup = false
            for gi = 0, (mq.TLO.Group.Members() or 0) do
                local gm = mq.TLO.Group.Member(gi)
                ---@diagnostic disable-next-line: undefined-field
                if gm and gm.ID() == targetID then inGroup = true; break end
            end
            if not inGroup then goto next_target end
        end

        local cureCast = false

        for _, entry in ipairs(_state.heal.curesArray) do
            if entry == '' or entry == 'null' or entry == 'NULL' then goto next_cure end

            -- Parse: SpellName[|debuffType[|scope][|condN]] (mac:12665-12686)
            local parts = {}
            for p in (entry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
            local spellName = parts[1] or ''
            local arg2      = (parts[2] or ''):lower()
            local arg3      = (parts[3] or ''):lower()
            if spellName == '' then goto next_cure end

            -- Resolve debuff type and scope from pipe-delimited fields
            local debuffType, scope
            if arg2 == '' or arg2:find('cond', 1, true) then
                debuffType = ''; scope = 'everyone'
            elseif arg2 == 'me' then
                debuffType = ''; scope = 'me'
            else
                debuffType = arg2
                scope = (arg3 == 'me') and 'me' or 'everyone'
            end

            if scope == 'me' and targetID ~= meID then goto next_cure end

            -- Spell ready check: skip if nothing can cast it (mac:12695)
            local rankName = mq.TLO.Spell(spellName).RankName() or spellName
            local ready = mq.TLO.Me.SpellReady(rankName)()
                or mq.TLO.Me.AltAbilityReady(spellName)()
                or mq.TLO.Me.CombatAbilityReady(rankName)()
                or mq.TLO.Me.ItemReady(spellName)()
            if not ready then goto next_cure end

            -- Get debuff state: live TLO for self, ini cache for others (mac:12700-12727)
            local poison, disease, curse, corrupt, mezzed
            if targetID == meID then
                ---@diagnostic disable-next-line: undefined-field
                poison  = mq.TLO.Me.Poisoned.ID()  or 0
                ---@diagnostic disable-next-line: undefined-field
                disease = mq.TLO.Me.Diseased.ID()  or 0
                ---@diagnostic disable-next-line: undefined-field
                local cursedID  = mq.TLO.Me.Cursed.ID() or 0
                ---@diagnostic disable-next-line: undefined-field
                local restlesID = mq.TLO.Me.Song('Restless Curse').ID() or 0
                curse   = cursedID + restlesID
                ---@diagnostic disable-next-line: undefined-field
                corrupt = mq.TLO.Me.Corrupted.ID() or 0
                ---@diagnostic disable-next-line: undefined-field
                mezzed  = mq.TLO.Me.Mezzed.ID()   or 0
                if (poison + disease + curse + corrupt + mezzed) == 0 then break end
            else
                local raw = mq.TLO.Ini(buffFile, tostring(targetID), 'Debuffs')() or '0'
                local rp  = {}
                for p in (raw .. '|'):gmatch('([^|]*)|') do rp[#rp + 1] = p end
                if (tonumber(rp[1]) or 0) == 0 then break end  -- no debuffs recorded for this target
                poison  = tonumber(rp[2]) or 0
                disease = tonumber(rp[3]) or 0
                curse   = tonumber(rp[4]) or 0
                corrupt = tonumber(rp[5]) or 0
                mezzed  = tonumber(rp[6]) or 0
            end

            -- Debuff type match (mac:12729-12744)
            local shouldCure = false
            if debuffType == '' then
                shouldCure = true
            elseif debuffType == 'poison'     then shouldCure = poison  > 0
            elseif debuffType == 'disease'    then shouldCure = disease > 0
            elseif debuffType == 'curse'      then shouldCure = curse   > 0
            elseif debuffType == 'corruption' then shouldCure = corrupt > 0
            elseif debuffType == 'mezzed'     then shouldCure = mezzed  > 0
            end
            if not shouldCure then goto next_cure end

            -- Group spell + out-of-group target guard (mac:12746)
            do
                local tt = mq.TLO.Spell(spellName).TargetType() or ''
                if tt:lower():find('group v1', 1, true) then
                    local inGroup = false
                    for gi = 0, (mq.TLO.Group.Members() or 0) do
                        local gm = mq.TLO.Group.Member(gi)
                        ---@diagnostic disable-next-line: undefined-field
                        if gm and gm.ID() == targetID then inGroup = true; break end
                    end
                    if not inGroup then goto next_cure end
                end
            end

            _utils.debug('heals', string.format('checkCures: %s -> id=%d (%s)', spellName, targetID, debuffType))
            _cast.castWhat(spellName, targetID, 'Cure')
            if _state.cast.castReturn == 'CAST_SUCCESS' then
                ---@diagnostic disable-next-line: undefined-field
                mq.cmdf('/%s o "CURING: >> %s << with %s"',
                    _state.session.broadcastSay, spawn.CleanName() or '', spellName)
                cureCast = true
                -- Re-check heals after a cure (mac:12761-12764)
                if _state.heal.healsOn > 0 then
                    Heal.checkHealth('CheckCures')
                end
            end

            ::next_cure::
        end

        -- After self-cure, refresh debuff ini entry (mac:12768-12776)
        if targetID == meID and cureCast then
            Heal.writeDebuffs()
        end

        ::next_target::
    end

    -- Wire MezBroke timer reset deferred from Step 2.2 events.lua (onMezBroke handler)
    _state.mez.broke = false

    _utils.debug('heals', 'checkCures leave')
end

-- Port of Sub RezCheck (mac:6834). Scans for dead group members / self and rezzes them.
-- Phase order: MA corpse → self (if !rezMeLast) → group slots 1-5 → self (if rezMeLast)
-- → OOC autoRezAll pass with CorpseRezCheck try-count tracking.
-- autoRezOn: 0=off 1=normal 2=OOC-only (mac:6836, 6840).
function Heal.rezCheck()
    if _state.heal.autoRezOn == 0 then return end
    ---@diagnostic disable-next-line: undefined-field
    if _state.misc.dmz and not (mq.TLO.Zone.IsInstance() or false) then return end
    if mq.TLO.Me.Hovering() then return end
    if mq.TLO.Me.Invis() and _state.combat.aggroTargetID == '' then return end
    -- autoRezOn==2: rez only OOC; abort if in combat (mac:6840)
    if _state.heal.autoRezOn == 2 and _state.combat.aggroTargetID ~= '' then return end

    -- Quick probe: if no rez spell is ready at all, bail out early (mac:6855-6860)
    if not rezWithCheck() then
        _utils.debug('heals', 'rezCheck: no rez ready')
        return
    end

    _utils.debug('heals', 'rezCheck enter')

    local RZ_RADIUS   = 150
    local meName      = mq.TLO.Me.CleanName() or ''
    local maName      = _state.session.mainAssist

    -- Cast a rez spell at corpseID, broadcast msg on success, set oocRezTimers[corpseID].
    -- Returns true on CAST_SUCCESS.
    local function doRez(spell, corpseID, broadcastMsg, timerSecs)
        mq.cmdf('/squelch /tar id %d', corpseID)
        mq.delay(500, function() return mq.TLO.Target.ID() == corpseID end)
        if mq.TLO.Target.ID() ~= corpseID then return false end
        if (mq.TLO.Target.Distance() or 9999) > _state.movement.campRadius then
            mq.cmd('/corpse')
            mq.delay(500)
        end
        _cast.castWhat(spell, corpseID, 'RezCheck')
        if _state.cast.castReturn == 'CAST_SUCCESS' then
            mq.cmdf('/%s o "%s"', _state.session.broadcastSay, broadcastMsg)
            _state.heal.oocRezTimers[corpseID] = os.clock() + timerSecs
            mq.cmd('/squelch /target clear')
            return true
        end
        return false
    end

    -- Phase 1: MA corpse (mac:6862-6882)
    if maName ~= '' then
        local maCorpseID = mq.TLO.Spawn(
            'pccorpse ' .. maName .. ' radius ' .. RZ_RADIUS .. ' zradius 50').ID() or 0
        if maCorpseID ~= 0 then
            local spell = rezWithCheck()
            if spell and os.clock() >= (_state.heal.oocRezTimers[maCorpseID] or 0) then
                _utils.debug('heals', 'rezCheck: rezzing MA ' .. maName)
                doRez(spell, maCorpseID, 'REZZING MA =>> ' .. maName .. ' <<=', 60)
            end
        end
    end

    -- Self rez helper (mac:6886-6911 and 6947-6973)
    local function rezSelf()
        local corpseID = mq.TLO.Spawn(
            'pccorpse ' .. meName .. ' radius ' .. RZ_RADIUS .. ' zradius 50').ID() or 0
        if corpseID == 0 then return end
        local spell = rezWithCheck()
        if not spell then return end
        if os.clock() < (_state.heal.oocRezTimers[corpseID] or 0) then return end
        _utils.debug('heals', 'rezCheck: rezzing self')
        doRez(spell, corpseID, 'REZZING ME =>> ' .. meName .. ' <<=', 60)
    end

    -- Group rez helper — slots 1-5 (mac:6914-6945)
    local function rezGroup()
        for i = 1, 5 do
            local spell = rezWithCheck()
            if not spell then break end

            local m = mq.TLO.Group.Member(i)
            ---@diagnostic disable-next-line: undefined-field
            local memberName = m and m.CleanName() or ''
            if memberName == '' or memberName == maName then goto next_gm end

            ---@diagnostic disable-next-line: undefined-field
            local otherZone = m and m.OtherZone() or false
            -- Skip if Call of Wild rez and member is in another zone (mac:6920)
            if spell:find('Call of', 1, true) and otherZone then goto next_gm end

            do
                local corpseID = mq.TLO.Spawn(memberName .. ' pccorpse').ID() or 0
                if corpseID == 0 then goto next_gm end

                if os.clock() < (_state.heal.battleRezTimers[i] or 0) then goto next_gm end

                local dist = mq.TLO.Spawn('id ' .. tostring(corpseID)).Distance() or 9999
                if dist > 100 then goto next_gm end

                _utils.debug('heals', 'rezCheck: rezzing group member ' .. memberName)
                mq.cmdf('/squelch /tar id %d', corpseID)
                mq.delay(500, function() return mq.TLO.Target.ID() == corpseID end)
                if mq.TLO.Target.ID() ~= corpseID then goto next_gm end
                if (mq.TLO.Target.Distance() or 9999) > _state.movement.campRadius then
                    mq.cmd('/corpse')
                    mq.delay(500)
                end
                _cast.castWhat(spell, corpseID, 'RezCheckG')
                if _state.cast.castReturn == 'CAST_SUCCESS' then
                    local isCallOfWild = spell:find('Call of', 1, true)
                    if _state.combat.combatStart then
                        mq.cmdf('/%s o "BATTLE REZZED =>> %s <<="', _state.session.broadcastSay, memberName)
                        _state.heal.battleRezTimers[i] = os.clock() + (isCallOfWild and 360 or 180)
                    else
                        mq.cmdf('/%s o "REZZED =>> %s <<="', _state.session.broadcastSay, memberName)
                        _state.heal.battleRezTimers[i] = os.clock() + (isCallOfWild and 360 or 60)
                    end
                    mq.cmd('/squelch /target clear')
                else
                    -- On failure, throttle retries for this slot (mac:6940)
                    if memberName ~= maName then
                        _state.heal.battleRezTimers[i] = os.clock() + 60
                    end
                end
            end

            ::next_gm::
        end
    end

    -- Phase 2+3: self then group, or group then self depending on rezMeLast (mac:6884, 6946)
    if not _state.heal.rezMeLast then
        rezSelf()
        rezGroup()
    else
        rezGroup()
        rezSelf()
    end

    -- Phase 4: OOC autoRezAll — rez any nearby pccorpse up to 3 times (mac:7018-7081)
    if not _state.combat.combatStart and _state.heal.autoRezAll then
        local corpseCount = mq.TLO.SpawnCount(
            'pccorpse radius ' .. RZ_RADIUS .. ' zradius 50')() or 0
        if corpseCount > 0 then
            for j = 1, corpseCount do
                local spell = rezWithCheck()
                if not spell then break end

                ---@diagnostic disable-next-line: undefined-field
                local corpseID = mq.TLO.NearestSpawn(j,
                    'pccorpse radius ' .. RZ_RADIUS .. ' zradius 50').ID() or 0
                if corpseID == 0 then goto next_ra end
                -- Skip own corpse (already handled above)
                if corpseID == mq.TLO.Spawn(
                    'pccorpse ' .. meName .. ' radius ' .. RZ_RADIUS .. ' zradius 50').ID() then
                    goto next_ra
                end
                if os.clock() < (_state.heal.oocRezTimers[corpseID] or 0) then goto next_ra end

                -- Parse try count from corpseRezCheck (mac:7030-7044)
                local crc     = _state.heal.corpseRezCheck
                local tryStr  = crc:match(tostring(corpseID) .. ':(%d+)|')
                local tries   = tonumber(tryStr) or 0

                if tries < 3 then
                    local corpseSpawn = mq.TLO.Spawn('id ' .. tostring(corpseID))
                    local dist = corpseSpawn and corpseSpawn.Distance() or 9999
                    if dist <= RZ_RADIUS then
                        local rezName = corpseSpawn and corpseSpawn.CleanName() or ''
                        _cast.castWhat(spell, corpseID, 'RezCheckA')
                        if _state.cast.castReturn == 'CAST_SUCCESS' then
                            tries = tries + 1
                            mq.cmdf('/%s o "Rezzing =>> %s for the %d Time<<="',
                                _state.session.broadcastSay, rezName, tries)
                            _state.heal.oocRezTimers[corpseID] = os.clock() + 180
                            -- Update corpseRezCheck string (mac:7055-7059)
                            if tryStr then
                                _state.heal.corpseRezCheck = crc:gsub(
                                    tostring(corpseID) .. ':%d+|',
                                    tostring(corpseID) .. ':' .. tries .. '|')
                            else
                                _state.heal.corpseRezCheck =
                                    tostring(corpseID) .. ':' .. tries .. '|' .. crc
                            end
                            mq.cmd('/squelch /target clear')
                        end
                    end
                end

                ::next_ra::
            end
        else
            -- No corpses remain: prune oocRezTimers and reset corpseRezCheck (mac:7067-7080)
            for id in pairs(_state.heal.oocRezTimers) do
                local s = mq.TLO.Spawn('id ' .. tostring(id))
                if not s or (s.Type() or '') ~= 'Corpse' then
                    _state.heal.oocRezTimers[id] = nil
                end
            end
            _state.heal.corpseRezCheck = 'null'
        end
    end

    _utils.debug('heals', 'rezCheck leave')
end

return Heal
