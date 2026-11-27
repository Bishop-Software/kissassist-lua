-- modules/control.lua — the one place that changes a kissassist-lua setting or
-- movement mode. /togglevariable, /changevarint, the camp/chase commands, the
-- GUI, group messages and /kactl all come through here, so a change behaves the
-- same however it arrives (kactl control API design, #360).
--
--   Control.set(name, value, opts)   a variable (phase 1, #361)
--   Control.setMode(mode, opts)      manual / camp / chase (phase 2, #362)
--   /kactl mode ...                  Control.command
--
-- Neither prints its own result: they return ok, msg, info and the caller
-- decides what to show. The side effects keep the mac's messages
-- ("New camp set", "I Will Now Chase ...").
local mq = require('mq')

local Control = {}

local _state, _config, _comms

function Control.init(state, config, comms)
    _state  = state
    _config = config
    _comms  = comms
end

-- State sub-tables searched for a variable, in order.
local VAR_TABLES = {
    'session', 'combat', 'cast', 'pull', 'movement', 'heal', 'buffs', 'pet',
    'loot', 'dps', 'misc', 'bard', 'mez', 'afk', 'merc', 'charm', 'debuff', 'cond',
}

-- Names that don't match their state field (lowercase name -> table, field):
-- the mac's variable names and the INI keys the port spells differently.
-- Everything else is found by a case-insensitive field search.
local NAMES = {
    -- mac variable names
    peton        = { 'pet', 'on' },       pettoyson   = { 'pet', 'toysOn' },
    pethold      = { 'pet', 'holdOn' },   petcombaton = { 'pet', 'combatOn' },
    looton       = { 'loot', 'on' },      afktoolson  = { 'afk', 'on' },
    mezon        = { 'mez', 'on' },       conon       = { 'cond', 'on' },
    charmon      = { 'charm', 'on' },     mercon      = { 'merc', 'on' },
    debuffon     = { 'debuff', 'on' },    pullhold    = { 'pull', 'hold' },
    dpspaused    = { 'dps', 'paused' },
    pullranking  = { 'pull', 'ranking' },
    -- session.assistAt is only the command-line value; combat uses this one
    assistat     = { 'combat', 'assistAt' },
    mercassistat = { 'merc', 'assistAt' },
    -- INI keys
    petholdon         = { 'pet', 'holdOn' },
    petshrinkon       = { 'pet', 'shrinkOn' },
    petsuspend        = { 'pet', 'suspend' },
    pettauntoverride  = { 'pet', 'tauntOverride' },
    petforcehealonmed = { 'pet', 'forceHealOnMed' },
    charmkeep         = { 'charm', 'keep' },
    charmradius       = { 'charm', 'radius' },
    charmminlevel     = { 'charm', 'minLevel' },
    charmmaxlevel     = { 'charm', 'maxLevel' },
    mezradius         = { 'mez', 'radius' },
    mezstophps        = { 'mez', 'stopHPs' },
    mezminlevel       = { 'mez', 'minLevel' },
    mezmaxlevel       = { 'mez', 'maxLevel' },
    pullmeleestick    = { 'pull', 'meleeStick' },
    pullroletoggle    = { 'pull', 'roleToggle' },
    pullradiustouse   = { 'pull', 'radiusToUse' },
    afkgmaction       = { 'afk', 'gmAction' },
    afkpcradius       = { 'afk', 'pcRadius' },
    charmspell        = { 'charm', 'spell' },
    petspell          = { 'pet', 'spell' },
    petshrinkspell    = { 'pet', 'shrinkSpell' },
    -- the INI value as written; movement.stickHow is it resolved by role
    stickhow          = { 'movement', 'dStickHow' },
}

-- Mac variables that have no counterpart in the port.
local UNSUPPORTED = {
    dpsmeter = true, dpsspam = true, dpswriteon = true,
}

-- Find a variable by its mac name, INI key or port field name.
-- Returns table, field (or nil).
function Control.resolve(name)
    local lname = tostring(name or ''):lower()
    local alias = NAMES[lname]
    if alias and _state[alias[1]] then return _state[alias[1]], alias[2] end
    for _, sub in ipairs(VAR_TABLES) do
        local t = _state[sub]
        if t then
            if t[name] ~= nil then return t, name end
            for k in pairs(t) do
                if type(k) == 'string' and k:lower() == lname then return t, k end
            end
        end
    end
end

-- Convert a value to the field's type. A boolean is on/off as is; on/1 = on,
-- off/0/empty = off, another number is used as is (mac:8378-8406).
-- Returns the new value and on/off. asText: a text setting (a spell name, a
-- list) takes the text exactly as given, empty included.
local function convertValue(cur, field, arg, asText)
    if asText then
        local t = arg == nil and '' or tostring(arg)
        return t, t ~= ''
    end
    local a, la, num, on
    if type(arg) == 'boolean' then
        a, la, on = '', '', arg
    else
        a   = tostring(arg or ''):match('^%s*(.-)%s*$')
        la  = a:lower()
        num = tonumber(a)
        if la == 'on' then on = true
        elseif la == 'off' or la == '' or la == 'null' then on = false
        elseif num then on = num > 0
        else on = true end
    end
    if type(cur) == 'boolean' then return on, on end
    if type(cur) == 'number' then
        if num then return num, num > 0 end
        if not on then return 0, false end
        return field == 'castingInterruptOn' and 62 or 1, true  -- 62 = the mac's "all" bitmask
    end
    if on and a ~= '' and la ~= 'on' then return a, true end
    return on and '1' or '0', on
end

-- Text written to the INI. What was typed is kept as typed (the mac's
-- /changevarint); a boolean from the GUI becomes 1/0 or the field's number.
local function iniText(raw, value, on)
    if type(raw) == 'boolean' then
        if type(value) == 'number' then return tostring(value) end
        return on and '1' or '0'
    end
    return tostring(raw)
end

local function stickOff()
    if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
end

-- Side effects of turning a variable on/off (mac Bind_ToggleVariable 8406-8470,
-- Bind_ChangeVarInt 11256-11335). save: the change is also written to the INI.
-- raw: the value as given (DPSOn 2 and BuffsOn 2 need more than on/off).
local function sideEffects(tbl, field, on, who, save, raw)
    local mv = _state.movement
    if tbl == _state.afk and (field == 'on' or field == 'pcRadius') then
        -- AFK stranger check: MQ2Posse watches the PC radius (modes 1 and 2)
        local afk = _state.afk
        if (field == 'pcRadius' or afk.on == 1 or afk.on == 2) and mq.TLO.Plugin('MQ2Posse').IsLoaded() then
            mq.cmdf('/posse radius %d', afk.pcRadius or 0)
        end
    elseif field == 'autoHide' and save then
        _config.set('General', 'AutoHide', nil)  -- older UI builds saved it here
    elseif field == 'dStickHow' then
        require('modules.movement').resolveStickHow()
    elseif field == 'xTarHealList' then
        require('modules.healing').setXTargetHealList(_state.heal.xTarHealList)
    elseif field == 'dpsOn' then
        -- DPSOn 2 = any HP + wait out the spell cooldown (combat.dpsOnOoc)
        _state.combat.dpsOnOoc = on and tonumber(raw) == 2
    elseif field == 'buffsOn' then
        -- BuffsOn 2 = also buff group members' pets (mac:4579)
        if on then _state.buffs.buffGroupPets = tonumber(raw) == 2 end
    elseif field == 'chaseAssist' then
        -- /chase on [who], /chaseon: chase mode (mac:8406-8416)
        if on then
            local wasCamping = mv.returnToCamp
            Control.setMode('chase', { who = who })
            if wasCamping and save then _config.set('General', 'ReturnToCamp', '0') end
        else
            stickOff()
        end
    elseif field == 'returnToCamp' and on then
        -- /camphere on: camp mode with a new camp right here (mac:8417-8432)
        local wasChasing = _state.session.chaseAssist
        Control.setMode('camp', { here = true })
        if wasChasing then
            _config.set('General', 'ChaseAssist', '0')  -- the mac saves this one (mac:8425)
            _config.save()
            printf('\ay>> ChaseAssist Off')
        end
    elseif field == 'autoRezAll' then
        if on then printf('\ayNow Rezing Everyone.')
        else
            _state.heal.corpseRezCheck = 'null'
            printf('\ayNo longer Rezing Everyone.')
        end
    elseif field == 'targetSwitchingOn' and on and not _state.session.iAmMA then
        _state.combat.targetSwitchingOn = false  -- MA only (mac:8460)
    elseif field == 'ranking' then
        -- PullRanking: rebuild the pull list, puller roles only (mac:15019)
        local Pull = require('modules.pull')
        if require('modules.pull.util').isPullerRole(_state.session.role) then
            Pull.setRanking(on)
        else
            Pull.setRanking(false, true)
        end
    elseif field == 'maxRadius' then
        mv.campRadiusExceed = (_state.pull.maxRadius or 0) + 200  -- mac:11277
    elseif field == 'xTarHeal' then
        if (_state.heal.healsOn or 0) == 0 then
            _state.heal.xTarHeal = 0
            printf('\ayTurn on Heals first. Setting XTarget Healing OFF!')  -- mac:11313
        else
            require('modules.healing').setXTargetHealList(_state.heal.xTarHealList)
        end
    end
end

-- Settings whose INI value isn't one state field. Each takes the value and
-- returns the text to save, or nil, error.
local function spellAndCount(spellField, countField, minCount)
    return function(value)
        local m = _state.mez
        local v = tostring(value or '')
        local spell, count = v:match('^(.-)|(%-?%d+)%s*$')
        if not spell then spell, count = v, m[countField] end
        m[spellField] = spell
        m[countField] = math.max(minCount, tonumber(count) or minCount)
        return spell .. '|' .. m[countField]
    end
end

local SPECIAL = {
    -- [Mez] MezSpell / MezAESpell: 'spell|min mobs' (mac:14800)
    mezspell   = spellAndCount('spell', 'singleCount', 2),
    mezaespell = spellAndCount('aeSpell', 'aeCount', 0),
    -- [Pull] PullLevel / PullPause: parsed by the pull module, saved as written
    pulllevel = function(value)
        require('modules.pull').setPullLevel(value)
        return _state.pull.levelSetting
    end,
    pullpause = function(value)
        require('modules.pull').setPullPause(value)
        return _state.pull.pauseSetting
    end,
    -- [Melee] UseMQ2Melee 0 / 1 / 2 (2: MQ2Melee sticks with its INI stickcmd).
    -- A boolean keeps the current 1 / 2 choice.
    usemq2melee = function(value)
        local c = _state.combat
        local n
        if type(value) == 'boolean' then n = value and (c.mq2MeleeMode or 1) or 0
        else n = tonumber(value) end
        if n ~= 0 and n ~= 1 and n ~= 2 then return nil, 'badvalue' end
        if n > 0 then c.mq2MeleeMode = n end
        if not require('modules.combat.settings').setMQ2Melee(_state, n > 0) then return nil, 'noplugin' end
        require('modules.movement').resolveStickHow()  -- MQ2Melee does its own sticking
        return tostring(n)
    end,
}

-- Set a variable: Control.set(name, value, opts) -> ok, msg, info.
--   name   mac variable name, INI key or state field (ReturnToCamp, MezRadius, ...)
--   value  on/off/1/0/number/text as typed, a boolean, or a number
--   opts   save:    also write it to the INI under opts.section (and save)
--          section: INI section to write
--          who:     chase target for ChaseAssist
--          text:    a text setting: value is kept exactly as given
-- On success info = { field, old, value, now, on }: value is what was set, now
-- the field after the side effects (TargetSwitchingOn stays off for a non-MA).
-- GroupWatch settings return { shown }; SPECIAL ones { value, now } (the text saved).
-- On failure msg is 'unknown', 'unsupported', 'badvalue' or 'noplugin' (UseMQ2Melee).
-- 'waithere' stops chasing and returning to camp (mac:8473-8477).
function Control.set(name, value, opts)
    opts = opts or {}
    local lname = tostring(name or ''):lower()
    if lname == '' then return false, 'unknown' end
    if lname == 'waithere' then
        Control.setMode('manual')
        return true, 'waithere', {}
    end
    if UNSUPPORTED[lname] then return false, 'unsupported' end

    -- GroupWatchOn "1|20", GroupWatchPct, GroupWatchCheck "condN" (mac:14569-14587)
    local GroupWatch = require('modules.groupwatch')
    if GroupWatch.isVar(name) then
        local shown = GroupWatch.setVar(name, value)
        if not shown then return false, 'badvalue' end
        if opts.save then GroupWatch.save() end
        return true, 'set', { shown = shown }
    end

    local save = opts.save and opts.section ~= nil
    local special = SPECIAL[lname]
    if special then
        local text, err = special(value)
        if text == nil then return false, err or 'badvalue' end
        if save then
            _config.set(opts.section, name, text)
            _config.save()
        end
        return true, 'set', { value = text, now = text }
    end

    local tbl, field = Control.resolve(name)
    if not tbl then return false, 'unknown' end
    local old = tbl[field]
    local newValue, on = convertValue(old, field, value, opts.text)
    tbl[field] = newValue
    if save then _config.set(opts.section, name, iniText(value, newValue, on)) end
    sideEffects(tbl, field, on, opts.who, save, value)
    if save then _config.save() end
    return true, 'set', { field = field, old = old, value = newValue, now = tbl[field], on = on }
end

-- ─── Entry lists (phase 3c, #363) ────────────────────────────────────────────
-- The GUI's list editors (DPS, Heals, Buffs, conditions, ...) save a whole list
-- here. Each list is an array of INI entries ('null' for an empty slot) plus a
-- size key. After saving, the owning module reloads it into State with its
-- startup loader, so an edit loads exactly what a restart would.
--   name -> { section, key, sizeKey, reload }  (reload nil: read when used)
local function combatList(section)
    return function() require('modules.combat.settings').loadList(_state, section) end
end
local function healList(section)
    return function() require('modules.healing').loadList(section) end
end
local function buffList(name)
    return function() require('modules.buffs').loadList(name) end
end

local ENTRY_LISTS = {
    dps      = { 'DPS',         'DPS',      'DPSSize',      combatList('DPS') },
    burn     = { 'Burn',        'Burn',     'BurnSize',     combatList('Burn') },
    aggro    = { 'Aggro',       'Aggro',    'AggroSize',    combatList('Aggro') },
    ae       = { 'AE',          'AE',       'AESize',       combatList('AE') },
    debuff   = { 'Debuff',      'Debuff',   'DebuffSize',   function() require('modules.debuff').loadList() end },
    heals    = { 'Heals',       'Heals',    'HealsSize',    healList('Heals') },
    cures    = { 'Cures',       'Cures',    'CuresSize',    healList('Cures') },
    buffs    = { 'Buffs',       'Buffs',    'BuffsSize',    buffList('Buffs') },
    petbuffs = { 'Pet',         'PetBuffs', 'PetBuffsSize', buffList('PetBuffs') },
    pettoys  = { 'Pet',         'PetToys',  'PetToysSize',  buffList('PetToys') },
    cond     = { 'KConditions', 'Cond',     'CondSize',     function() require('modules.cond').load() end },
    gom      = { 'GoM',         'GoMSpell', 'GoMSize' },  -- read when used (combat/abilities.lua)
    gems     = { 'Spells',      'Gems' },                 -- read when used (cast.lua)
}

-- Save a whole entry list: Control.setEntries(name, entries, size) -> ok, msg.
--   name     dps, burn, aggro, ae, debuff, heals, cures, buffs, petbuffs,
--            pettoys, cond, gom or gems (any case)
--   entries  the INI array, 'null' for an empty slot
--   size     the list's size key (DPSSize, ...); left as it is when nil
-- On failure msg is 'unknown list' or 'bad entries'.
function Control.setEntries(name, entries, size)
    local list = ENTRY_LISTS[tostring(name or ''):lower()]
    if not list then return false, 'unknown list' end
    if type(entries) ~= 'table' then return false, 'bad entries' end
    local section, key, sizeKey, reload = list[1], list[2], list[3], list[4]
    _config.set(section, key, entries)
    if size and sizeKey then _config.set(section, sizeKey, tostring(size)) end
    _config.save()
    if reload then reload() end
    return true, 'saved'
end

-- ─── Movement mode (phase 2, #362) ───────────────────────────────────────────
-- manual: no chasing, no camp return (the camp spot is kept unless 'clear').
-- camp:   return to camp, no chasing.
-- chase:  chase someone, no camp return.
-- Both flags are set together, so there is never a moment with both or with
-- the old one still on (MQ2Boxr's Manual sends /chaseoff and /camphere off
-- 300 ms apart).

local MODES = { manual = true, camp = true, chase = true }

-- The mode the two flags describe. Pure: also used by the ${KissAssist} TLO.
function Control.modeOf(state)
    if state.session.chaseAssist then return 'chase' end
    if state.movement.returnToCamp then return 'camp' end
    return 'manual'
end

function Control.mode() return Control.modeOf(_state) end

local function hasCamp()
    local mv = _state.movement
    return (mv.campX or 0) ~= 0 or (mv.campY or 0) ~= 0
end

local function myCampSpot()
    return {
        x = mq.TLO.Me.X(), y = mq.TLO.Me.Y(), z = mq.TLO.Me.FloorZ(),
        zone = mq.TLO.Zone.ID(), zoneName = mq.TLO.Zone.ShortName() or '',
    }
end

-- Camp spot: at = { x, y, z, zone, zoneName } (a group CAMP), else right here.
local function setCampSpot(at)
    local mv = _state.movement
    local spot = at or myCampSpot()
    mv.campX        = spot.x or mv.campX
    mv.campY        = spot.y or mv.campY
    mv.campZ        = spot.z or mv.campZ
    mv.campZone     = spot.zone or mv.campZone
    mv.campZoneName = spot.zoneName or mv.campZoneName
    mv.lookForward  = mq.TLO.Me.Heading.DegreesCCW() or 0  -- mac:8424
    _state.pull.mapSet = false  -- repaint the map circles around the new camp
end

-- The group message for a mode; the boxes that get it run the same setMode
-- (modules/comms.lua). Only members of our group/raid are listened to.
local function broadcastMode(mode, opts)
    if not _comms then return end
    if mode == 'camp' then
        if opts.resume then
            _comms.broadcast('CAMPON', {})
        else
            local mv = _state.movement
            local spot = opts.others and myCampSpot()
                or { x = mv.campX, y = mv.campY, z = mv.campZ, zone = mv.campZone, zoneName = mv.campZoneName }
            _comms.broadcast('CAMP', spot)
        end
    elseif mode == 'chase' then
        _comms.broadcast('CHASE', { who = opts.who or _state.movement.whoToChase })
    elseif opts.clear then
        _comms.broadcast('CAMPOFF', {})
    else
        _comms.broadcast('STAY', {})
    end
end

-- Set the movement mode: Control.setMode(mode, opts) -> ok, msg, info.
--   mode   'manual' | 'camp' | 'chase'
--   opts   who:    chase target (chase; kept as is when not given)
--          here:   camp: a new camp at this spot (the default)
--          resume: camp: back to the kept camp
--          at:     camp: a new camp at { x, y, z, zone, zoneName } (a group CAMP)
--          clear:  manual: also clear the camp spot
--          group:  this toon and the group/raid's kissassist-lua boxes
--          others: only the group/raid's boxes, not this toon (the mac's
--                  /stayhere and /chaseme)
-- On failure msg is 'badmode', 'nocamp' (resume with no camp) or 'nowho'.
function Control.setMode(mode, opts)
    opts = opts or {}
    mode = tostring(mode or ''):lower()
    if not MODES[mode] then return false, 'badmode' end
    local mv, ses = _state.movement, _state.session
    local who = opts.who
    if who == 'null' then who = nil end
    if mode == 'chase' and opts.others and (who or '') == '' then return false, 'nowho' end

    if not opts.others then
        if mode == 'camp' then
            if opts.at then
                setCampSpot(opts.at)
            elseif opts.resume then
                if not hasCamp() then return false, 'nocamp' end
            else
                setCampSpot()
                printf('\ay>> New camp set %.1f, %.1f', mv.campY or 0, mv.campX or 0)
            end
            if ses.chaseAssist then stickOff() end
            ses.chaseAssist = false
            mv.returnToCamp = true
        elseif mode == 'chase' then
            if who and who ~= '' and who ~= mv.whoToChase then
                mv.whoToChase = who
                printf('\ayI Will Now Chase %s', who)
            end
            mv.returnToCamp = false
            ses.chaseAssist = true
            if (mq.TLO.Me.Pet.ID() or 0) > 0 and (mq.TLO.Me.Pet.Stance() or ''):upper() ~= 'FOLLOW' then
                mq.cmd('/pet follow')
            end
        else
            ses.chaseAssist = false
            mv.returnToCamp = false
            stickOff()
            if opts.clear then
                mv.campX, mv.campY, mv.campZ, mv.campZoneName = 0, 0, 0, ''
            end
        end
    end

    if opts.group or opts.others then broadcastMode(mode, opts) end
    return true, 'set', { mode = mode }
end

-- ─── /kactl ──────────────────────────────────────────────────────────────────
-- /kactl <verb> [args]: the strict, script-safe way in (#360). Every value is
-- explicit (on|off|toggle, never "no value means off"), nothing goes to the
-- group unless a verb is told 'group' / 'others', nothing is saved unless it is
-- told 'save', and it prints nothing unless it fails or 'verbose' is given.
-- ${KissAssist.LastResult} holds the outcome of the last /kactl: 'ok' or
-- 'error: <why>'.
--
-- Verbs live where their code is: this file registers mode, set, pause and stop;
-- modules/binds.lua registers target, charm, medley, list and test;
-- modules/ui.lua registers ui. Control.verb(name, usage, run) adds one;
-- run(words) gets the words after the verb ('verbose' removed) and returns
-- ok, msg (msg: what happened, or why it failed).

local VERBS = {}

Control.lastResult = ''

function Control.verb(name, usage, run)
    VERBS[name] = { usage = usage, run = run }
end

-- on | off | toggle -> boolean (toggle flips current). nil, error otherwise.
function Control.onOff(word, current)
    local w = tostring(word or ''):lower()
    if w == 'on' then return true end
    if w == 'off' then return false end
    if w == 'toggle' then return not current end
    return nil, 'expects on, off or toggle'
end

-- Take a trailing flag word (save, group, ...) out of words. Returns true if found.
function Control.takeFlag(words, flag)
    for i = #words, 1, -1 do
        if tostring(words[i]):lower() == flag then
            table.remove(words, i)
            return true
        end
    end
    return false
end

-- The INI section and key spelling a setting is saved under, from the default
-- config (modules/config.lua). nil if unknown or in more than one section.
function Control.sectionOf(name)
    if not (_config and _config.defaultCfg) then return nil end
    local lname = tostring(name or ''):lower()
    local foundSection, foundKey
    for section, keys in pairs(_config.defaultCfg()) do
        if type(keys) == 'table' then
            for key, value in pairs(keys) do
                if type(key) == 'string' and type(value) ~= 'table' and key:lower() == lname then
                    if foundSection then return nil end  -- ambiguous
                    foundSection, foundKey = section, key
                end
            end
        end
    end
    return foundSection, foundKey
end

-- Run a verb without printing or touching LastResult (the GUI's way in).
function Control.run(verb, words)
    local v = VERBS[verb]
    if not v then return false, 'unknown verb' end
    return v.run(words or {})
end

-- Queue a verb for the main loop (Control.runDeferred). The GUI's way in for
-- its buttons: a verb may wait (combatReset uses mq.delay), and that can't run
-- inside an ImGui frame. A failure is printed like a /kactl one.
local _deferred = {}

function Control.defer(verb, words)
    _deferred[#_deferred + 1] = { verb = verb, words = words or {} }
end

-- Run the queued verbs, in order. Called once per main-loop pass.
function Control.runDeferred()
    if #_deferred == 0 then return end
    local queue = _deferred
    _deferred = {}
    for _, d in ipairs(queue) do
        local ok, msg = Control.run(d.verb, d.words)
        if not ok then printf('\ay/kactl %s: %s', d.verb, tostring(msg)) end
    end
end

-- /kactl entry point. words: the command's arguments. Returns ok, msg.
function Control.command(words)
    local verb = tostring(words[1] or ''):lower()
    local v = VERBS[verb]
    if not v then
        local names = {}
        for name in pairs(VERBS) do names[#names + 1] = name end
        table.sort(names)
        Control.lastResult = 'error: unknown verb'
        printf('\ay/kactl: unknown verb \at%s\ay. Verbs: %s', words[1] or '', table.concat(names, ', '))
        return false, 'unknown verb'
    end
    local rest, verbose = {}, false
    for i = 2, #words do
        local w = words[i]
        if w ~= nil and w ~= '' then
            if tostring(w):lower() == 'verbose' then verbose = true else rest[#rest + 1] = w end
        end
    end
    local ok, msg = v.run(rest)
    if ok then
        Control.lastResult = 'ok'
        if verbose then printf('\ay/kactl %s: %s', verb, tostring(msg or 'ok')) end
    else
        Control.lastResult = 'error: ' .. tostring(msg)
        printf('\ay/kactl %s: %s. Usage: /kactl %s', verb, tostring(msg), v.usage)
    end
    return ok, msg
end

-- ── mode ─────────────────────────────────────────────────────────────────────
--   /kactl mode manual [clear] [group|others]
--   /kactl mode camp [here|resume] [group|others]
--   /kactl mode chase [<name>|me] [group|others]

-- Parse the words after 'mode'. Returns mode, opts, verbose or nil, error.
function Control.parseMode(words)
    local mode = tostring(words[1] or ''):lower()
    if not MODES[mode] then return nil, 'mode must be manual, camp or chase' end
    local opts, verbose = {}, false
    for i = 2, #words do
        local w  = tostring(words[i])
        local lw = w:lower()
        if lw == '' then
            goto continue  -- empty argument
        end
        if lw == 'verbose' then
            verbose = true
        elseif lw == 'group' or lw == 'others' then
            if opts.group or opts.others then return nil, 'use group or others, not both' end
            opts[lw] = true
        elseif lw == 'here' or lw == 'resume' then
            if mode ~= 'camp' then return nil, lw .. ' only goes with camp' end
            if opts.here or opts.resume then return nil, 'use here or resume, not both' end
            opts[lw] = true
        elseif lw == 'clear' then
            if mode ~= 'manual' then return nil, 'clear only goes with manual' end
            opts.clear = true
        elseif mode == 'chase' and not opts.who then
            opts.who = (lw == 'me') and (mq.TLO.Me.CleanName() or '') or w
        else
            return nil, 'unexpected word: ' .. w
        end
        ::continue::
    end
    return mode, opts, verbose
end

local MODE_ERRORS = {
    nocamp = 'no camp to resume (set one with /kactl mode camp here)',
    nowho  = 'chase with others needs a name (or me)',
}

Control.verb('mode', 'mode manual [clear] | camp [here|resume] | chase [<name>|me]  [group|others]', function(words)
    local mode, opts = Control.parseMode(words)
    if not mode then return false, opts end
    local ok, msg = Control.setMode(mode, opts)
    if not ok then return false, MODE_ERRORS[msg] or msg end
    return true, 'mode ' .. Control.mode()
end)

-- ── set ──────────────────────────────────────────────────────────────────────
--   /kactl set <name> <value>|toggle [save]
-- Any setting /togglevariable and /changevarint know (mac names, INI keys).
-- 'save' writes it to the config under the setting's INI section.

local SET_ERRORS = {
    unknown     = 'unknown setting',
    unsupported = 'not supported in the Lua port',
    badvalue    = 'bad value',
    noplugin    = 'MQ2Melee plugin is not loaded',
}

Control.verb('set', 'set <name> <value>|toggle [save]', function(words)
    local save = Control.takeFlag(words, 'save')
    local name, value = words[1], words[2]
    if not name or not value then return false, 'needs a name and a value' end
    if #words > 2 then return false, 'unexpected word: ' .. tostring(words[3]) end
    local tbl, field = Control.resolve(name)
    -- on/off as booleans, so 'save' writes 1/0 (or the field's number, e.g. 62)
    -- rather than the word; /changevarint keeps the mac's write-as-typed.
    local lvalue = tostring(value):lower()
    if lvalue == 'on' then value = true elseif lvalue == 'off' then value = false end
    if lvalue == 'toggle' then
        if not tbl then return false, SET_ERRORS.unknown end
        local cur = tbl[field]
        if type(cur) == 'boolean' then value = not cur
        elseif type(cur) == 'number' then value = cur == 0
        else return false, 'toggle only works for on/off settings' end
    end
    local opts = {}
    if save then
        local section, key = Control.sectionOf(name)
        if not section then return false, 'no INI section known for ' .. tostring(name) .. ' (use /changevarint)' end
        opts.save, opts.section, name = true, section, key
    end
    local ok, msg, info = Control.set(name, value, opts)
    if not ok then return false, SET_ERRORS[msg] or msg end
    if info.shown then return true, string.format('%s = %s', name, info.shown) end
    return true, string.format('%s = %s', name, tostring(info.now))
end)

-- ── pause, stop ──────────────────────────────────────────────────────────────
--   /kactl pause on|off|toggle   soft pause (modules/pause.lua, #353)
--   /kactl stop                  end the script

Control.verb('pause', 'pause on|off|toggle', function(words)
    if #words ~= 1 then return false, 'expects on, off or toggle' end
    local Pause = require('modules.pause')
    local on, err = Control.onOff(words[1], Pause.isPaused())
    if on == nil then return false, err end
    Pause.set(on)
    return true, on and 'paused' or 'running'
end)

Control.verb('stop', 'stop', function(words)
    if #words > 0 then return false, 'takes no arguments' end
    printf('\arKissAssist stopping...\ax')
    _state.terminate = true
    return true, 'stopping'
end)

return Control
