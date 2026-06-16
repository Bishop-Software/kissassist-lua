local mq     = require('mq')
local Config = require('modules.config')

local Debuff = {}
local _state, _utils, _cast, _healing, _cond, _combat

-- Parse "SpellName|target|damod[|condNNN]" → { spell, tag1, tag2, condNo }
local function parseDebuffEntry(raw)
    local cond    = ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
    return {
        spell  = parts[1] or '',
        tag1   = parts[2] or '',
        tag2   = parts[3] or '',
        condNo = condNo,
    }
end

function Debuff.init(state, utils, cast, healing, cond, combat)
    _state   = state
    _utils   = utils
    _cast    = cast
    _healing = healing
    _cond    = cond
    _combat  = combat

    local debuffOn   = tonumber(Config.get('Debuff', 'DebuffOn',   '0')) or 0
    local debuffSize = tonumber(Config.get('Debuff', 'DebuffSize', '0')) or 0
    local debuffRaw  = Config.get('Debuff', 'Debuff', nil) or {}

    _state.debuff.on    = debuffOn
    _state.debuff.size  = debuffSize
    _state.debuff.slots = {}
    _state.debuff.count = 0

    for i = 1, debuffSize do
        local raw = debuffRaw[i] or 'null'
        if raw ~= 'null' and raw ~= '' then
            local slot = parseDebuffEntry(raw)
            if slot.spell ~= '' then
                _state.debuff.slots[#_state.debuff.slots + 1] = slot
                _state.debuff.count = _state.debuff.count + 1
            end
        end
    end

    _utils.debug('debuff', 'Debuff.init: on=%d size=%d count=%d', debuffOn, debuffSize, _state.debuff.count)
end

-- Scan XTarget auto-haters in melee range with LOS; return array of spawn IDs.
-- Mirrors the XTarget scan in Sub DoDebuffStuff (kissassist.mac:7654-7700).
local function debuffRadar()
    local results  = {}
    local xTotal   = _state.combat.xSlotTotal
    local maxDist  = _state.combat.meleeDistance

    for j = 1, xTotal do
        local xt = mq.TLO.Me.XTarget(j)
        if not xt then goto next end
        local xtID = xt.ID() or 0
        if xtID == 0 then goto next end
        if (xt.TargetType() or '') ~= 'Auto Hater' then goto next end

        local sp = mq.TLO.Spawn('id ' .. xtID)
        if not sp or (sp.ID() or 0) == 0 then goto next end
        if (sp.Type() or ''):lower() == 'corpse' then goto next end
        if (sp.Distance() or 999) >= maxDist then goto next end
        if not sp.LineOfSight() then goto next end

        -- Skip PCs and PC-owned pets (mac:7680-7683)
        local spType = (sp.Type() or ''):lower()
        if spType == 'pc' then goto next end
        if spType == 'pet' then
            local masterSp = mq.TLO.Spawn('id ' .. (sp.Master.ID() or 0))
            if masterSp and (masterSp.Type() or ''):lower() == 'pc' then goto next end
        end

        results[#results + 1] = xtID
        ::next::
    end

    return results
end

-- Port of Sub DebuffCast (kissassist.mac:7730).
-- Iterates debuff slots against a single target; fwait=true waits up to 2s for readiness.
function Debuff.cast(targetID, fwait)
    local debuffCount = _state.debuff.count or 0
    if debuffCount == 0 then return end

    local sp = mq.TLO.Spawn('id ' .. targetID)
    if not sp or (sp.ID() or 0) == 0 then return end
    if (sp.Type() or ''):lower() == 'corpse' then return end

    local tidStr = tostring(targetID)

    for i = 1, debuffCount do
        local slot = _state.debuff.slots[i]
        if not slot then break end

        local spellName = slot.spell or ''
        if spellName == '' or spellName == 'null' then goto next_debuff end

        -- Condition gate (mac:7736)
        if slot.condNo and slot.condNo ~= 0 and _cond then
            if not _cond.eval(slot.condNo) then goto next_debuff end
        end

        -- DBOTimer/DBOList: skip if mob was recently debuffed with this slot (mac:7634-7648)
        local dboExpiry = (_state.debuff.timers or {})[i] or 0
        if os.clock() < dboExpiry then
            local list = (_state.debuff.lists or {})[i] or ''
            if list:find('|' .. tidStr, 1, true) then goto next_debuff end
        end

        -- Check effective cast range (mac:7759-7763)
        local castRange = mq.TLO.Spell(spellName).Range() or 0
        local aeRange   = mq.TLO.Spell(spellName).AERange() or 0
        local effRange  = (castRange >= aeRange) and castRange or aeRange
        if effRange == 0 then effRange = _state.combat.meleeDistance end
        if (sp.Distance() or 999) > effRange then goto next_debuff end

        -- Check readiness (mac:7755-7757); fwait=true: wait up to 2s for primary mob
        local rankName = mq.TLO.Spell(spellName).RankName() or spellName
        local ready = mq.TLO.Me.SpellReady(rankName)()
                   or mq.TLO.Me.AltAbilityReady(spellName)()
                   or mq.TLO.Me.CombatAbilityReady(rankName)()
        if not ready then
            if fwait then
                local waitUntil = os.clock() + 2
                while os.clock() < waitUntil do
                    mq.doevents()
                    if _healing and (_state.heals.on or 0) ~= 0 then
                        _healing.checkHealth('DebuffCast')
                    end
                    mq.delay(100)
                    if mq.TLO.Me.SpellReady(rankName)()
                       or mq.TLO.Me.AltAbilityReady(spellName)()
                       or mq.TLO.Me.CombatAbilityReady(rankName)() then
                        ready = true
                        break
                    end
                end
            end
            if not ready then goto next_debuff end
        end

        -- GroupEscape check before each slot cast (mac:7858)
        if _combat then _combat.groupEscape() end

        -- Cast via central dispatcher (mac:7738-7744)
        local result = _cast.castWhat(spellName, targetID, 'DebuffCast')
        _utils.debug('debuff', 'Debuff.cast [%d] %s on %d → %s', i, spellName, targetID, result or 'nil')

        if result == 'CAST_SUCCESS' then
            -- Track: update DBOList and set DBOTimer (mac:7744+)
            local existing = _state.debuff.lists[i] or ''
            if not existing:find('|' .. tidStr, 1, true) then
                _state.debuff.lists[i] = existing .. '|' .. tidStr
            end
            local duration = mq.TLO.Spell(spellName).Duration() or 30
            _state.debuff.timers[i] = os.clock() + duration
            printf('** Debuff %s on %s', spellName, sp.CleanName() or '')
        elseif result == 'CAST_IMMUNE' or result == 'CAST_TAKEHOLD' then
            -- Suppress retries for a long window (mac:7748-7750)
            _state.debuff.timers[i] = os.clock() + 600
            local list = _state.debuff.lists[i] or ''
            if not list:find('|' .. tidStr, 1, true) then
                _state.debuff.lists[i] = list .. '|' .. tidStr
            end
        end

        ::next_debuff::
    end
end

-- Port of Sub DoDebuffStuff (kissassist.mac:7613).
-- Guards, cleans stale tracking, then casts on primary and XTarget haters.
function Debuff.check(firstMobID)
    if (_state.debuff.on or 0) == 0 then return end
    if (_state.debuff.count or 0) == 0 then return end
    if mq.TLO.Window('RespawnWnd').Open() then return end
    if _state.dps.paused then return end
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end

    -- No myTargetID and MA is present as non-merc: skip (mac:7616)
    if (_state.combat.myTargetID or 0) == 0 then
        local maID = mq.TLO.Spawn('=' .. (_state.session.mainAssist or '')).ID() or 0
        if maID ~= 0 and (mq.TLO.Spawn('id ' .. maID).Type() or '') ~= 'Mercenary' then return end
    end

    -- Bard+MA: skip when in active combat to avoid interruption (mac:7628-7631)
    if _state.session.iAmABard and _state.session.iAmMA
       and (_state.combat.myTargetID or 0) ~= 0
       and (_state.combat.aggroTargetID or '') ~= '' then
        return
    end

    mq.doevents()

    -- Clean stale entries from dboLists (dead/far/corpse mobs) (mac:7641-7648)
    for i = 1, (_state.debuff.count or 0) do
        local list = (_state.debuff.lists or {})[i] or ''
        if list ~= '' then
            local cleaned = ''
            for idStr in list:gmatch('|(%d+)') do
                local id = tonumber(idStr) or 0
                if id ~= 0 then
                    local mob = mq.TLO.Spawn('id ' .. id)
                    if mob and (mob.ID() or 0) ~= 0
                       and (mob.Distance() or 999) <= 200
                       and (mob.Type() or ''):lower() ~= 'corpse' then
                        cleaned = cleaned .. '|' .. idStr
                    end
                end
            end
            _state.debuff.lists[i] = cleaned
        end
    end

    -- Debuff primary target (mac:7653)
    if firstMobID and firstMobID ~= 0 then
        local fType = (mq.TLO.Spawn('id ' .. firstMobID).Type() or ''):lower()
        if fType == 'npc' or fType == 'pet' then
            Debuff.cast(firstMobID, true)
        end
    end

    -- Debuff additional XTarget auto-haters in range (mac:7654-7700)
    local haters = debuffRadar()
    for _, xtID in ipairs(haters) do
        mq.doevents()
        if _state.dps.paused then return end
        if xtID == firstMobID then goto next_xt end

        -- Drop melee briefly for off-target cast (mac:7686-7690); restored after loop
        if _state.combat.meleeOn and mq.TLO.Me.Combat()
           and (not _state.session.iAmMA or xtID ~= (mq.TLO.Target.ID() or 0)) then
            mq.cmd('/attack off')
            mq.delay(500, function() return not mq.TLO.Me.Combat() end)
        end

        local fwait = (_state.debuff.on == 2 and not _state.combat.burnCalled)
        Debuff.cast(xtID, fwait)

        ::next_xt::
    end

    -- Restore target to primary mob and resume melee (mac:7701-7707)
    if (mq.TLO.Target.ID() or 0) ~= _state.combat.myTargetID
       and _state.combat.myTargetID ~= 0 then
        local mysp = mq.TLO.Spawn('id ' .. _state.combat.myTargetID)
        if mysp and (mysp.Type() or ''):lower() ~= 'corpse' then
            mq.cmd('/target id ' .. _state.combat.myTargetID)
            mq.delay(1000, function()
                return (mq.TLO.Target.ID() or 0) == _state.combat.myTargetID
            end)
            if _state.combat.meleeOn and _state.combat.attacking then
                mq.cmd('/squelch /attack on')
            end
        end
    end

    _utils.debug('debuff', 'Debuff.check: leave')
end

-- Clear all per-fight debuff tracking (call on combat end).
function Debuff.resetFight()
    _state.debuff.timers = {}
    _state.debuff.lists  = {}
end

return Debuff
