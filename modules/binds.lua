local mq    = require('mq')
local Utils = require('modules.utils')

local Binds = {}

local BOUND = {}

local function bind(cmd, fn)
    mq.bind(cmd, fn)
    BOUND[cmd] = true
end

local state, _buffs, _cast, _combat, _config, _comms

-- Maps /debug subcommand names to state.debug field names
local DEBUG_FIELDS = {
    buffs  = 'buffs',
    combat = 'combat',
    cast   = 'cast',
    chainp = 'chainpull',
    heals  = 'heals',
    mez    = 'mez',
    move   = 'move',
    pet    = 'pet',
    pull   = 'pull',
    rk     = 'rk',
    bard   = 'bard',
    charm  = 'charm',
    comms  = 'comms',
    debuff = 'debuff',
    merc   = 'merc',
}

-- ─── Debug ────────────────────────────────────────────────────────────────────

local function onDebug(cmd1, cmd2, cmd3)
    local c1 = (cmd1 or ''):lower()
    local c2 = (cmd2 or ''):lower()
    local c3 = (cmd3 or ''):lower()

    local function asOnOff(s)
        if s == 'on' or s == '1' then return true end
        if s == 'off' or s == '0' then return false end
        return nil
    end

    local field, onoff

    if c1 == 'all' then
        field = 'all'
        onoff = asOnOff(c2)
    elseif DEBUG_FIELDS[c1] then
        field = DEBUG_FIELDS[c1]
        onoff = asOnOff(c2)
    elseif asOnOff(c1) ~= nil then
        field = 'general'
        onoff = asOnOff(c1)
        if not onoff and state.debug.all then field = 'all' end
    elseif c1 == 'help' then
        printf('\ay/debug [all|bard|buffs|cast|chainp|charm|combat|comms|debuff|heals|merc|mez|move|pet|pull|rk] [on|off] [log]')
        return
    else
        field = state.debug.all and 'all' or 'general'
        onoff = nil  -- toggle
    end

    if field == 'all' then
        local val = onoff ~= nil and onoff or not state.debug.all
        for k in pairs(state.debug) do
            if k ~= 'logging' then state.debug[k] = val end
        end
        printf('\ay>> Debug All %s', val and 'On' or 'Off')
    elseif field then
        local val = onoff ~= nil and onoff or not state.debug[field]
        state.debug[field] = val
        printf('\ay>> Debug %s %s', field, val and 'On' or 'Off')
    end

    -- log/logc as cmd2 (when cmd1 is field name) or cmd3
    local logcmd = (c3 ~= '' and c3 or (c2 == 'log' or c2 == 'logc') and c2 or '')
    if logcmd == 'log' or logcmd == 'logc' then
        state.debug.logging = not state.debug.logging
        if state.debug.logging then mq.cmd('/mlog on') else mq.cmd('/mlog off') end
        printf('\ay>> Debug logging %s', state.debug.logging and 'On' or 'Off')
    end
end

-- ─── Combat ───────────────────────────────────────────────────────────────────

local function onBurn(what, st)
    local w = (what or ''):lower()
    local s = (st   or ''):lower()
    if w == 'on' or s == 'on' then
        state.combat.burnOn     = true
        state.movement.campZone = mq.TLO.Zone.ID()
        printf('\awTurning Burn On.')
    elseif w == 'off' or s == 'off' then
        state.combat.burnOn     = false
        state.combat.burnActive = false
        state.combat.burnCalled = false
        state.combat.burnID     = 0
        printf('\awTurning Burn Off.')
    end
    if not state.combat.burnOn then return end
    if w == 'on' and s ~= 'doburn' then return end
    state.combat.burnCalled = true
    local burnWhat = tonumber(what) or 0
    if burnWhat > 0 then
        state.combat.burnID = burnWhat
    elseif state.combat.myTargetID > 0 then
        state.combat.burnID = state.combat.myTargetID
    else
        local tid   = mq.TLO.Target.ID() or 0
        local ttype = (mq.TLO.Target.Type() or ''):lower()
        if tid > 0 and ttype ~= 'pc' and ttype ~= 'pet' and ttype ~= 'mercenary' and ttype ~= 'corpse' then
            state.combat.burnID = tid
        end
    end
    -- Burn rotation in M4 (combat.lua)
end

local function onBackOff(onOffFlag, _waitFlag)
    local flag = (onOffFlag or ''):lower()
    local pausing
    if flag == 'on' or flag == '1' then
        pausing = false
    elseif flag == 'off' or flag == '0' then
        pausing = true
    else
        pausing = not state.dps.paused
    end
    state.dps.paused = pausing
    if pausing then
        state.combat.combatStart = false
        printf('\awBacking off — DPS paused.')
    else
        printf('\awResuming — DPS active.')
    end
    -- CombatReset + /stick off in M4 (combat.lua)
end

local function onSwitch(_lockOnFlag, newTargetID)
    if state.session.iAmMA then return end
    state.combat.calledTargetID = tonumber(newTargetID) or 0
    _combat.combatReset('switch', 'switchnow')
    printf('\aw>> Switching to target ID: %d', state.combat.calledTargetID)
end

local function onSwitchMA(newMA, newRole, doWhat)
    if not newMA or newMA == '' then return end
    state.session.mainAssist = newMA
    state.session.iAmMA = (newMA:lower() == (mq.TLO.Me.CleanName() or ''):lower())
    state.combat.calledTargetID = 0
    _combat.combatReset('switchma', 'switchma')
    -- Broadcast to group when doWhat is absent or 0 (mac:10973-10978 DanNet equivalent)
    if (not doWhat or doWhat == '' or tonumber(doWhat) == 0) and _comms then
        _comms.broadcast('SWITCHMA', { newMA = newMA, newRole = newRole or 'tank' })
    end
    printf('\awMain Assist changed to \at%s\aw (IAmMA=%s)', newMA, tostring(state.session.iAmMA))
end

local function onSwitchTarget(idArg)
    local newID = tonumber(idArg) or mq.TLO.Target.ID() or 0
    state.combat.myTargetID = 0
    if newID ~= 0 then
        state.combat.aggroTargetID = tostring(newID)
        local name = (mq.TLO.Spawn('id ' .. newID).CleanName() or '?')
        printf('\awSwitching combat target to \at%s\aw (ID: %d)', name, newID)
    else
        state.combat.aggroTargetID = ''
        printf('\awCleared combat target — will pick up next hater on tick')
    end
end

local function onTargetMode()
    state.combat.manualTargetMode = not state.combat.manualTargetMode
    _config.set('Melee', 'ManualTargetMode', state.combat.manualTargetMode and '1' or '0')
    _config.save()
    printf('\aw/katargetmode: Manual Target Mode is \at%s',
           state.combat.manualTargetMode and 'ON' or 'OFF')
end

local function onKissCast(castWhat, whatID, _forceInterrupt)
    if not castWhat or castWhat == '' then
        printf('\ay/kisscast <spellname>')
        return
    end
    _cast.castWhat(castWhat, tonumber(whatID) or 0, 'KissCast')
end

local function onPetOn()
    state.pet.on = true
    _config.set('Pet', 'PetOn', '1')
    _config.save()
    printf('\ayPet system \agON')
end

local function onPetOff()
    state.pet.on = false
    _config.set('Pet', 'PetOn', '0')
    _config.save()
    printf('\ayPet system \arOFF')
end

local function onMountOn()
    state.misc.mountOn = true
    _config.set('General', 'MountOn', '1')
    _config.save()
    printf('\ayMount system \agON')
end

local function onMountOff()
    state.misc.mountOn = false
    _config.set('General', 'MountOn', '0')
    _config.save()
    printf('\ayMount system \arOFF')
end

local function onAutoFireOn()
    local cur = state.combat.autoFireOn or 0
    state.combat.autoFireOn = cur == 0 and 1 or 0
    _config.set('Melee', 'AutoFireOn', tostring(state.combat.autoFireOn))
    _config.save()
    printf('\ayAutoFireOn \ag%d', state.combat.autoFireOn)
end

-- ─── /togglevariable and /changevarint ───────────────────────────────────────
-- Both take the mac's variable names (ChaseAssist, MeleeOn, ...), so aliases left
-- over from kissassist.mac (/chase, /meleeon, /assistat, ...) keep working.

-- State sub-tables searched for a variable, in order.
local VAR_TABLES = {
    'session', 'combat', 'cast', 'pull', 'movement', 'heal', 'buffs', 'pet',
    'loot', 'dps', 'misc', 'bard', 'mez', 'afk', 'merc', 'charm', 'debuff', 'cond',
}

-- Mac names the port spells differently (lowercase mac name -> table, field).
-- Everything else is found by a case-insensitive field search.
local MAC_VAR_NAMES = {
    peton      = { 'pet', 'on' },     pettoyson   = { 'pet', 'toysOn' },
    pethold    = { 'pet', 'holdOn' }, petcombaton = { 'pet', 'combatOn' },
    looton     = { 'loot', 'on' },    afktoolson  = { 'afk', 'on' },
    mezon      = { 'mez', 'on' },     conon       = { 'cond', 'on' },
    charmon    = { 'charm', 'on' },   mercon      = { 'merc', 'on' },
    debuffon   = { 'debuff', 'on' },  pullhold    = { 'pull', 'hold' },
    dpspaused  = { 'dps', 'paused' },
    -- session.assistAt is only the command-line value; combat uses this one
    assistat   = { 'combat', 'assistAt' },
}

-- Mac variables that have no counterpart in the port.
local UNSUPPORTED_VARS = {
    dpsmeter = true, dpsspam = true, dpswriteon = true, movewhenhit = true,
}

-- Find a variable by its mac or port name. Returns table, field (or nil).
local function findVar(name)
    local lname = name:lower()
    local alias = MAC_VAR_NAMES[lname]
    if alias and state[alias[1]] then return state[alias[1]], alias[2] end
    for _, sub in ipairs(VAR_TABLES) do
        local t = state[sub]
        if t then
            if t[name] ~= nil then return t, name end
            for k in pairs(t) do
                if type(k) == 'string' and k:lower() == lname then return t, k end
            end
        end
    end
end

-- Convert a value to the field's type. on/1 = on, off/0/empty = off, another
-- number is used as is (mac:8378-8406). Returns the new value and on/off.
local function convertValue(cur, field, arg)
    local a   = tostring(arg or ''):match('^%s*(.-)%s*$')
    local la  = a:lower()
    local num = tonumber(a)
    local on
    if la == 'on' then on = true
    elseif la == 'off' or la == '' or la == 'null' then on = false
    elseif num then on = num > 0
    else on = true end
    if type(cur) == 'boolean' then return on, on end
    if type(cur) == 'number' then
        if num then return num, num > 0 end
        if not on then return 0, false end
        return field == 'castingInterruptOn' and 62 or 1, true  -- 62 = the mac's "all" bitmask
    end
    if on and a ~= '' and la ~= 'on' then return a, true end
    return on and '1' or '0', on
end

local function stickOff()
    if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
end

-- Side effects of turning a variable on/off (mac Bind_ToggleVariable 8406-8470,
-- Bind_ChangeVarInt 11256-11335). persist: also write the change to the INI.
local function varSideEffects(field, on, whoToChase, persist)
    local mv = state.movement
    if field == 'chaseAssist' then
        if on then
            if whoToChase and whoToChase ~= '' and whoToChase ~= 'null'
               and whoToChase ~= mv.whoToChase then
                mv.whoToChase = whoToChase
                printf('\ayI Will Now Chase %s', whoToChase)
            end
            if mv.returnToCamp then
                mv.returnToCamp = false
                if persist then _config.set('General', 'ReturnToCamp', '0') end
            end
            if (mq.TLO.Me.Pet.ID() or 0) > 0 and (mq.TLO.Me.Pet.Stance() or ''):upper() ~= 'FOLLOW' then
                mq.cmd('/pet follow')
            end
        else
            stickOff()
        end
    elseif field == 'returnToCamp' and on then
        -- New camp right here (mac:8417-8432)
        mv.campX, mv.campY, mv.campZ = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.FloorZ()
        mv.lookForward  = mq.TLO.Me.Heading.DegreesCCW() or 0
        mv.campZone     = mq.TLO.Zone.ID()
        mv.campZoneName = mq.TLO.Zone.ShortName() or ''
        state.pull.mapSet = false
        if state.session.chaseAssist then
            state.session.chaseAssist = false
            _config.set('General', 'ChaseAssist', '0')  -- the mac saves this one (mac:8425)
            _config.save()
            stickOff()
            printf('\ay>> ChaseAssist Off')
        end
        printf('\ay>> New camp set %.1f, %.1f', mv.campY or 0, mv.campX or 0)
    elseif field == 'autoRezAll' then
        if on then printf('\ayNow Rezing Everyone.')
        else
            state.heal.corpseRezCheck = 'null'
            printf('\ayNo longer Rezing Everyone.')
        end
    elseif field == 'targetSwitchingOn' and on and not state.session.iAmMA then
        state.combat.targetSwitchingOn = false  -- MA only (mac:8460)
    elseif field == 'maxRadius' then
        mv.campRadiusExceed = (state.pull.maxRadius or 0) + 200  -- mac:11277
    elseif field == 'xTarHeal' then
        if (state.heal.healsOn or 0) == 0 then
            state.heal.xTarHeal = 0
            printf('\ayTurn on Heals first. Setting XTarget Healing OFF!')  -- mac:11313
        else
            require('modules.healing').setXTargetHealList(state.heal.xTarHealList)
        end
    end
end

-- /togglevariable <name> [on|off|1|0|value] [who]. Port of Bind_ToggleVariable
-- (mac:8371). As in the mac, no value turns it off. Not saved to the INI.
-- 'waithere' stops chasing and returning to camp.
local function onToggleVariable(varName, val, extra)
    if not varName or varName == '' then
        printf('\ay/togglevariable <name> [on|off|value]')
        return
    end
    if varName:lower() == 'waithere' then  -- mac:8473-8477
        state.session.chaseAssist   = false
        state.movement.returnToCamp = false
        stickOff()
        return
    end
    if UNSUPPORTED_VARS[varName:lower()] then
        printf('\ay%s is not supported in the Lua port.', varName)
        return
    end
    local tbl, field = findVar(varName)
    if not tbl then
        printf('\ay/togglevariable: unknown variable \at%s', varName)
        return
    end
    local value, on = convertValue(tbl[field], field, val)
    tbl[field] = value
    varSideEffects(field, on, extra, false)
    printf('\ay>> Setting: (%s) to (%s) (%s)', varName, on and 'On' or 'Off', tostring(tbl[field]))
end

-- /changevarint <Section> <Name> <value>: set a variable and save it to the INI.
-- Port of Bind_ChangeVarInt (mac:11237). The older '/changevarint <name> <value>'
-- form still works, without saving.
local function onChangeVarInt(a1, a2, a3)
    local section, name, value
    if a3 and a3 ~= '' then
        section, name, value = a1, a2, a3
    else
        name, value = a1, a2
    end
    if not name or name == '' or not value or value == '' then
        printf('\ay/changevarint <Section> <Name> <value>')
        return
    end
    local tbl, field = findVar(name)
    if not tbl then
        printf('\ay/changevarint: unknown variable \at%s', name)
        return
    end
    local old = tbl[field]
    local newValue, on = convertValue(old, field, value)
    tbl[field] = newValue
    printf('\ayChanging %s from %s to %s', name, tostring(old), tostring(newValue))
    if section then
        _config.set(section, name, tostring(value))
    end
    varSideEffects(field, on, nil, section ~= nil)
    if section then _config.save() end
end

-- ─── Movement / camp ──────────────────────────────────────────────────────────

local function onMakeCampHere()
    state.movement.campX        = mq.TLO.Me.X()
    state.movement.campY        = mq.TLO.Me.Y()
    state.movement.campZ        = mq.TLO.Me.FloorZ()
    state.movement.campZone     = mq.TLO.Zone.ID()
    state.movement.campZoneName = mq.TLO.Zone.ShortName() or ''
    state.movement.lookForward  = mq.TLO.Me.Heading.DegreesCCW() or 0  -- mac:8424
    state.movement.returnToCamp = true
    state.session.chaseAssist   = false
    state.pull.mapSet           = false  -- repaint the map circles around the new camp
    printf('\ay>> Camp set at %.1f, %.1f', state.movement.campY, state.movement.campX)
    if _comms then
        _comms.broadcast('CAMP', {
            x        = state.movement.campX,
            y        = state.movement.campY,
            z        = state.movement.campZ,
            zone     = state.movement.campZone,
            zoneName = state.movement.campZoneName,
        })
    end
end

local function onStayHere()
    state.movement.campX        = mq.TLO.Me.X()
    state.movement.campY        = mq.TLO.Me.Y()
    state.movement.campZ        = mq.TLO.Me.FloorZ()
    state.movement.campZone     = mq.TLO.Zone.ID()
    state.movement.campZoneName = mq.TLO.Zone.ShortName() or ''
    state.movement.lookForward  = mq.TLO.Me.Heading.DegreesCCW() or 0
    state.movement.returnToCamp = true
    state.session.chaseAssist   = false
    printf('\ay>> StayHere — camp set at %.1f, %.1f', state.movement.campY, state.movement.campX)
    if _comms then _comms.broadcast('STAY', {}) end
end

local function onCampOff()
    state.movement.returnToCamp = false
    state.movement.campX        = 0
    state.movement.campY        = 0
    state.movement.campZ        = 0
    state.movement.campZoneName = ''
    printf('\ay>> Camp mode off.')
end

local function onChaseMe()
    local myName = mq.TLO.Me.CleanName() or ''
    state.movement.whoToChase  = myName
    state.session.chaseAssist  = true
    printf('\ay>> ChaseMe %s', myName)
    if _comms then _comms.broadcast('CHASE', { who = myName }) end
end

-- Mirrors Bind_TrackMeDown (kissassist.mac). Sets chase target; no arg toggles off.
local function onTrackMeDown(name, _useNavOnly, _ignoreDist)
    if not name or name == '' then
        state.session.chaseAssist  = false
        state.movement.whoToChase  = ''
        printf('\ayChase assist disabled.')
    else
        state.movement.whoToChase  = name
        state.session.chaseAssist  = true
        printf('\ayChasing: \at%s', name)
    end
end

local PULL_DIRS = { n = 0, ne = 45, e = 90, se = 135, s = 180, sw = 225, w = 270, nw = 315 }

-- Mirrors Bind_SetPullArc (mac:14461): /setpullarc <width> [degrees|n|ne|e|se|s|sw|w|nw].
-- No direction = the way you are facing. Width 0 turns directional pulling off.
local function onSetPullArc(width, fdir)
    local w = tonumber(width) or 0
    local function save()
        -- Save to the pickle config (the .ini was renamed to .bak at migration)
        _config.set('Pull', 'PullArcWidth', tostring(state.pull.pullArcWidth))
        _config.save()
    end
    if w <= 0 or w > 359 then
        if state.pull.pullArcWidth > 0 then printf('\ayTurning off Directional Pulling.') end
        state.pull.pullArcWidth = 0
        require('modules.pull').clearArc()
        save()
        return
    end
    local facing
    if not fdir or fdir == '' then
        facing = mq.TLO.Me.Heading.Degrees() or 0
    elseif tonumber(fdir) then
        facing = tonumber(fdir) % 360
    else
        facing = PULL_DIRS[fdir:lower()]
        if not facing then
            printf('\arInvalid Direction. Turning off Directional Pulling.')
            state.pull.pullArcWidth = 0
            require('modules.pull').clearArc()
            save()
            return
        end
    end
    state.pull.pullArcWidth = w
    require('modules.pull').setPullAngles(facing, w)
    save()
end

-- Mirrors Bind_SetPullRanking (kissassist.mac:15019). Pull ranking pulls the
-- MobsToPull entries marked with ':' first. Per session; not saved.
local PULL_RANK_ROLES = { puller = true, pullertank = true, pullerpettank = true,
                          hunter = true, hunterpettank = true }
local function onSetPullRanking(flag)
    if not PULL_RANK_ROLES[state.session.role] then
        printf('\ayInvalid current Role to use Pull Ranking. Setting Pull Ranking OFF!')
        require('modules.pull').setRanking(false, true)
        return
    end
    flag = (flag or ''):lower()
    local on
    if flag == 'on' or flag == '1' then
        on = true
    elseif flag == 'off' or flag == '0' then
        on = false
    else
        printf('\ayInvalid SetPullRanking argument. Must be one of the following: on, off, 1, or 0.')
        return
    end
    if on == state.pull.ranking then
        printf('\ayPull Ranking is %s.', on and 'on' or 'off')
        return
    end
    require('modules.pull').setRanking(on)
end

-- ─── Buffs / group ────────────────────────────────────────────────────────────

local function onBuffGroup(_flag)
    state.buffs.forceBuffs = true
    state.timers.readBuffs = 0  -- mac:11734
    state.timers.iniNext   = 0
    _buffs.checkBuffs(true)
end

local function onCampfire()
    state.misc.campfireOn = true
    mq.cmd('/usefinditem Fellowship Campfire')
    printf('\ay>> Campfire placed at %.1f, %.1f', state.movement.campY, state.movement.campX)
end

-- Mirrors Bind_TooBuffList (kissassist.mac:16086). The "too buff" list holds the
-- names of characters outside the group to also buff, '|'-terminated
-- ("Name1|Name2|"). Runtime only; the mac never saves it to the INI.
local function onTbManager(action, actionID)
    local a    = (action or ''):lower()
    local list = state.buffs.extendedList or ''
    if a ~= 'add' and a ~= 'remove' and a ~= 'reset' and a ~= 'clear' then
        printf('\ayInvalid Action for Too Buff List, please use add, remove, reset or clear.')
        return
    end

    local workID = tonumber(actionID) or 0
    if workID == 0 then workID = mq.TLO.Target.ID() or 0 end
    local workName = workID ~= 0 and (mq.TLO.Spawn('id ' .. workID).CleanName() or '') or ''
    if (a == 'add' or a == 'remove') and workName == '' then
        printf('\ayInvalid ID. Please target a Character or use a proper ID.')
        return
    end

    if a == 'reset' then
        -- Drop names that are no longer in the zone
        local kept = {}
        for name in list:gmatch('([^|]+)|') do
            if (mq.TLO.Spawn('=' .. name).ID() or 0) ~= 0 then
                kept[#kept + 1] = name .. '|'
            else
                printf('\ayRemoved %s from the Too Buff List.', name)
            end
        end
        list = table.concat(kept)
    elseif a == 'clear' then
        list = ''
        printf('\ayToo Buff List Cleared.')
    elseif a == 'remove' then
        if list:find(workName .. '|', 1, true) then
            list = list:gsub(workName:gsub('%p', '%%%0') .. '|', '', 1)
            printf('\ayRemoved %s from Too Buff List.', workName)
        else
            printf('\ay%s Not Found on the Too Buff List.', workName)
        end
    else -- add
        local count = select(2, list:gsub('|', ''))
        if count > 49 then
            printf('\ayThere is a limit of 50 names. Please remove some before trying to add more.')
            return
        end
        if list:find(workName .. '|', 1, true) then
            printf('\ay%s Found on Too Buff List. No Need to add again.', workName)
            return
        end
        list = list .. workName .. '|'
        printf('\ayAdded %s to the Too Buff List.', workName)
    end

    state.buffs.extendedList       = list
    state.buffs.globalExtendedList = list  -- mac g_ExtendedBuffList
end

-- ─── Pull management ──────────────────────────────────────────────────────────

-- Mirrors Bind_AddToPull (kissassist.mac:8315). Appends name to zone-scoped MobsToPull
-- in KissAssist_Info.ini (shared across all characters in the zone), comma-delimited.
local function onAddPull(name)
    if not name or name == '' then
        name = mq.TLO.Target.CleanName() or ''
        if name == '' then
            printf('\ay/addpull [mobname] — no argument and no target')
            return
        end
    end
    local iniFile = state.session.infoFileName
    local zone    = state.session.zoneName
    if not iniFile or iniFile == '' or not zone or zone == '' then
        printf('\ay/addpull: zone not available yet')
        return
    end
    local existing = Utils.zoneIniGet(iniFile, zone, 'MobsToPull') or ''
    local lname = name:lower()
    for entry in (existing .. ','):gmatch('([^,]+),') do
        if entry:match('^%s*(.-)%s*$'):gsub(':', ''):lower() == lname then
            printf('\ay%s is already on the pull list.', name)
            return
        end
    end
    local updated = (existing == '' or existing == 'all' or existing == 'null')
        and name or (existing .. ',' .. name)
    state.pull.mobsToPullRaw = updated
    require('modules.pull').setRanking(state.pull.ranking, true)
    mq.cmdf('/ini "%s" "%s" "MobsToPull" "%s"', iniFile, zone, updated)
    printf('\ayAdded \at%s\ay to pull list.', name)
end

-- Mirrors Bind_AddToIgnore (kissassist.mac:8266). Appends name to zone-scoped MobsToIgnore
-- in KissAssist_Info.ini (shared across all characters in the zone), comma-delimited.
-- '/addignore <id> 1' instead ignores that one spawn ID for this session (mac:8303-8310).
local function onAddIgnore(name, byID)
    if tonumber(byID) == 1 then
        local id = math.floor(tonumber(name) or 0)
        local sp = mq.TLO.Spawn('id ' .. id)
        if id <= 0 or (sp.Type() or ''):upper() ~= 'NPC' then
            printf('\ayNo NPCs with ID: (%s) detected. Nothing added to list.', tostring(name))
            return
        end
        local list = state.pull.mobsToIgnoreByID or 'null'
        if list == 'null' or list == '' then list = '|' end
        if not list:find('|' .. id .. '|', 1, true) then
            state.pull.mobsToIgnoreByID = list .. id .. '|'
            printf('\ayIgnoring \at%s\ay (ID %d) for this session.', sp.CleanName() or '?', id)
        end
        return
    end
    if not name or name == '' then
        name = mq.TLO.Target.CleanName() or ''
        if name == '' then
            printf('\ay/addignore [mobname] — no argument and no target')
            return
        end
    end
    local iniFile = state.session.infoFileName
    local zone    = state.session.zoneName
    if not iniFile or iniFile == '' or not zone or zone == '' then
        printf('\ay/addignore: zone not available yet')
        return
    end
    local existing = Utils.zoneIniGet(iniFile, zone, 'MobsToIgnore') or ''
    local lname = name:lower()
    for entry in (existing .. ','):gmatch('([^,]+),') do
        if entry:match('^%s*(.-)%s*$'):lower() == lname then
            printf('\ay%s is already on the ignore list.', name)
            return
        end
    end
    local updated = (existing == '' or existing == 'null')
        and name or (existing .. ',' .. name)
    state.pull.mobsToIgnore = updated
    mq.cmdf('/ini "%s" "%s" "MobsToIgnore" "%s"', iniFile, zone, updated)
    printf('\ayAdded \at%s\ay to ignore list.', name)
end

-- Mirrors Sub Bind_AddMezImmune (kissassist.mac:8226).
-- Adds current target (or named mob) to the mez-immune ID list at runtime
-- and to the persistent MezImmune name list in InfoFileName INI.
local function onAddMezImmune(_mti)
    local tID   = mq.TLO.Target.ID() or 0
    local tType = (mq.TLO.Target.Type() or ''):lower()
    if tID == 0 or tType ~= 'npc' then
        printf('--AddMezImmune: Target an NPC to add to the mez immune list.')
        return
    end
    local name = mq.TLO.Target.CleanName() or ''
    -- Strip named-mob '#' prefix
    if name:sub(1, 1) == '#' then name = name:sub(2) end
    -- Strip corpse suffix
    name = name:match("^(.+)'s corpse$") or name:match("^(.+) corpse$") or name
    if name == '' then
        printf('--AddMezImmune: Could not resolve mob name for target.')
        return
    end
    local sID = tostring(tID)
    local ids = state.mez.immuneIDs or ''
    if ids:find('|' .. sID, 1, true) then
        printf('>> %s (ID:%d) is already on the mez immune list.', name, tID)
        return
    end
    state.mez.immuneIDs = ids .. '|' .. sID
    -- Persist name to InfoFileName INI under the current zone key
    local iniFile = state.session.infoFileName
    local zone    = state.session.zoneName
    if iniFile and iniFile ~= '' and zone and zone ~= '' then
        local existing = Utils.zoneIniGet(iniFile, zone, 'MezImmune') or ''
        if not existing:find(name, 1, true) then
            local updated = (existing == '' or existing == 'null') and name or (existing .. ',' .. name)
            mq.cmdf('/ini "%s" "%s" "MezImmune" "%s"', iniFile, zone, updated)
        end
    end
    printf('\ay>> Mez Immune -> %s <- ID:%d Added to immune list.', name, tID)
end

-- Charm binds — mirrors /charmon, /charmkeep, /setcharmed, /resetcharmed, /addcimmune
-- (kisscharm.mac alias block).

local function onCharmOn()
    if not state.session.iAmACharmClass then
        printf('--CharmOn: not a charm class (DRU/ENC/NEC/BRD).')
        return
    end
    state.charm.on = not state.charm.on
    printf('\ay>> CharmOn = %s', tostring(state.charm.on))
end

local function onCharmKeep()
    if not state.session.iAmACharmClass then
        printf('--CharmKeep: not a charm class (DRU/ENC/NEC/BRD).')
        return
    end
    state.charm.keep = not state.charm.keep
    printf('\ay>> CharmKeep = %s', tostring(state.charm.keep))
end

local function onSetCharmed()
    local petID = mq.TLO.Me.Pet.ID() or 0
    if petID == 0 then
        printf('--SetCharmed: no active pet to record.')
        return
    end
    state.charm.petId   = petID
    state.charm.petZone = mq.TLO.Zone.ShortName() or ''
    printf('\ay>> CharmPet set: ID:%d zone:%s', petID, state.charm.petZone)
end

local function onResetCharmed()
    state.charm.petId   = 0
    state.charm.petZone = ''
    printf('\ay>> CharmPet reset.')
end

-- Mirrors /addcimmune — adds current target to the runtime charm-immune ID list
-- and optionally persists the name to KissAssist_Info.ini (when AACharmImmune=1).
local function onAddCharmImmune()
    local tID   = mq.TLO.Target.ID() or 0
    local tType = (mq.TLO.Target.Type() or ''):lower()
    if tID == 0 or tType ~= 'npc' then
        printf('--AddCharmImmune: Target an NPC to add to the charm immune list.')
        return
    end
    local name = mq.TLO.Target.CleanName() or ''
    if name:sub(1, 1) == '#' then name = name:sub(2) end
    name = name:match("^(.+)'s corpse$") or name:match("^(.+) corpse$") or name
    local tag = '|' .. tostring(tID)
    if state.charm.immuneIds:find(tag, 1, true) then
        printf('>> %s (ID:%d) is already on the charm immune list.', name, tID)
        return
    end
    state.charm.immuneIds = state.charm.immuneIds .. tag
    if state.charm.aaImmune and name ~= '' then
        local iniFile = state.session.infoFileName
        local zone    = state.session.zoneName
        if iniFile and iniFile ~= '' and zone and zone ~= '' then
            local existing = Utils.zoneIniGet(iniFile, zone, 'CharmImmune') or ''
            if not existing:find(name, 1, true) then
                local updated = (existing == '' or existing:lower() == 'null')
                                and name or (existing .. ',' .. name)
                mq.cmdf('/ini "%s" "%s" "CharmImmune" "%s"', iniFile, zone, updated)
                state.charm.immuneList = updated
            end
        end
    end
    printf('\ay>> Charm Immune -> %s <- ID:%d added.', name, tID)
end

-- Add current target (or named arg) to zone-scoped MobsToBurn list in KissAssist_Info.ini.
-- Updates state.combat.namedWatchList at runtime so the change takes effect immediately.
local function onAddBurn(name)
    if not name or name == '' then
        name = mq.TLO.Target.CleanName() or ''
        if name == '' then
            printf('\ay/addburn [mobname] — no argument and no target')
            return
        end
    end
    local iniFile = state.session.infoFileName
    local zone    = state.session.zoneName
    if not iniFile or iniFile == '' or not zone or zone == '' then
        printf('\ay/addburn: zone not available yet')
        return
    end
    local existing = Utils.zoneIniGet(iniFile, zone, 'MobsToBurn') or ''
    local lname = name:lower()
    for entry in (existing .. ','):gmatch('([^,]+),') do
        if entry:match('^%s*(.-)%s*$'):lower() == lname then
            printf('\ay%s is already on the burn list.', name)
            return
        end
    end
    local updated = (existing == '' or existing == 'null')
        and name or (existing .. ',' .. name)
    state.combat.namedWatchList[#state.combat.namedWatchList + 1] = lname
    mq.cmdf('/ini "%s" "%s" "MobsToBurn" "%s"', iniFile, zone, updated)
    printf('\ayAdded \at%s\ay to burn list.', name)
end

-- ─── Info display ─────────────────────────────────────────────────────────────

local function onZoneInfo()
    printf('-------------------------------------------------------------------------')
    printf('%s - (%s)', mq.TLO.Zone.Name() or '', mq.TLO.Zone.ShortName() or '')
    printf('-------------------------------------------------------------------------')
    printf('MobsToPullRaw:   %s', state.pull.mobsToPullRaw)
    printf('MobsToPullFirst: %s', state.pull.mobsToPullFirst)
    printf('MobsToPull:      %s', state.pull.mobsToPull)
    printf('Pull Ranking:    %s', state.pull.ranking and 'on' or 'off')
    local infoFile = state.session.infoFileName or ''
    local zone     = state.session.zoneName     or ''
    local burnList = (infoFile ~= '' and zone ~= '')
        and (mq.TLO.Ini(infoFile, zone, 'MobsToBurn')() or 'null') or 'null'
    printf('MobsToBurn:      %s', burnList)
    printf('-------------------------------------------------------------------------')
end

local function onAggroInfo()
    printf('-------------------------------------------------------------------------')
    printf('XTarget Entry Information:')
    printf('    Index(s): %d : %d', state.combat.xTSlot, state.combat.xTSlot2)
    local xt = mq.TLO.Me.XTarget(state.combat.xTSlot)
    if xt and xt.ID() and xt.ID() > 0 then
        printf('    Target Info: %d - %s', xt.ID(), xt.Name())
    else
        printf('    No Target Info. XTarget entry %d is empty.', state.combat.xTSlot)
    end
    printf('-------------------------------------------------------------------------')
    printf('Main Assist and Group Information:')
    printf('    I am MA: %s  MA: %s  My ID: %d',
        tostring(state.session.iAmMA), state.session.mainAssist, mq.TLO.Me.ID())
    printf('    Group MA ID: %s  My Target ID: %d',
        tostring(mq.TLO.Group.MainAssist.ID()), state.combat.myTargetID)
    printf('-------------------------------------------------------------------------')
end

-- ─── Misc / admin ─────────────────────────────────────────────────────────────

local function onAddFriend()
    local tID   = mq.TLO.Target.ID() or 0
    local tType = (mq.TLO.Target.Type() or ''):lower()
    if tID == 0 or tType ~= 'pc' or tID == mq.TLO.Me.ID() then
        printf('--ADDFRIEND: Target a PC to add to your Posse list.')
        return
    end
    local name = mq.TLO.Target.CleanName()
    mq.cmd('/posse add ' .. name)
    mq.cmd('/posse save')
    mq.cmd('/posse load')
    printf('>> Added %s to Posse list.', name)
end

-- /kisscheck [sections]: config summary, then the mac's INI spell-name check
-- (Bind_KissCheck -> ScanIni, mac:11464). Sections default to all.
local function onKissCheck(...)
    printf('----------- KissAssist Config Check -----------')
    printf('Role: \at%-12s\aw  MA: \at%-20s\aw  AssistAt: \at%d%%',
        state.session.role, state.session.mainAssist, state.session.assistAt)
    printf('IAmMA: \at%-5s\aw  IAmBard: \at%s',
        tostring(state.session.iAmMA), tostring(state.session.iAmABard))
    printf('HealsOn: \at%-2s\aw  CuresOn: \at%-2s\aw  BuffsOn: \at%s',
        tostring(state.heal.healsOn), tostring(state.heal.curesOn), tostring(state.buffs.buffsOn))
    printf('DPSOn:   \at%-5s\aw  MeleeOn: \at%s',
        tostring(state.combat.dpsOn), tostring(state.combat.meleeOn))
    printf('PetOn:   \at%-5s\aw  LootOn:  \at%s',
        tostring(state.pet.on), tostring(state.loot.on))
    printf('Camp: \at%.1f, %.1f\aw  ReturnToCamp: \at%s',
        state.movement.campY, state.movement.campX, tostring(state.movement.returnToCamp))
    printf('Chase: \at%-5s\aw  ChaseTarget: \at%s',
        tostring(state.session.chaseAssist), state.movement.whoToChase)
    printf('INI: \at%s', state.session.iniFileName)
    printf('-----------------------------------------------')
    _config.scanIni(table.concat({ ... }, '|'))
end

-- The mac's /kasettings was a chat-menu settings editor; the KissAssist window
-- replaces it, so this just opens the window (/kaui toggles it).
local function onKaSettings(_cmd1, _cmd2, _skipIni)
    require('modules.ui').show()
    printf('\ay>> Settings are in the KissAssist window (/kaui to toggle it).')
end

local function onWriteSpells(_quiet)
    _config.writeSpells(state)
    if not _quiet then printf('\aySpell set written to config.') end
end

-- Mirrors Bind_MemMySpells (kissassist.mac:14131-14232).
-- Reads Gem1..GemN from [Spells] (or [Spells{set}]) in the character INI and
-- mems each spell into the corresponding gem slot.
local function onMemMySpells(_charName, p_spellSet)
    local gemSlots    = state.cast.gemSlots or 8

    -- Gem list for a config section: the migrated [Spells] Gems array (what
    -- /writespells and the UI write), or Gem1..GemN keys for other sections.
    -- Returns nil when the section has no gems.
    local function gemsFor(section)
        local gems = _config.get(section, 'Gems', nil)
        if type(gems) ~= 'table' then
            gems = {}
            for i = 1, gemSlots do gems[i] = _config.get(section, 'Gem' .. i, nil) end
        end
        for i = 1, gemSlots do
            local g = gems[i]
            if g and g ~= '' and g ~= 'null' then return gems end
        end
        return nil
    end

    -- Determine spell section (Spells or SpellsN for alternate sets)
    local spellSection = (p_spellSet and p_spellSet ~= '' and p_spellSet ~= 'null')
                         and ('Spells' .. p_spellSet) or 'Spells'

    -- Read from the pickle config; the character .ini is renamed to .bak at migration
    local gemList = gemsFor(spellSection)
    if not gemList then
        if spellSection ~= 'Spells' then
            printf('\aw No Spells Section found for: %s. Defaulting to Spells Section.', spellSection)
            gemList = gemsFor('Spells')
        end
        if not gemList then
            printf('\aw No Spells found in your config. Use /writespells and try again.')
            return
        end
    end

    -- Bard twist-pause stub → M8

    local wasStanding = mq.TLO.Me.Standing()

    for i = 1, gemSlots do
        local spellToMem = gemList[i] or ''
        if spellToMem ~= '' and spellToMem ~= 'null' then
            -- Strip " Rk. X" rank suffix before resolving to current rank
            local baseName = spellToMem
            local rkPos = spellToMem:find(' Rk%.', 1, false)
            if rkPos then baseName = spellToMem:sub(1, rkPos - 1) end
            -- Resolve to the character's current known rank
            spellToMem = mq.TLO.Spell(baseName).RankName() or spellToMem

            if mq.TLO.Me.Book(spellToMem)() then
                -- Unmem from wrong slot first
                local curGem = mq.TLO.Me.Gem(spellToMem)() or 0
                if curGem > 0 and curGem ~= i then
                    mq.cmdf('/notify CastSpellWnd CSPW_Spell%d rightmouseup', curGem - 1)
                    local t = os.clock() + 2.0
                    while os.clock() < t and (mq.TLO.Me.Gem(spellToMem)() or 0) ~= 0 do
                        mq.delay(100)
                    end
                end
                -- Mem only if slot doesn't already have this spell
                if (mq.TLO.Me.Gem(i).Name() or '') ~= spellToMem then
                    local prevDontMove = state.movement.dontMoveMe
                    state.movement.dontMoveMe = true
                    while mq.TLO.Me.Moving() do mq.delay(100) end
                    if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Standing() then
                        mq.cmd('/sit')
                    end
                    printf('\aw Meming %s in slot %d', spellToMem, i)
                    local stickActive = mq.TLO.Stick.Active()
                    if stickActive then mq.cmd('/stick pause') end
                    mq.cmdf('/memspell %d "%s"', i, spellToMem)
                    local timeout = os.clock() + 15.0
                    while os.clock() < timeout do
                        mq.delay(100)
                        if (mq.TLO.Me.Gem(i).Name() or '') == spellToMem then break end
                    end
                    if stickActive then mq.cmd('/stick unpause') end
                    state.movement.dontMoveMe = prevDontMove
                end
            else
                printf('\aw Could Not find the spell %s in your spell book.', baseName)
            end
        end
    end

    -- Refresh misc gem snapshots after memming
    if state.cast.miscGem > 0 then
        state.cast.reMemMiscSpell = mq.TLO.Me.Gem(state.cast.miscGem).Name() or ''
    end
    if state.cast.miscGemLW > 0 then
        state.cast.reMemMiscSpellLW = mq.TLO.Me.Gem(state.cast.miscGemLW).Name() or ''
    end

    -- Bard cleanup stub → M8
    if wasStanding and mq.TLO.Me.Sitting() and not mq.TLO.Me.Mount.ID() then
        mq.cmd('/stand')
    end
end

local function onIniWrite()
    _config.save()
    printf('\ayConfig flushed to pickle.')
end

local function onParse(expr, p2, p3, p4, p5, p6, p7, p8)
    local parts = {}
    for _, v in ipairs({expr, p2, p3, p4, p5, p6, p7, p8}) do
        if v and v ~= '' then parts[#parts+1] = v end
    end
    local exprStr = table.concat(parts, ' ')
    if exprStr == '' then
        printf('\ay/parse <expression>')
        return
    end
    local result = mq.parse('${' .. exprStr .. '}')
    printf('\ay%s\aw = \ag%s', exprStr, tostring(result))
end

local function onMyCmds(cmd, p1, p2, p3)
    local myCmd = state.misc.myCmd or ''
    if cmd and cmd ~= '' then
        local parts = {cmd}
        for _, v in ipairs({p1, p2, p3}) do
            if v and v ~= '' then parts[#parts+1] = v end
        end
        myCmd = table.concat(parts, ' ')
    end
    if myCmd == '' then
        printf('\ay/mycmd: no command set (configure General.MyCmd in config)')
        return
    end
    mq.cmd(myCmd)
end

-- ─── Integration test runner ──────────────────────────────────────────────────

local INTEGRATION_TESTS = { 'debug_cmds', 'toggle_cmds', 'camp_cmds', 'switchma', 'charm_cmds', 'switchtarget' }

local function onKaTest(testName)
    if not testName or testName == '' then
        printf('\ay/katest <debug_cmds|toggle_cmds|camp_cmds|switchma|charm_cmds|switchtarget|all>')
        return
    end
    local names = testName:lower() == 'all' and INTEGRATION_TESTS or { testName }
    -- Single shared TH across all suites so the final summary covers everything.
    package.loaded['tests.test_helpers'] = nil
    local TH = require('tests.test_helpers')
    for _, name in ipairs(names) do
        local path = 'tests.integration.test_' .. name
        package.loaded[path] = nil
        local ok, err = pcall(function()
            require(path).run(mq, state, TH)
        end)
        if not ok then
            printf('\ar[ERROR]\ax /katest %s: %s', name, tostring(err))
        end
    end
    TH.printSummary()
end

-- ─── Registration ─────────────────────────────────────────────────────────────

function Binds.register(s, b, cast, combat, config, comms)
    state   = s
    _buffs  = b
    _cast   = cast
    _combat = combat
    _config = config
    _comms  = comms

    -- Debug / utility
    if mq.TLO.Alias('/debug')() then mq.cmd('/alias /debug delete') end
    bind('/debug',          onDebug)
    bind('/parse',          onParse)
    bind('/zoneinfo',       onZoneInfo)
    bind('/aggroinfo',      onAggroInfo)
    bind('/iniwrite',       onIniWrite)
    bind('/writespells',    onWriteSpells)
    bind('/memmyspells',    onMemMySpells)
    bind('/mycmd',          onMyCmds)

    bind('/kisscheck',      onKissCheck)
    bind('/kasettings',     onKaSettings)
    bind('/katest',         onKaTest)
    bind('/togglevariable', onToggleVariable)
    bind('/changevarint',   onChangeVarInt)

    -- Combat
    bind('/burn',              onBurn)
    bind('/backoff',           onBackOff)
    bind('/switchnow',         onSwitch)
    bind('/kaswitchtarget',    onSwitchTarget)
    bind('/katargetmode',      onTargetMode)
    if mq.TLO.Alias('/switchma')() then mq.cmd('/alias /switchma delete') end
    bind('/switchma',          onSwitchMA)
    bind('/kisscast',       onKissCast)
    if mq.TLO.Alias('/peton')()  then mq.cmd('/alias /peton delete')  end
    if mq.TLO.Alias('/petoff')() then mq.cmd('/alias /petoff delete') end
    bind('/peton',          onPetOn)
    bind('/petoff',         onPetOff)
    bind('/mounton',        onMountOn)
    bind('/mountoff',       onMountOff)
    if mq.TLO.Alias('/autofireon')() then mq.cmd('/alias /autofireon delete') end
    bind('/autofireon',     onAutoFireOn)
    bind('/kainterrupton',  function()
        local v = (state.cast.castingInterruptOn or 0) == 0 and 62 or 0
        state.cast.castingInterruptOn = v
        _config.set('Spells', 'CastingInterruptOn', tostring(v))
        _config.save()
        printf('\awCastingInterruptOn: %s', v ~= 0 and '\agON (62)' or '\arOFF')
    end)

    -- Movement / camp
    bind('/makecamphere',   onMakeCampHere)
    bind('/stayhere',       onStayHere)
    bind('/campoff',        onCampOff)
    bind('/chaseme',        onChaseMe)
    bind('/trackmedown',    onTrackMeDown)
    bind('/SetPullArc',     onSetPullArc)
    bind('/setpullranking', onSetPullRanking)

    -- Buffs / group / misc
    bind('/buffgroup',      onBuffGroup)
    bind('/campfire',       onCampfire)
    bind('/tbmanager',      onTbManager)
    bind('/addfriend',      onAddFriend)

    -- Pull management
    bind('/addpull',        onAddPull)
    bind('/addignore',      onAddIgnore)
    bind('/addimmune',      onAddMezImmune)
    if mq.TLO.Alias('/addburn')() then mq.cmd('/alias /addburn delete') end
    bind('/addburn',        onAddBurn)

    -- Charm
    bind('/charmon',        onCharmOn)
    bind('/charmkeep',      onCharmKeep)
    bind('/setcharmed',     onSetCharmed)
    bind('/resetcharmed',   onResetCharmed)
    bind('/addcimmune',     onAddCharmImmune)

    bind('/kamedleyquiet',  function()
        if not state.session.iAmABard then
            printf('--MedleyQuiet: bard only.')
            return
        end
        mq.cmd('/medley quiet')
        state.bard.medleyQuiet = not state.bard.medleyQuiet
    end)

    -- Script control
    bind('/kastop', function()
        printf('\arKissAssist stopping...\ax')
        state.terminate = true
    end)
end

function Binds.unregister()
    for cmd in pairs(BOUND) do
        mq.unbind(cmd)
    end
    BOUND = {}
end

return Binds
