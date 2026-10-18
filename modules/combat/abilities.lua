-- combat/abilities.lua — ability helpers used by the combat loop: BeforeAttack, pet engage,
-- named-mob burn watch, group escape, AE rotation, Gift of Mana, aggro management,
-- feign/aggro wait and rogue hide.

local mq     = require('mq')
local Config = require('modules.config')
local Util   = require('modules.combat.util')

local Abilities = {}
local _state, _utils, _cast, _cond, _mez
local Combat  -- modules/combat.lua facade; used for calls back into targeting

local dist2D       = Util.dist2D
local spawnGone    = Util.spawnGone
local isDeadOrGone = Util.isDeadOrGone
local getMASpawn   = Util.getMASpawn

function Abilities.init(state, utils, cast, cond, mez, combat)
    _state  = state
    _utils  = utils
    _cast   = cast
    _cond   = cond
    _mez    = mez
    Combat  = combat
end

-- Mirrors Sub BeforeAttack (kissassist.mac:2022).
-- Fires pre-combat abilities from beforeArray before first melee swing.
-- condCheck: 1=all entries, 2=only entries that have |cond flag set.
local function beforeAttack(_tarID, condCheck)
    local beforeArr = _state.arrays.beforeArray
    for i = 1, #beforeArr do
        local entry = beforeArr[i]
        if not entry or entry == 'null' then return end
        if (mq.TLO.Target.ID() or 0) == 0 then return end

        local name = entry:match('^([^|]+)') or entry
        if not name or name == '' or name == 'null' then return end

        -- condCheck==2: skip entries without |cond (conditional-only pass)
        if not entry:find('|cond', 1, true) and condCheck == 2 then
            goto next_before
        end
        -- Condition guard: skip if this entry's condition evaluates false
        if _cond then
            local cp = entry:find('|cond', 1, true)
            if cp then
                local condNo = tonumber(entry:lower():match('|cond(%d+)')) or 0
                if condNo > 0 and not _cond.eval(condNo) then goto next_before end
            end
        end

        -- Item
        local item = mq.TLO.FindItem('=' .. name)
        if item and (item.ID() or 0) ~= 0 and mq.TLO.Me.ItemReady(name)() then
            mq.cmd('/useitem "' .. name .. '"')
            mq.cmd('/echo ## Before Attack >> ' .. name .. ' <<')
        -- AA
        elseif (mq.TLO.Me.AltAbility(name).ID() or 0) ~= 0
               and mq.TLO.Me.AltAbilityReady(name)()
               and (mq.TLO.Me.AltAbility(name).Type() or 0) ~= 5
               and name:lower() ~= 'twincast' then
            mq.cmd('/alt act ' .. (mq.TLO.Me.AltAbility(name).ID() or 0))
            mq.cmd('/echo ## Before Attack >> ' .. name .. ' <<')
        -- Discipline (CombatAbility)
        elseif mq.TLO.Me.CombatAbilityReady(name)()
               and (mq.TLO.Spell(name) ~= nil)
               and ((mq.TLO.Spell(name).EnduranceCost() or 0) < (mq.TLO.Me.CurrentEndurance() or 0)) then
            mq.cmd('/disc "' .. name .. '"')
            mq.cmd('/echo ## Before Attack >> ' .. name .. ' <<')
        -- Activated skill/ability
        elseif (mq.TLO.Me.Skill(name)() or 0) > 0 and mq.TLO.Me.AbilityReady(name)() then
            mq.cmd('/doability "' .. name .. '"')
            mq.cmd('/echo ## Before Attack >> ' .. name .. ' <<')
        -- command: prefix (deferred — CastCommand)
        end

        mq.delay(150)
        ::next_before::
    end
end

-- Mirrors Sub CombatPet (kissassist.mac:2056).
-- Sends pet to attack the current myTargetID mob if in range and below PetAssistAt%.
local function combatPet()
    if (mq.TLO.Me.Pet.ID() or 0) == 0 then return end
    if mq.TLO.Pet.Combat() then return end
    if _state.dps.paused then return end
    if not _state.pet.combatOn then return end

    Combat.combatTargetCheck(1)
    local myID = _state.combat.myTargetID
    if myID == 0 then return end

    local sp       = mq.TLO.Spawn('id ' .. myID)
    local dist3D   = sp and sp.Distance3D() or 999
    local role     = _state.session.role

    -- Pulling: summon pet if too far away (mac:2066-2075, Summon Companion AA)
    if _state.pull.pulling then
        if (mq.TLO.Me.AltAbility('Summon Companion').ID() or 0) ~= 0
           and mq.TLO.Me.AltAbilityReady('Summon Companion')()
           and (mq.TLO.Me.Pet.Distance() or 0) > 79 then
            mq.cmd('/echo Pet! Get over here!')
            _cast.castWhat('Summon Companion', mq.TLO.Me.Pet.ID(), 'CombatPet')
        end
    end

    -- Wait for target buffs if target just changed (mac:2076-2078, minor)
    -- BreakMez for pettank roles (mac:2080)
    local pRole = _state.session.role or ''
    if _mez and (pRole == 'pettank' or pRole == 'pullerpettank' or pRole == 'hunterpettank') then
        _mez.breakMez()
    end
    if mq.TLO.Target.Mezzed.ID() then return end

    -- Send pet to attack or follow based on role and distance (mac:2082-2116)
    local petAttackRange = _state.pet.attackRange
    local campY = _state.movement.campY
    local campX = _state.movement.campX
    local meY   = mq.TLO.Me.Y() or 0
    local meX   = mq.TLO.Me.X() or 0

    if role == 'pettank' or role == 'pullerpettank' then
        if _state.movement.returnToCamp then
            local petY = mq.TLO.Me.Pet.Y() or 0
            local petX = mq.TLO.Me.Pet.X() or 0
            local petCampDist = dist2D(campY, campX, petY, petX)
            local meCampDist  = dist2D(campY, campX, meY, meX)
            local petStance   = mq.TLO.Me.Pet.Stance() or ''
            if petStance ~= 'FOLLOW' then
                if petCampDist > _state.movement.campRadius
                   or meCampDist > _state.movement.campRadius then
                    mq.cmd('/pet follow')
                elseif meCampDist <= _state.movement.campRadius and dist3D > petAttackRange then
                    mq.cmd('/pet follow')
                end
            end
            if dist2D(campY, campX, meY, meX) <= _state.movement.campRadius
               and dist3D < petAttackRange then
                mq.cmd('/pet attack')
                mq.delay(250)
                mq.cmd('/pet swarm')
            end
        else
            if dist3D < petAttackRange then
                mq.cmd('/pet attack')
                mq.delay(250)
                mq.cmd('/pet swarm')
            elseif (mq.TLO.Me.Pet.Stance() or '') ~= 'FOLLOW' then
                mq.cmd('/pet follow')
            end
        end
    else
        if dist3D < petAttackRange then
            mq.cmd('/pet attack')
            mq.delay(250)
            mq.cmd('/pet swarm')
        elseif (mq.TLO.Me.Pet.Stance() or '') ~= 'FOLLOW' then
            mq.cmd('/pet follow')
        end
    end
    _state.timers.petAttack = os.clock() + 3
end

-- Mirrors Sub ValidateTarget (kissassist.mac:948).
-- Validates current Target (or spawnID) as a legal attack target.
-- Mirrors Sub IsSpawnNamed (mac:12872).
-- Returns true if spawnID is a named mob.
-- SpawnMaster mode checks Alert[5] instead of Spawn.Named (requires MQ2SpawnMaster).
local function isSpawnNamed(spawnID)
    if not spawnID or spawnID == 0 then return false end
    local sp = mq.TLO.Spawn('id ' .. spawnID)
    if not sp or not sp() then return false end
    if _state.session.useSpawnMaster then
        return (mq.TLO.SpawnCount('id ' .. spawnID .. ' alert 5')() or 0) > 0
    end
    return sp.Named() or false
end

-- Mirrors Sub NamedWatch (mac:12886). Two paths:
--   ignoreTarget=false — evaluate current target (melee path, mac:12889)
--   ignoreTarget=true  — scan xtarhater for a nearby named (SkipCombat healer path, mac:12915)
local function namedWatch(ignoreTarget)
    if _state.combat.burnAllNamed == 0 then return end
    local myID = _state.combat.myTargetID or 0

    if not ignoreTarget then
        if myID == 0 then return end
        local sp = mq.TLO.Spawn('id ' .. myID)
        if not sp or not sp() then return end
        if (sp.Distance() or 999) > _state.combat.meleeDistance then return end
        local tName = (sp.CleanName() or ''):lower()
        local named = isSpawnNamed(myID)
        -- BurnAllNamed==2: named flag not enough — must also be on the watch list
        if named and _state.combat.burnAllNamed == 2 then
            named = false
            for _, wn in ipairs(_state.combat.namedWatchList) do
                if wn == tName then named = true; break end
            end
        end
        -- BurnAllNamed==1 miss OR mode==2: check watch list directly
        if not named and #_state.combat.namedWatchList > 0 then
            for _, wn in ipairs(_state.combat.namedWatchList) do
                if wn == tName then named = true; break end
            end
        end
        if named then
            mq.cmd('/popup *** Mob:(' .. sp.CleanName() .. ') is a NAMED!')
            mq.cmd('/echo *** Mob:('  .. sp.CleanName() .. ') is a NAMED!')
            if _cast.doBurn then _cast.doBurn() end
            _state.combat.namedCheck = true
        end
    else
        -- Healer/caster path: scan xtarhater for a nearby named (mac:12915)
        local dist    = _state.combat.meleeDistance
        local foundID = 0
        if _state.session.useSpawnMaster then
            local cnt = mq.TLO.SpawnCount('xtarhater radius ' .. dist .. ' alert 5')() or 0
            if cnt > 0 then
                local ns = mq.TLO.Spawn('xtarhater radius ' .. dist .. ' alert 5')
                if ns and ns.ID() then foundID = ns.ID() end
            end
        else
            local cnt = mq.TLO.SpawnCount('xtarhater named radius ' .. dist)() or 0
            if cnt > 0 then
                local ns = mq.TLO.Spawn('xtarhater named radius ' .. dist)
                if ns and ns.ID() then foundID = ns.ID() end
            end
        end
        if foundID == 0 then return end
        -- BurnAllNamed==2: filter against watch list
        if _state.combat.burnAllNamed == 2 then
            local ns    = mq.TLO.Spawn('id ' .. foundID)
            local tName = ns and (ns.CleanName() or ''):lower() or ''
            local found = false
            for _, wn in ipairs(_state.combat.namedWatchList) do
                if wn == tName then found = true; break end
            end
            if not found then return end
        end
        local ns    = mq.TLO.Spawn('id ' .. foundID)
        local tName = ns and ns.CleanName() or ''
        _state.combat.myTargetID   = foundID
        _state.combat.myTargetName = tName
        mq.cmd('/popup *** Mob:(' .. tName .. ') is a NAMED!')
        mq.cmd('/echo *** Mob:('  .. tName .. ') is a NAMED!')
        if _cast.doBurn then _cast.doBurn() end
        _state.combat.namedCheck = true
        _state.combat.myTargetID = 0   -- reset after burn (mac:12945)
    end
end

-- Mirrors Sub GroupEscape (mac:6335). WIZ/DRU only, non-raid.
-- Triggers group evac when in combat (or have aggro) and the MA is dead or missing.
local function groupEscape()
    if (_state.session.groupEscapeOn or 0) == 0 then return end
    if (mq.TLO.Raid.Members() or 0) > 0 then return end
    local inCombat = mq.TLO.Me.CombatState() == 'COMBAT'
    local hasAggro = (tonumber(_state.combat.aggroTargetID) or 0) ~= 0
    if not (inCombat or hasAggro) then return end
    if not spawnGone(getMASpawn()) then return end
    mq.cmd('/echo + The MA is dead, activating Group Escape!')
    local cls = (mq.TLO.Me.Class.ShortName() or ''):lower()
    if cls == 'dru' then
        mq.cmd('/removebuff "Divine Barrier"')
        if mq.TLO.Me.AltAbilityReady('Exodus')() then
            _cast.castWhat('Exodus', mq.TLO.Me.ID(), 'GroupEscape', 0, 0)
        elseif mq.TLO.Me.Book('Succor')() then
            _cast.castWhat('Succor', mq.TLO.Me.ID(), 'GroupEscape', 0, 0)
        end
    elseif cls == 'wiz' then
        if mq.TLO.Me.AltAbilityReady('Exodus')() then
            _cast.castWhat('Exodus', mq.TLO.Me.ID(), 'GroupEscape', 0, 0)
        elseif mq.TLO.Me.Book('Evacuate')() then
            _cast.castWhat('Evacuate', mq.TLO.Me.ID(), 'GroupEscape', 0, 0)
        end
    end
end

-- AE spell rotation (mac:12473-12560 Sub AECheck).
-- Called each fight tick when aeOn; casts first eligible AE slot whose mob-count threshold is met.
local function aeCheck()
    local s = _state
    if not s.combat.aeOn then return end
    if (mq.TLO.Target.Type() or ''):lower() == 'corpse' then return end
    if s.combat.aggroTargetID == 0 then return end
    if not _cast or not _cast.castWhat then return end

    local aeRadius = s.combat.aeRadius
    Combat.mobRadar('los', aeRadius)

    local mobCountTemp = mq.TLO.SpawnCount(
        'npc xtarhater targetable los radius ' .. aeRadius .. ' zradius 50 noalert 3')() or 0
    if mobCountTemp <= 0 then return end

    local aeRaw  = Config.get('AE', 'AE', nil) or {}
    local aeSize = tonumber(Config.get('AE', 'AESize', '10')) or 10

    for i = 1, aeSize do
        local raw = aeRaw[i] or 'null'
        if raw == 'null' or raw == '' then goto ae_next end

        -- Strip optional |condNNN suffix
        local condNo  = 0
        local condPos = raw:lower():find('|cond%d')
        if condPos then
            condNo = tonumber(raw:lower():match('|cond(%d+)')) or 0
            raw    = raw:sub(1, condPos - 1)
        end

        local parts = {}
        for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
        local spell    = parts[1] or ''
        local mobCount = tonumber(parts[2]) or 1
        local tgt      = (parts[3] or 'Mob'):upper()

        if spell == '' or spell == 'null' then goto ae_next end
        if mobCount > mobCountTemp then goto ae_next end

        -- burn: trigger burn rotation when threshold met
        if spell:lower() == 'burn' then
            if not s.combat.burnActive then
                mq.cmdf('/echo AE-> %d Mobs: Activating BURN', mobCountTemp)
                if _cast and _cast.doBurn then _cast.doBurn() end
            end
            return
        end

        -- Resolve target spawn ID
        local targetID
        if tgt == 'ME' then
            targetID = mq.TLO.Me.ID()
        elseif tgt == 'MA' then
            targetID = getMASpawn().ID()
        elseif tgt == 'PET' then
            targetID = mq.TLO.Me.Pet.ID()
        else  -- Mob / Single
            targetID = s.combat.myTargetID ~= 0 and s.combat.myTargetID or nil
        end
        if not targetID or targetID == 0 then goto ae_next end

        -- Safety check for AE casts: skip if it would pull more mobs than are on XTarget
        if tgt ~= 'SINGLE' then
            local tgtSpawn = mq.TLO.Spawn('id ' .. targetID)
            if tgtSpawn and (tgtSpawn.ID() or 0) ~= 0 then
                local tgtX    = tgtSpawn.X() or 0
                local tgtY    = tgtSpawn.Y() or 0
                local aeRange = mq.TLO.Spell(spell).AERange() or 0
                if aeRange == 0 then aeRange = aeRadius end
                local locStr   = string.format('%f,%f radius %d', tgtX, tgtY, aeRange)
                local xtCount  = mq.TLO.SpawnCount('npc xtarhater loc ' .. locStr)() or 0
                local allCount = mq.TLO.SpawnCount('npc loc ' .. locStr)() or 0
                if xtCount < allCount then
                    _utils.debug('combat', 'AE-> Casting %s would aggro more mobs(%d) than on xtarget(%d)',
                        spell, allCount, xtCount)
                    goto ae_next
                end
            end
        end

        local result = _cast.castWhat(spell, targetID, 'AoE', condNo)
        if result == 'CAST_SUCCESS' then
            if tgt == 'SINGLE' then
                local name = (mq.TLO.Spawn('id ' .. targetID).CleanName() or '?')
                mq.cmdf('/echo AE-> %s on Single target >> %s <<', spell, name)
            else
                mq.cmdf('/echo AE-> %d Mobs: Casting AE %s', mobCountTemp, spell)
            end
        end
        do return end  -- one cast attempt per tick

        ::ae_next::
    end
end

-- Gift of Mana proc handler (mac:11497-11580).
-- Consumes gomActive, iterates GoM spell list, casts the first eligible free spell.
-- Per-slot timers suppress a slot until the buffed spell's duration expires.
local function checkGoM()
    local s = _state
    if not s.bard.gomActive then return end
    s.bard.gomActive  = false
    s.timers.gomTimer = os.clock() + 3

    if not _cast or not _cast.castWhat then return end

    local gomRaw  = Config.get('GoM', 'GoMSpell', nil) or {}
    local gomSize = tonumber(Config.get('GoM', 'GoMSize', '3')) or 3

    for i = 1, gomSize do
        local raw = gomRaw[i] or 'null'
        if raw == 'null' or raw == '' then goto gom_next end

        local spell, tgt = raw:match('^([^|]+)|(.+)$')
        if not spell then spell, tgt = raw, 'MA' end
        tgt = (tgt or 'MA'):upper()

        -- Suppress slot while buff is still active on target
        if (s.timers.gomSpellTimers[i] or 0) > os.clock() then goto gom_next end

        -- Spell must be in book and ready
        if not mq.TLO.Me.SpellReady(spell)() then goto gom_next end

        -- Resolve target to a spawn ID
        local targetID
        if tgt == 'ME' then
            targetID = mq.TLO.Me.ID()
        elseif tgt == 'MA' then
            targetID = getMASpawn().ID()
        else  -- Mob
            targetID = s.combat.myTargetID ~= 0 and s.combat.myTargetID or nil
            if targetID then
                local sp = mq.TLO.Spawn('id ' .. targetID)
                if not sp or (sp.Type() or ''):lower() == 'corpse' then
                    goto gom_next
                end
            end
        end
        if not targetID or targetID == 0 then goto gom_next end

        mq.cmdf('/echo Gift of Mana detected! Trying to cast %s', spell)
        local result = _cast.castWhat(spell, targetID, 'GoM', 0)
        if result == 'CAST_SUCCESS' then
            local dur = mq.TLO.Spell(spell).MyDuration.TotalSeconds() or 0
            s.timers.gomSpellTimers[i] = os.clock() + dur
            mq.cmdf('/echo Gift of Mana Casting >> %s <<', spell)
            return
        elseif result == 'CAST_CANCELLED' then
            return
        end
        -- fizzle/resist/interrupt: fall through to next slot

        ::gom_next::
    end
end

-- Mirrors Sub FeignAggroCheck (kissassist.mac:14524).
-- If still feigning/invis after combat, waits out the aggroOff timer before standing.
local function feignAggroCheck()
    local expiry = _state.timers.aggroOff or 0
    if expiry ~= 0 and os.clock() < expiry then
        while mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() do
            mq.doevents()
            mq.delay(250)
        end
    else
        mq.doevents()
    end
end

-- Mirrors Sub AggroCheck (kissassist.mac:2373).
-- Iterates aggroArray casting aggro-management abilities based on pctAggro thresholds.
-- Entry format: spellName|pct|glt|target  where glt is < (gain) >> << (secondary) >> > (lose).
local function aggroCheck()
    local myID = _state.combat.myTargetID
    if myID == 0 then return end
    if isDeadOrGone(myID) then return end

    -- MA with target-switching: sync target first (mac:2383)
    if _state.session.iAmMA and _state.combat.targetSwitchingOn
       and (mq.TLO.Target.ID() or 0) ~= 0
       and (mq.TLO.Target.ID() or 0) ~= myID
       and _state.combat.combatStart then
        Combat.combatTargetCheck(1)
    end
    if _state.combat.myTargetID == 0 then return end

    for _, entry in ipairs(_state.combat.aggroArray) do
        if not entry then break end
        local condNo = entry.condNo or 0
        if condNo > 0 and _cond and not _cond.eval(condNo) then goto next_aggro end
        local rawEntry = entry.name or ''
        if rawEntry == 'null' or rawEntry == '' then break end

        -- Parse: spellName|pct|glt|target
        local parts = {}
        for p in (rawEntry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
        local spellName  = parts[1] or ''
        local pct        = tonumber(parts[2] or '') or 0
        local glt        = parts[3] or ''
        local targetType = parts[4] or ''

        if spellName == '' or spellName == 'null' then goto next_aggro end

        -- Skip active self-disc (mac:2410)
        if (mq.TLO.Me.CombatAbility(spellName).ID() or 0) ~= 0 then
            local asSp = mq.TLO.Spell(spellName)
            if asSp and (asSp.Duration.TotalSeconds() or 0) > 0
               and ((asSp.TargetType() or ''):lower() == 'self')
               and (mq.TLO.Me.ActiveDisc.ID() or 0) ~= 0 then
                goto next_aggro
            end
        end

        -- Ability ready check (mac:2395)
        if not mq.TLO.Me.SpellReady(spellName)()
           and not mq.TLO.Me.AltAbilityReady(spellName)()
           and not mq.TLO.Me.AbilityReady(spellName)()
           and not mq.TLO.Me.CombatAbilityReady(spellName)() then
            goto next_aggro
        end

        -- Aggro threshold check (mac:2397-2409)
        local myPct  = mq.TLO.Me.PctAggro() or 0
        local secPct = mq.TLO.Target.SecondaryPctAggro() or 0
        if glt == '<' then
            -- Gain aggro: cast when my aggro is below pct
            if pct <= myPct then goto next_aggro end
        elseif glt == '<<' then
            -- Secondary aggro: cast when secondary holder is above (pct-100)%
            local adjPct = pct - 100
            if secPct == 0 or secPct < adjPct then goto next_aggro end
        elseif glt == '>' then
            -- Lose aggro: cast when my aggro is above pct
            if pct > myPct then goto next_aggro end
        else
            goto next_aggro
        end

        -- Resolve cast target (mac:2412-2420)
        local aggroTID = myID
        local tl = targetType:lower()
        if tl == 'me' then
            aggroTID = mq.TLO.Me.ID() or 0
        elseif tl == 'ma' then
            aggroTID = getMASpawn().ID() or 0
        elseif tl == 'pet' then
            aggroTID = mq.TLO.Me.Pet.ID() or 0
        elseif tl == 'inc' then
            -- INC: target mob only when in melee range; skip if close (mac:2421)
            if (mq.TLO.Spawn('id ' .. myID).Distance() or 0) < _state.combat.meleeDistance then
                goto next_aggro
            end
        end
        if aggroTID == 0 then goto next_aggro end

        -- Cast (mac:2423)
        local result = _cast.castWhat(spellName, aggroTID, 'Aggro', 0, 0)
        if result == 'CAST_SUCCESS' then
            printf('Casting >> %s << to control AGGRO(%s) on %s',
                spellName, glt,
                mq.TLO.Spawn('id ' .. aggroTID).CleanName() or '')
            -- Start aggroOff timer on lose-aggro cast if feigning/invis (mac:2427-2429)
            if glt == '>' and (_state.timers.aggroOff or 0) == 0 then
                if mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() then
                    _state.timers.aggroOff = os.clock() + 20
                end
            end
            break  -- one aggro ability per call (mac:2431)
        end
        -- Break-early if threshold already satisfied after failed cast (mac:2433-2435)
        if glt == '>' and pct > myPct then break end
        if glt == '<<' and secPct < (pct - 100) then break end
        if glt == '<' and pct < myPct then break end

        ::next_aggro::
    end
    _utils.debug('combat', 'aggroCheck: leave')
end

-- Mirrors Sub Roguestuff (kissassist.mac:15205). ROG-only auto-stealth after combat.
local function rogueHide()
    if not _state.session.iAmARogue then return end
    if not _state.misc.autoHide then return end
    if mq.TLO.Me.Hovering() then return end
    if mq.TLO.Me.Combat() then return end
    if mq.TLO.Me.AbilityReady('hide') and mq.TLO.Me.AbilityReady('sneak') then
        mq.cmd('/doability hide')
        mq.cmd('/doability sneak')
    end
end

Abilities.beforeAttack    = beforeAttack
Abilities.combatPet       = combatPet
Abilities.isSpawnNamed    = isSpawnNamed
Abilities.namedWatch      = namedWatch
Abilities.groupEscape     = groupEscape
Abilities.aeCheck         = aeCheck
Abilities.checkGoM        = checkGoM
Abilities.feignAggroCheck = feignAggroCheck
Abilities.aggroCheck      = aggroCheck
Abilities.rogueHide       = rogueHide

return Abilities
