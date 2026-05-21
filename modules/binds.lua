local mq = require('mq')

local Binds = {}

local BOUND = {}

local function bind(cmd, fn)
    mq.bind(cmd, fn)
    BOUND[cmd] = true
end

local state, utils, _buffs, _loot, _cast, _combat, _config, _comms

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
        printf('\ay/debug [all|buffs|combat|cast|chainp|heals|mez|move|pet|pull|rk] [on|off] [log]')
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

local function onSwitchMA(newMA, _newRole, _doWhat)
    if not newMA or newMA == '' then return end
    state.session.mainAssist = newMA
    state.session.iAmMA = (newMA:lower() == (mq.TLO.Me.CleanName() or ''):lower())
    state.combat.calledTargetID = 0
    _combat.combatReset('switchma', 'switchma')
    printf('\awMain Assist changed to \at%s\aw (IAmMA=%s)', newMA, tostring(state.session.iAmMA))
end

local function onKissCast(castWhat, whatID, forceInterrupt)
    if not castWhat or castWhat == '' then
        printf('\ay/kisscast <spellname>')
        return
    end
    _cast.castWhat(castWhat, tonumber(whatID) or 0, forceInterrupt)
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

-- Shared sub-table list used by changevarint and togglevariable to search state.
local function stateSubtables()
    return {
        state.session, state.combat, state.cast, state.pull,
        state.movement, state.heal, state.buffs, state.pet,
        state.loot, state.dps, state.misc, state.bard, state.mez,
    }
end

local function onToggleVariable(varName, _val, _extra)
    if not varName or varName == '' then
        printf('\ay/togglevariable <varName>')
        return
    end
    for _, tbl in ipairs(stateSubtables()) do
        if tbl[varName] ~= nil then
            local cur = tbl[varName]
            if type(cur) == 'boolean' then
                tbl[varName] = not cur
                printf('\ay%s = \at%s', varName, tostring(tbl[varName]))
            elseif type(cur) == 'number' then
                tbl[varName] = cur == 0 and 1 or 0
                printf('\ay%s = \at%d', varName, tbl[varName])
            else
                printf('\aytogglervariable: %s is not toggleable (type: %s)', varName, type(cur))
            end
            return
        end
    end
    printf('\aytogglesvariable: unknown variable \at%s', varName)
end

local function onChangeVarInt(varName, value, _c, _d)
    if not varName or varName == '' then
        printf('\ay/changevarint <varName> <value>')
        return
    end
    local n = tonumber(value)
    if not n then
        printf('\aychangevarint: value must be a number, got: %s', tostring(value))
        return
    end
    for _, tbl in ipairs(stateSubtables()) do
        if tbl[varName] ~= nil then
            tbl[varName] = n
            printf('\ay%s = \at%d', varName, n)
            return
        end
    end
    printf('\aychangevarint: unknown variable \at%s', varName)
end

-- ─── Movement / camp ──────────────────────────────────────────────────────────

local function onMakeCampHere()
    state.movement.campX        = mq.TLO.Me.X()
    state.movement.campY        = mq.TLO.Me.Y()
    state.movement.campZ        = mq.TLO.Me.FloorZ()
    state.movement.campZone     = mq.TLO.Zone.ID()
    state.movement.returnToCamp = true
    state.session.chaseAssist   = false
    printf('\ay>> Camp set at %.1f, %.1f', state.movement.campY, state.movement.campX)
    if _comms then
        _comms.broadcast('CAMP', {
            x    = state.movement.campX,
            y    = state.movement.campY,
            z    = state.movement.campZ,
            zone = state.movement.campZone,
        })
    end
end

local function onStayHere()
    state.movement.campX        = mq.TLO.Me.X()
    state.movement.campY        = mq.TLO.Me.Y()
    state.movement.campZ        = mq.TLO.Me.FloorZ()
    state.movement.campZone     = mq.TLO.Zone.ID()
    state.movement.returnToCamp = true
    state.session.chaseAssist   = false
    printf('\ay>> StayHere — camp set at %.1f, %.1f', state.movement.campY, state.movement.campX)
    if _comms then _comms.broadcast('STAY', {}) end
end

local function onCampOff()
    state.movement.returnToCamp = false
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

-- Mirrors Bind_SetPullArc (kissassist.mac). Sets arc width; recomputes lSide/rSide.
local function onSetPullArc(width, _fdir)
    local w = tonumber(width) or 0
    state.pull.pullArcWidth = w
    if w > 0 then
        local half = w / 2.0
        state.pull.lSide = -half
        state.pull.rSide =  half
    else
        state.pull.lSide = 0
        state.pull.rSide = 0
    end
    mq.cmdf('/ini "%s" "Pull" "PullArcWidth" "%d"', state.session.iniFileName, w)
    printf('\ayPull arc set to \at%d\ay (lSide=%.1f rSide=%.1f).', w, state.pull.lSide, state.pull.rSide)
end

-- Mirrors Bind_SetPullRanking (kissassist.mac). Sets mob ranking preference.
local function onSetPullRanking(n, _arg)
    local ranking = tonumber(n) or 0
    state.pull.ranking = ranking
    mq.cmdf('/ini "%s" "Pull" "PullRanking" "%d"', state.session.iniFileName, ranking)
    printf('\ayPull ranking set to \at%d\ay.', ranking)
end

-- ─── Buffs / group ────────────────────────────────────────────────────────────

local function onBuffGroup(_flag)
    state.buffs.forceBuffs = true
    state.timers.iniNext   = 0
    _buffs.checkBuffs(true)
end

local function onCampfire()
    state.misc.campfireOn = true
    mq.cmd('/usefinditem Fellowship Campfire')
    printf('\ay>> Campfire placed at %.1f, %.1f', state.movement.campY, state.movement.campX)
end

local function onTbManager(action, spell)
    if not action or action == '' or not spell or spell == '' then
        printf('\ay/tbmanager [add|remove] SpellName')
        return
    end
    local a    = action:lower()
    local list = state.buffs.extendedList or ''
    if a == 'add' then
        if list:find(spell, 1, true) then
            printf('\ay%s is already in the Too-Buff list.', spell)
        else
            state.buffs.extendedList = list == '' and spell or (list .. ',' .. spell)
            mq.cmdf('/ini "%s" "Buffs" "ExtendedList" "%s"', state.session.iniFileName, state.buffs.extendedList)
            printf('\ayAdded %s to Too-Buff list.', spell)
        end
    elseif a == 'remove' then
        local parts = {}
        for entry in (list .. ','):gmatch('([^,]+),') do
            if entry ~= spell then parts[#parts + 1] = entry end
        end
        state.buffs.extendedList = table.concat(parts, ',')
        mq.cmdf('/ini "%s" "Buffs" "ExtendedList" "%s"', state.session.iniFileName, state.buffs.extendedList)
        printf('\ayRemoved %s from Too-Buff list.', spell)
    else
        printf('\ay/tbmanager [add|remove] SpellName')
    end
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
    local existing = mq.TLO.Ini(iniFile, zone, 'MobsToPull')() or ''
    local lname = name:lower()
    for entry in (existing .. ','):gmatch('([^,]+),') do
        if entry:match('^%s*(.-)%s*$'):lower() == lname then
            printf('\ay%s is already on the pull list.', name)
            return
        end
    end
    local updated = (existing == '' or existing == 'all' or existing == 'null')
        and name or (existing .. ',' .. name)
    state.pull.mobsToPullFirst = updated
    mq.cmdf('/ini "%s" "%s" "MobsToPull" "%s"', iniFile, zone, updated)
    printf('\ayAdded \at%s\ay to pull list.', name)
end

-- Mirrors Bind_AddToIgnore (kissassist.mac:8266). Appends name to zone-scoped MobsToIgnore
-- in KissAssist_Info.ini (shared across all characters in the zone), comma-delimited.
local function onAddIgnore(name, _byID)
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
    local existing = mq.TLO.Ini(iniFile, zone, 'MobsToIgnore')() or ''
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
        local existing = mq.TLO.Ini(iniFile, zone, 'MezImmune')() or ''
        if not existing:find(name, 1, true) then
            local updated = (existing == '' or existing == 'null') and name or (existing .. ',' .. name)
            mq.cmdf('/ini "%s" "%s" "MezImmune" "%s"', iniFile, zone, updated)
        end
    end
    printf('\ay>> Mez Immune -> %s <- ID:%d Added to immune list.', name, tID)
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
    local existing = mq.TLO.Ini(iniFile, zone, 'MobsToBurn')() or ''
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
    printf('MobsToPull:      %s', state.pull.mob)
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

local function onKissCheck()
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
end

local function onKaSettings(_cmd1, _cmd2, _skipIni)
    printf('>> KaSettings — M11 (ImGui UI)')
end

local function onWriteSpells(_quiet)
    _config.writeSpells(state)
    if not _quiet then printf('\aySpell set written to config.') end
end

-- Mirrors Bind_MemMySpells (kissassist.mac:14131-14232).
-- Reads Gem1..GemN from [Spells] (or [Spells{set}]) in the character INI and
-- mems each spell into the corresponding gem slot.
local function onMemMySpells(_charName, p_spellSet)
    local iniFile     = state.session.iniFileName
    local gemSlots    = state.cast.gemSlots or 8

    -- Determine spell section (Spells or SpellsN for alternate sets)
    local spellSection = (p_spellSet and p_spellSet ~= '' and p_spellSet ~= 'null')
                         and ('Spells' .. p_spellSet) or 'Spells'

    -- Validate section exists; fall back to Spells if alternate set not found
    if (mq.TLO.Ini(iniFile, spellSection, 'Gem1')() or '') == '' then
        if spellSection ~= 'Spells' then
            printf('\aw No Spells Section found for: %s. Defaulting to Spells Section.', spellSection)
            spellSection = 'Spells'
        end
        if (mq.TLO.Ini(iniFile, 'Spells', 'Gem1')() or '') == '' then
            printf('\aw No Spells found in INI: %s. Use /writespells and try again.', iniFile)
            return
        end
    end

    -- Bard twist-pause stub → M8

    local wasStanding = mq.TLO.Me.Standing()

    for i = 1, gemSlots do
        local spellToMem = mq.TLO.Ini(iniFile, spellSection, 'Gem' .. i)() or ''
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
                    state.misc.dontMoveMe = true
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
                    state.misc.dontMoveMe = false
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

-- ─── Loot ─────────────────────────────────────────────────────────────────────

local function onLootOn()
    state.loot.on = 1
    mq.cmd('/autoloot turn on')
    printf('\agLooting enabled.')
end

local function onLootOff()
    state.loot.on = 0
    mq.cmd('/autoloot turn off')
    printf('\ayLooting disabled.')
end

local function onSell()
    if state.loot.on == 0 then printf('\ayLooting is disabled (/kalooton to enable).') return end
    _loot.sell()
end
local function onDeposit()
    if state.loot.on == 0 then printf('\ayLooting is disabled (/kalooton to enable).') return end
    _loot.deposit()
end
local function onBarter()
    if state.loot.on == 0 then printf('\ayLooting is disabled (/kalooton to enable).') return end
    _loot.barter()
end

-- ─── Registration ─────────────────────────────────────────────────────────────

function Binds.register(s, u, b, l, cast, combat, config, comms)
    state   = s
    utils   = u
    _buffs  = b
    _loot   = l
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
    bind('/togglevariable', onToggleVariable)
    bind('/changevarint',   onChangeVarInt)

    -- Combat
    bind('/burn',           onBurn)
    bind('/backoff',        onBackOff)
    bind('/switchnow',      onSwitch)
    if mq.TLO.Alias('/switchma')() then mq.cmd('/alias /switchma delete') end
    bind('/switchma',       onSwitchMA)
    bind('/kisscast',       onKissCast)
    if mq.TLO.Alias('/peton')()  then mq.cmd('/alias /peton delete')  end
    if mq.TLO.Alias('/petoff')() then mq.cmd('/alias /petoff delete') end
    bind('/peton',          onPetOn)
    bind('/petoff',         onPetOff)
    bind('/mounton',        onMountOn)
    bind('/mountoff',       onMountOff)
    if mq.TLO.Alias('/autofireon')() then mq.cmd('/alias /autofireon delete') end
    bind('/autofireon',     onAutoFireOn)

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

    -- Loot
    bind('/kalooton',       onLootOn)
    bind('/kalootoff',      onLootOff)
    bind('/kasell',         onSell)
    bind('/kadeposit',      onDeposit)
    bind('/kabarter',       onBarter)
end

function Binds.unregister()
    for cmd in pairs(BOUND) do
        mq.unbind(cmd)
    end
    BOUND = {}
end

return Binds
