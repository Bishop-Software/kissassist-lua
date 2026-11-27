local mq      = require('mq')
local Utils   = require('modules.utils')
local Aliases = require('modules.aliases')
local Control = require('modules.control')

local Binds = {}

local BOUND = {}

local function bind(cmd, fn)
    mq.bind(cmd, fn)
    BOUND[cmd] = true
end

-- True if the port binds this command (any case). Used by /kactl test recent.
function Binds.isBound(name)
    name = (name or ''):lower()
    for cmd in pairs(BOUND) do
        if cmd:lower() == name then return true end
    end
    return false
end

local state, _buffs, _cast, _combat, _config

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

-- /backoff [on|off|1|0] [waitFlag]: Bind_BackOff (mac:13717-13767). on/1 backs
-- off, off/0 resumes, no argument toggles. Backing off stops the fight (melee,
-- MQ2Melee, stick, CombatReset); resuming turns MQ2Melee back on. With waitFlag
-- the MA gets 3 seconds to target a new mob, which becomes the new target.
-- Afterwards, with ReturnToCamp, head back to camp (unless waitFlag).
local function onBackOff(onOffFlag, waitFlag)
    local flag = (onOffFlag or ''):lower()
    local pausing
    if flag == 'on' or flag == '1' then
        pausing = true
    elseif flag == 'off' or flag == '0' then
        pausing = false
    else
        pausing = not state.dps.paused
    end
    local wait = (tonumber(waitFlag) or 0) ~= 0
    local c    = state.combat

    if pausing then
        state.dps.paused = true
        c.combatStart    = false
        if c.useMQ2Melee then mq.cmd('/squelch /melee off') end
        mq.cmd('/squelch /attack off')
        if mq.TLO.Stick.Active() then mq.cmd('/stick off') end
        _combat.combatReset(0, 'backoff')
        printf('\awBacking off - All Combat has been reset.')
    else
        printf('\awResetting. No Longer Backing off.')
        if wait and state.session.iAmMA then
            if (mq.TLO.Me.Casting.ID() or 0) ~= 0 then
                mq.cmd('/stopcast')
                state.cast.castResult = 'CAST_CANCELLED'
            end
            printf('\awPausing for new target. Switch to new target now.')
            mq.cmd('/beep')
            local oldTarget = mq.TLO.Target.ID() or 0
            local function switched()
                local t = mq.TLO.Target.ID() or 0
                return t ~= 0 and t ~= oldTarget
            end
            mq.delay(3000, switched)
            if switched() then
                -- CombatTargetCheck 2 runs while still paused, with target switching forced on.
                local saved = c.targetSwitchingOn
                c.targetSwitchingOn = true
                _combat.combatTargetCheck(2)
                c.targetSwitchingOn = saved
                printf('\awTarget Switched from Backoff command.')
            else
                printf('\awTarget NOT Switched. You can always try again.')
            end
        end
        if c.useMQ2Melee then mq.cmd('/squelch /melee on') end
        state.dps.paused = false
    end

    local mv = state.movement
    if mv.returnToCamp and not wait and (mv.campX ~= 0 or mv.campY ~= 0) then
        local dy = (mq.TLO.Me.Y() or 0) - mv.campY
        local dx = (mq.TLO.Me.X() or 0) - mv.campX
        if math.sqrt(dx * dx + dy * dy) > 15 then
            require('modules.movement').doWeMove(0, 'bind_backoff')
        end
    end
end

local function onSwitch(_lockOnFlag, newTargetID)
    if state.session.iAmMA then return end
    state.combat.calledTargetID = tonumber(newTargetID) or 0
    _combat.combatReset('switch', 'switchnow')
    printf('\aw>> Switching to target ID: %d', state.combat.calledTargetID)
end

-- /switchma <name> [role] [1]: Bind_SwitchMA (mac:10969), in modules/roles.lua.
-- Broadcasts to the group unless the 3rd arg is non-zero (mac:10973-10978).
local function onSwitchMA(newMA, newRole, doWhat)
    if not newMA or newMA == '' then
        printf('\ay/switchma <name> [role] [1 = don\'t broadcast]')
        return
    end
    local broadcast = not doWhat or doWhat == '' or tonumber(doWhat) == 0
    require('modules.roles').switchMA(newMA, newRole, broadcast)
end

-- /kactl target <id>|clear: switch the combat target to that spawn now, or clear
-- it so the next hater is picked up (was /kaswitchtarget). A one-off switch;
-- holding a target until it dies is phase 4 (#364).
local function kactlTarget(words)
    if #words ~= 1 then return false, 'expects a spawn ID or clear' end
    if tostring(words[1]):lower() == 'clear' then
        state.combat.myTargetID    = 0
        state.combat.aggroTargetID = ''
        return true, 'target cleared'
    end
    local id = math.floor(tonumber(words[1]) or 0)
    local sp = mq.TLO.Spawn('id ' .. id)
    if id <= 0 or (sp.ID() or 0) == 0 then return false, 'no spawn with ID ' .. tostring(words[1]) end
    state.combat.myTargetID    = 0
    state.combat.aggroTargetID = tostring(id)
    return true, string.format('target %s (ID %d)', sp.CleanName() or '?', id)
end

local function onKissCast(castWhat, whatID, _forceInterrupt)
    if not castWhat or castWhat == '' then
        printf('\ay/kisscast <spellname>')
        return
    end
    _cast.castWhat(castWhat, tonumber(whatID) or 0, 'KissCast')
end


-- ─── /togglevariable and /changevarint ───────────────────────────────────────
-- Both take the mac's variable names (ChaseAssist, MeleeOn, ...), so aliases left
-- over from kissassist.mac (/chase, /meleeon, /assistat, ...) keep working.
-- Thin adapters: the work is Control.set (modules/control.lua); these keep the
-- mac's argument forms and messages.

-- /togglevariable <name> [on|off|1|0|value] [who]. Port of Bind_ToggleVariable
-- (mac:8371). As in the mac, no value turns it off. Not saved to the INI.
-- 'waithere' stops chasing and returning to camp.
local function onToggleVariable(varName, val, extra)
    if not varName or varName == '' then
        printf('\ay/togglevariable <name> [on|off|value]')
        return
    end
    local ok, msg, info = Control.set(varName, val, { who = extra })
    if not ok then
        if msg == 'unsupported' then
            printf('\ay%s is not supported in the Lua port.', varName)
        elseif msg == 'badvalue' then
            printf('\ay/togglevariable: bad value \at%s\ay for \at%s', tostring(val), varName)
        else
            printf('\ay/togglevariable: unknown variable \at%s', varName)
        end
        return
    end
    if msg == 'waithere' then return end
    if info.shown then
        printf('\ay>> Setting: (%s) to (%s)', varName, info.shown)
        return
    end
    printf('\ay>> Setting: (%s) to (%s) (%s)', varName, info.on and 'On' or 'Off', tostring(info.now))
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
    local ok, msg, info = Control.set(name, value, { section = section, save = section ~= nil })
    if not ok then
        if msg == 'badvalue' then
            printf('\ay/changevarint: bad value \at%s\ay for \at%s', value, name)
        elseif msg == 'unsupported' then
            printf('\ay%s is not supported in the Lua port.', name)
        else
            printf('\ay/changevarint: unknown variable \at%s', name)
        end
        return
    end
    if msg == 'waithere' then return end
    if info.shown then
        printf('\ayChanging %s to %s', name, info.shown)
        return
    end
    printf('\ayChanging %s from %s to %s', name, tostring(info.old), tostring(info.value))
end

-- ─── Movement / camp ──────────────────────────────────────────────────────────
-- The mac's camp/chase commands, as adapters over Control.setMode
-- (modules/control.lua). /kactl mode is the script-safe form of each.

-- /makecamphere: this toon and the group's kissassist-lua boxes camp at this spot.
-- (The mac's has the other boxes camp each at their own spot and leaves the
-- sender alone, mac:11373; the port has always used one shared spot.)
-- /kactl mode camp here group
local function onMakeCampHere()
    Control.setMode('camp', { here = true, group = true })
end

-- /stayhere: the other boxes stop where they are, no chasing, no camp return;
-- this toon is left as it is (mac:11361 sends /waithere to the group).
-- /kactl mode manual others
local function onStayHere()
    Control.setMode('manual', { others = true })
    printf('\ay>> StayHere: the group stops chasing and returning to camp.')
end

-- /chaseme: the other boxes chase this toon; this toon is left as it is
-- (mac:11349 sends /chase on <me> to the group). /kactl mode chase me others
local function onChaseMe()
    local myName = mq.TLO.Me.CleanName() or ''
    Control.setMode('chase', { who = myName, others = true })
    printf('\ay>> ChaseMe %s', myName)
end

-- Mirrors Bind_TrackMeDown (kissassist.mac). Sets chase target; no arg turns
-- chasing off. /kactl mode chase <name>
local function onTrackMeDown(name, _useNavOnly, _ignoreDist)
    if not name or name == '' then
        Control.set('ChaseAssist', false)
        state.movement.whoToChase = ''
        printf('\ayChase assist disabled.')
    else
        Control.setMode('chase', { who = name })
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

-- /campfire: place a fellowship campfire (mac Bind_Campfire, mac:11840)
local function onCampfire()
    require('modules.campfire').place()
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
    -- The name goes on this zone's MezImmune list: Info INI, state and alert
    -- list 4, so it takes effect at once (modules/mez.lua).
    require('modules.mez').addImmuneName(name)
    printf('\ay>> Mez Immune -> %s <- ID:%d Added to immune list.', name, tID)
end

-- /kactl charm on|off|toggle [save], charm keep on|off|toggle [save], charm set,
-- charm reset (were /charmon, /charmkeep, /setcharmed, /resetcharmed from the
-- kisscharm.mac fork). Charm classes only (DRU/ENC/NEC/BRD).
local function kactlCharm(words)
    local save = Control.takeFlag(words, 'save')
    local what = tostring(words[1] or ''):lower()
    if what == 'set' or what == 'reset' then
        if #words > 1 or save then return false, 'charm ' .. what .. ' takes no arguments' end
        if what == 'reset' then
            state.charm.petId, state.charm.petZone = 0, ''
            return true, 'charm pet reset'
        end
        local petID = mq.TLO.Me.Pet.ID() or 0
        if petID == 0 then return false, 'no pet to record' end
        state.charm.petId   = petID
        state.charm.petZone = mq.TLO.Zone.ShortName() or ''
        return true, string.format('charm pet ID %d in %s', petID, state.charm.petZone)
    end
    if not state.session.iAmACharmClass then return false, 'not a charm class (DRU/ENC/NEC/BRD)' end
    local key, field, word = 'CharmOn', 'on', words[1]
    if what == 'keep' then key, field, word = 'CharmKeep', 'keep', words[2] end
    if #words > (what == 'keep' and 2 or 1) then return false, 'unexpected word' end
    local on, err = Control.onOff(word, state.charm[field])
    if on == nil then return false, err end
    Control.set(key, on, save and { save = true, section = 'Charm' } or nil)
    return true, string.format('%s %s', key, on and 'on' or 'off')
end

-- /kactl list charmimmune add: the target goes on the runtime charm-immune ID
-- list, and its name on this zone's CharmImmune list when AACharmImmune=1
-- (was /addcimmune).
local function addCharmImmune()
    local tID   = mq.TLO.Target.ID() or 0
    local tType = (mq.TLO.Target.Type() or ''):lower()
    if tID == 0 or tType ~= 'npc' then return false, 'target an NPC first' end
    local name = mq.TLO.Target.CleanName() or ''
    if name:sub(1, 1) == '#' then name = name:sub(2) end
    name = name:match("^(.+)'s corpse$") or name:match("^(.+) corpse$") or name
    local tag = '|' .. tostring(tID)
    if state.charm.immuneIds:find(tag, 1, true) then
        return true, string.format('%s (ID %d) is already charm immune', name, tID)
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
    return true, string.format('%s (ID %d) is charm immune', name, tID)
end

-- /kactl list burn add [name]: the mob (or the target) goes on this zone's
-- MobsToBurn list in KissAssist_Info.ini and the live named-watch list (was /addburn).
local function addBurn(name)
    if not name or name == '' then
        name = mq.TLO.Target.CleanName() or ''
        if name == '' then return false, 'no name and no target' end
    end
    local iniFile = state.session.infoFileName
    local zone    = state.session.zoneName
    if not iniFile or iniFile == '' or not zone or zone == '' then return false, 'zone not available yet' end
    local existing = Utils.zoneIniGet(iniFile, zone, 'MobsToBurn') or ''
    local lname = name:lower()
    for entry in (existing .. ','):gmatch('([^,]+),') do
        if entry:match('^%s*(.-)%s*$'):lower() == lname then
            return true, name .. ' is already on the burn list'
        end
    end
    local updated = (existing == '' or existing == 'null')
        and name or (existing .. ',' .. name)
    state.combat.namedWatchList[#state.combat.namedWatchList + 1] = lname
    mq.cmdf('/ini "%s" "%s" "MobsToBurn" "%s"', iniFile, zone, updated)
    return true, 'added ' .. name .. ' to the burn list'
end

-- /kactl list <list> <action> [name]. LISTS[list][action](name) -> ok, msg.
-- burn and charmimmune are here; the mac's lists (pull, ignore, mezimmune,
-- friend, toobuff) are added in Binds.register, where their commands are.
local LISTS = {
    burn        = { add = function(name) return addBurn(name) end },
    charmimmune = { add = function(name)
        if name then return false, 'charmimmune adds the target; no name' end
        return addCharmImmune()
    end },
}

local function kactlList(words)
    local list, action = tostring(words[1] or ''):lower(), tostring(words[2] or ''):lower()
    local actions = LISTS[list]
    if not actions then
        local names = {}
        for n in pairs(LISTS) do names[#names + 1] = n end
        table.sort(names)
        return false, 'lists: ' .. table.concat(names, ', ')
    end
    local fn = actions[action]
    if not fn then
        local names = {}
        for n in pairs(actions) do names[#names + 1] = n end
        table.sort(names)
        return false, list .. ' takes ' .. table.concat(names, ', ')
    end
    local name = #words > 2 and table.concat(words, ' ', 3) or nil
    return fn(name)
end

-- /kactl medley quiet on|off|toggle: bard only; MQ2Medley's quiet mode (was
-- /kamedleyquiet). /medley quiet flips it, so it's only sent when it changes.
local function kactlMedley(words)
    if tostring(words[1] or ''):lower() ~= 'quiet' or #words ~= 2 then return false, 'expects quiet on|off|toggle' end
    if not state.session.iAmABard then return false, 'bard only' end
    local on, err = Control.onOff(words[2], state.bard.medleyQuiet)
    if on == nil then return false, err end
    if on ~= (state.bard.medleyQuiet == true) then
        mq.cmd('/medley quiet')
        state.bard.medleyQuiet = on
    end
    return true, 'medley quiet ' .. (on and 'on' or 'off')
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
        state.combat.dpsOn and (state.combat.dpsOnOoc and '2' or '1') or '0',
        tostring(state.combat.meleeOn))
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
-- replaces it, so this just opens the window (/kactl ui toggles it).
local function onKaSettings(_cmd1, _cmd2, _skipIni)
    require('modules.ui').show()
    printf('\ay>> Settings are in the KissAssist window (/kactl ui toggle to show or hide it).')
end

local function onWriteSpells(quiet)
    _config.writeSpells(state)
    if not quiet then printf('\aySpell set written to config.') end
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

    -- Bard: stop the songs while memming (mac:14182 CastBardCheck 0). With
    -- MQ2Medley that's /medley stop plus clearing the song mid-cast.
    local Bard = state.session.iAmABard and require('modules.bard') or nil
    if Bard then Bard.pauseMedley() end

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

    -- Stand back up if we were standing (mac:14225); a bard then gets its medley
    -- restarted if we stopped it (mac:14221-14224).
    if wasStanding and mq.TLO.Me.Sitting() and not mq.TLO.Me.Mount.ID() then
        mq.cmd('/stand')
    end
    if Bard then Bard.resumeMedley() end
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

local INTEGRATION_TESTS = { 'debug_cmds', 'toggle_cmds', 'camp_cmds', 'switchma', 'charm_cmds', 'switchtarget', 'recent' }

-- Runs from the main loop (state.misc.pendingTest), not inside the /kactl bind,
-- since the suites send /kactl commands of their own.
function Binds.runTests(testName)
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
            printf('\ar[ERROR]\ax /kactl test %s: %s', name, tostring(err))
        end
    end
    TH.printSummary()
end

-- /kactl test <suite>|all (was /katest): queue the run for the main loop.
local function kactlTest(words)
    local name = tostring(words[1] or ''):lower()
    local known = name == 'all'
    for _, n in ipairs(INTEGRATION_TESTS) do if n == name then known = true end end
    if #words ~= 1 or not known then
        return false, 'suites: ' .. table.concat(INTEGRATION_TESTS, ', ') .. ', all'
    end
    state.misc.pendingTest = name
    return true, 'running ' .. name
end

-- ─── Registration ─────────────────────────────────────────────────────────────

-- ─── The mac's commands: deprecated, each with a /kactl replacement ───────────
-- The 30 commands kissassist.mac binds stay as they are (mixed groups, MQ2Boxr
-- and the mac's aliases send them), but each prints a one-line notice, once per
-- session, naming its /kactl form. [General] LegacyCmdNotice=0 turns that off.

local _noticed = {}
local _shown   = {}  -- every notice shown this session, '<key> -> <replacement>'

-- The notices shown so far (for tests and /kactl check-style reports).
function Binds.shownNotices() return _shown end

-- /togglevariable and /changevarint name the variable, so someone typing the
-- /camphere alias reads about ReturnToCamp, not a command they never typed.
local function varReplacement(name, save)
    local l = tostring(name or ''):lower()
    if l == 'returntocamp' then return '/kactl mode camp here (or mode manual)' end
    if l == 'chaseassist' then return '/kactl mode chase [name] (or mode manual)' end
    if l == 'waithere' then return '/kactl mode manual' end
    return string.format('/kactl set %s <value>%s', name, save and ' save' or '')
end

local function notice(key, replacement)
    if state.session.legacyCmdNotice == false or _noticed[key] then return end
    _noticed[key] = true
    _shown[#_shown + 1] = key .. ' -> ' .. replacement
    printf('\ay%s is deprecated; use \at%s\ay (once per session; [General] LegacyCmdNotice=0 hides these).',
        key, replacement)
end

-- Bind a mac command; replacement is a string or a function(...) -> key, replacement.
local function legacy(cmd, fn, replacement)
    bind(cmd, function(...)
        if type(replacement) == 'function' then
            notice(replacement(...))
        else
            notice(cmd, replacement)
        end
        fn(...)
    end)
end

-- /kactl verbs that replace the mac's commands. Strict arguments; the work is
-- the mac command's own handler, so its usual messages still print.
local function only(words, n, usage)
    if #words ~= n then return false, 'expects ' .. usage end
    return true
end

local function kactlBackoff(words)
    local wait = Control.takeFlag(words, 'wait')
    if #words ~= 1 then return false, 'expects on, off or toggle [wait]' end
    local on, err = Control.onOff(words[1], state.dps.paused)
    if on == nil then return false, err end
    onBackOff(on and 'on' or 'off', wait and '1' or '0')
    return true, on and 'backed off' or 'fighting'
end

-- /kactl burn [<id>]: burn now on that spawn, the fight target or the NPC
-- target. Turns BurnOn on for the session first, as MQ2Boxr's /burn on doburn does.
local function kactlBurn(words)
    if #words > 1 then return false, 'expects [<id>]' end
    if words[1] and not tonumber(words[1]) then return false, 'expects a spawn ID' end
    if not state.combat.burnOn then
        state.combat.burnOn     = true
        state.movement.campZone = mq.TLO.Zone.ID()
    end
    onBurn(words[1] or '')
    return true, 'burning ID ' .. tostring(state.combat.burnID)
end

-- /kactl ignore <id>|clear: ignore one spawn ID for the session (/addignore <id> 1).
local function kactlIgnore(words)
    if #words ~= 1 then return false, 'expects a spawn ID or clear' end
    if tostring(words[1]):lower() == 'clear' then
        state.pull.mobsToIgnoreByID = 'null'
        return true, 'session ignore list cleared'
    end
    local id = math.floor(tonumber(words[1]) or 0)
    if id <= 0 or (mq.TLO.Spawn('id ' .. id).Type() or ''):upper() ~= 'NPC' then
        return false, 'no NPC with ID ' .. tostring(words[1])
    end
    onAddIgnore(tostring(id), 1)
    return true, 'ignoring ID ' .. id
end

-- /kactl switch <id>: a non-MA switches to the called target (/switchnow).
local function kactlSwitch(words)
    if #words ~= 1 or not tonumber(words[1]) then return false, 'expects a spawn ID' end
    if state.session.iAmMA then return false, 'the main assist picks its own target (use target)' end
    onSwitch(nil, words[1])
    return true, 'switching to ID ' .. words[1]
end

-- /kactl ma <name> [role] [group]: change the main assist (/switchma). Only
-- tells the group with 'group' (the mac's /switchma does unless told not to).
local function kactlMA(words)
    local group = Control.takeFlag(words, 'group')
    if #words < 1 or #words > 2 then return false, 'expects <name> [role] [group]' end
    require('modules.roles').switchMA(words[1], words[2], group)
    return true, 'main assist ' .. words[1]
end

-- /kactl cast <spell name...> [<id>]: cast by name (/kisscast); a trailing number is the target.
local function kactlCast(words)
    if #words == 0 then return false, 'expects <spell> [<id>]' end
    local id
    if #words > 1 and tonumber(words[#words]) then id = table.remove(words) end
    onKissCast(table.concat(words, ' '), id)
    return true, 'cast ' .. table.concat(words, ' ')
end

local function kactlDebug(words)
    local log = Control.takeFlag(words, 'log')
    if #words ~= 2 then return false, 'expects <area>|all on|off|toggle [log]' end
    local area = tostring(words[1]):lower()
    local field = area == 'all' and 'all' or DEBUG_FIELDS[area]
    if not field then return false, 'unknown area ' .. area end
    local on, err = Control.onOff(words[2], state.debug[field])
    if on == nil then return false, err end
    onDebug(area, on and 'on' or 'off', log and 'log' or nil)
    return true, string.format('debug %s %s', area, on and 'on' or 'off')
end

-- _comms: group messages now go out through Control (modules/control.lua);
-- the argument stays so the call in init.lua and the tests don't change.
function Binds.register(s, b, cast, combat, config, _comms)
    state   = s
    _buffs  = b
    _cast   = cast
    _combat = combat
    _config = config
    state.session.legacyCmdNotice = _config.get('General', 'LegacyCmdNotice', '1') ~= '0'

    -- The mac's commands (deprecated; the notice names the /kactl form)
    legacy('/debug',          onDebug,        '/kactl debug <area>|all on|off|toggle [log]')
    legacy('/parse',          onParse,        '/kactl parse <expression>')
    legacy('/zoneinfo',       onZoneInfo,     '/kactl info zone')
    legacy('/aggroinfo',      onAggroInfo,    '/kactl info aggro')
    legacy('/iniwrite',       onIniWrite,     '/kactl ini write')
    legacy('/writespells',    onWriteSpells,  '/kactl spells write')
    legacy('/memmyspells',    onMemMySpells,  '/kactl spells mem [set]')
    legacy('/mycmd',          onMyCmds,       '/kactl mycmd [command]')
    legacy('/kisscheck',      onKissCheck,    '/kactl check [sections]')
    legacy('/kasettings',     onKaSettings,   '/kactl ui on')
    legacy('/togglevariable', onToggleVariable, function(name)
        return '/togglevariable ' .. tostring(name or ''), varReplacement(name, false)
    end)
    legacy('/changevarint',   onChangeVarInt, function(a1, a2, a3)
        local name = (a3 and a3 ~= '') and a2 or a1
        return '/changevarint ' .. tostring(name or ''), varReplacement(name, a3 and a3 ~= '')
    end)
    legacy('/burn',           onBurn,         '/kactl burn [<id>] (and /kactl set BurnOn on|off)')
    legacy('/backoff',        onBackOff,      '/kactl backoff on|off|toggle [wait]')
    legacy('/switchnow',      onSwitch,       '/kactl switch <id>')
    legacy('/switchma',       onSwitchMA,     '/kactl ma <name> [role] [group]')
    legacy('/kisscast',       onKissCast,     '/kactl cast <spell> [<id>]')
    -- /peton and /autofireon are mac aliases (modules/aliases.lua), not commands.
    legacy('/makecamphere',   onMakeCampHere, '/kactl mode camp here group')
    legacy('/stayhere',       onStayHere,     '/kactl mode manual others')
    legacy('/chaseme',        onChaseMe,      '/kactl mode chase me others')
    legacy('/trackmedown',    onTrackMeDown,  '/kactl mode chase <name> (or mode manual)')
    legacy('/SetPullArc',     onSetPullArc,   '/kactl pullarc <width> [dir]')
    legacy('/setpullranking', onSetPullRanking, '/kactl set PullRanking on|off')
    legacy('/buffgroup',      onBuffGroup,    '/kactl buff now')
    legacy('/campfire',       onCampfire,     '/kactl campfire')
    legacy('/tbmanager',      onTbManager,    '/kactl list toobuff add|remove|clear|reset [<id>]')
    legacy('/addfriend',      onAddFriend,    '/kactl list friend add')
    legacy('/addpull',        onAddPull,      '/kactl list pull add [name]')
    legacy('/addignore',      onAddIgnore,    function(_name, byID)
        if tonumber(byID) == 1 then return '/addignore <id> 1', '/kactl ignore <id>' end
        return '/addignore', '/kactl list ignore add [name]'
    end)
    legacy('/addimmune',      onAddMezImmune, '/kactl list mezimmune add')

    -- The mac's lists in /kactl list (the burn and charmimmune lists are above).
    local function addOnly(fn, takesName)
        return { add = function(name)
            if name and not takesName then return false, 'adds the target; no name' end
            fn(name)
            return true, 'added'
        end }
    end
    LISTS.pull      = addOnly(onAddPull, true)
    LISTS.ignore    = addOnly(onAddIgnore, true)
    LISTS.mezimmune = addOnly(onAddMezImmune, false)
    LISTS.friend    = addOnly(onAddFriend, false)
    local function tb(action)
        return function(id)
            if id and not tonumber(id) then return false, 'expects a spawn ID (or your target)' end
            onTbManager(action, id)
            return true, 'too buff list ' .. action
        end
    end
    LISTS.toobuff = { add = tb('add'), remove = tb('remove'), clear = tb('clear'), reset = tb('reset') }

    -- Script control: /kactl <verb> [args] (modules/control.lua, #360). The
    -- verbs whose code lives here; mode, set, pause and stop are in control.lua,
    -- ui in ui.lua. Lua-only commands (/kapause, /kastop, /katest, /charmon, ...)
    -- became these verbs in #363; the mac's commands got theirs in #363 too.
    Control.verb('target', 'target <id>|clear', kactlTarget)
    Control.verb('charm',  'charm on|off|toggle | keep on|off|toggle  [save] | set | reset', kactlCharm)
    Control.verb('medley', 'medley quiet on|off|toggle', kactlMedley)
    Control.verb('list',   'list burn|charmimmune|pull|ignore|mezimmune|friend add [name] | toobuff add|remove|clear|reset [<id>]', kactlList)
    Control.verb('test',   'test <suite>|all', kactlTest)
    Control.verb('backoff', 'backoff on|off|toggle [wait]', kactlBackoff)
    Control.verb('burn',    'burn [<id>]', kactlBurn)
    Control.verb('ignore',  'ignore <id>|clear', kactlIgnore)
    Control.verb('switch',  'switch <id>', kactlSwitch)
    Control.verb('ma',      'ma <name> [role] [group]', kactlMA)
    Control.verb('cast',    'cast <spell> [<id>]', kactlCast)
    Control.verb('debug',   'debug <area>|all on|off|toggle [log]', kactlDebug)
    Control.verb('pullarc', 'pullarc <width> [dir]', function(words)
        if #words < 1 or #words > 2 or not tonumber(words[1]) then return false, 'expects <width> [dir]' end
        onSetPullArc(words[1], words[2])
        return true, 'pull arc ' .. words[1]
    end)
    Control.verb('buff', 'buff now', function(words)
        local ok, err = only(words, 1, 'now')
        if not ok or tostring(words[1]):lower() ~= 'now' then return false, err or 'expects now' end
        onBuffGroup()
        return true, 'buff pass'
    end)
    Control.verb('campfire', 'campfire', function(words)
        if #words > 0 then return false, 'takes no arguments' end
        onCampfire()
        return true, 'campfire'
    end)
    Control.verb('ini', 'ini write', function(words)
        if #words ~= 1 or tostring(words[1]):lower() ~= 'write' then return false, 'expects write' end
        onIniWrite()
        return true, 'config saved'
    end)
    Control.verb('spells', 'spells write | mem [set]', function(words)
        local what = tostring(words[1] or ''):lower()
        if what == 'write' and #words == 1 then onWriteSpells(); return true, 'spells written' end
        if what == 'mem' and #words <= 2 then onMemMySpells(nil, words[2]); return true, 'memming spells' end
        return false, 'expects write or mem [set]'
    end)
    Control.verb('check', 'check [sections]', function(words)
        onKissCheck(unpack(words))
        return true, 'checked'
    end)
    Control.verb('info', 'info zone|aggro', function(words)
        local what = tostring(words[1] or ''):lower()
        if #words ~= 1 then return false, 'expects zone or aggro' end
        if what == 'zone' then onZoneInfo() elseif what == 'aggro' then onAggroInfo()
        else return false, 'expects zone or aggro' end
        return true, what
    end)
    Control.verb('parse', 'parse <expression>', function(words)
        if #words == 0 then return false, 'expects an expression' end
        onParse(table.concat(words, ' '))
        return true, 'parsed'
    end)
    Control.verb('mycmd', 'mycmd [command]', function(words)
        onMyCmds(unpack(words))
        return true, 'sent'
    end)
    bind('/kactl', function(...) Control.command({ ... }) end)

    -- The mac's /alias shortcuts (mac LoadAliases). Runs after every bind so names
    -- the port binds are skipped: MQ won't add an alias while a command exists.
    local boundLower = {}
    for cmd in pairs(BOUND) do boundLower[cmd:lower()] = true end
    local written, deleted = Aliases.sync(function(name) return boundLower[name:lower()] end)
    Utils.debug('all', 'Aliases: %d written, %d deleted', written, deleted)
end

function Binds.unregister()
    for cmd in pairs(BOUND) do
        mq.unbind(cmd)
    end
    BOUND = {}
end

return Binds
