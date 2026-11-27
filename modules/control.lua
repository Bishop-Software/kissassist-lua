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
-- Returns the new value and on/off.
local function convertValue(cur, field, arg)
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
local function sideEffects(field, on, who, save, raw)
    local mv = _state.movement
    if field == 'dpsOn' then
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

-- Set a variable: Control.set(name, value, opts) -> ok, msg, info.
--   name   mac variable name, INI key or state field (ReturnToCamp, MezRadius, ...)
--   value  on/off/1/0/number/text as typed, a boolean, or a number
--   opts   save:    also write it to the INI under opts.section (and save)
--          section: INI section to write
--          who:     chase target for ChaseAssist
-- On success info = { field, old, value, now, on }: value is what was set, now
-- the field after the side effects (TargetSwitchingOn stays off for a non-MA).
-- GroupWatch settings return { shown }.
-- On failure msg is 'unknown', 'unsupported' or 'badvalue'.
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

    local tbl, field = Control.resolve(name)
    if not tbl then return false, 'unknown' end
    local old = tbl[field]
    local newValue, on = convertValue(old, field, value)
    tbl[field] = newValue
    local save = opts.save and opts.section ~= nil
    if save then _config.set(opts.section, name, iniText(value, newValue, on)) end
    sideEffects(field, on, opts.who, save, value)
    if save then _config.save() end
    return true, 'set', { field = field, old = old, value = newValue, now = tbl[field], on = on }
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
-- /kactl <verb> [args]: the strict, script-safe way in. Phase 2 has one verb:
--   /kactl mode manual [clear] [group|others]
--   /kactl mode camp [here|resume] [group|others]
--   /kactl mode chase [<name>|me] [group|others]
-- Quiet unless 'verbose' is given or it fails.

local MODE_USAGE = '/kactl mode manual [clear] | camp [here|resume] | chase [<name>|me]  [group|others] [verbose]'

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

-- /kactl entry point. words: the command's arguments. Returns ok, msg.
function Control.command(words)
    local verb = tostring(words[1] or ''):lower()
    if verb ~= 'mode' then
        printf('\ay/kactl: unknown verb \at%s\ay. Usage: %s', words[1] or '', MODE_USAGE)
        return false, 'badverb'
    end
    local rest = {}
    for i = 2, #words do rest[#rest + 1] = words[i] end
    local mode, opts, verbose = Control.parseMode(rest)
    if not mode then
        printf('\ay/kactl mode: %s. Usage: %s', opts, MODE_USAGE)
        return false, opts
    end
    local ok, msg = Control.setMode(mode, opts)
    if not ok then
        printf('\ay/kactl mode: %s', MODE_ERRORS[msg] or msg)
    elseif verbose then
        printf('\ay/kactl: mode %s', Control.mode())
    end
    return ok, msg
end

return Control
