-- modules/control.lua — the one place that changes a kissassist-lua setting.
-- /togglevariable, /changevarint and the GUI's checkboxes and number inputs all
-- call Control.set, so a setting gets the same side effects however it changes.
-- (kactl control API design, phase 1; /kactl itself comes in a later phase.)
--
-- Control.set never prints its own result: it returns ok, msg, info and the
-- caller decides what to show. The side effects keep the mac's messages
-- ("New camp set", "I Will Now Chase ...").
local mq = require('mq')

local Control = {}

local _state, _config

function Control.init(state, config)
    _state  = state
    _config = config
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
        if on then
            if who and who ~= '' and who ~= 'null' and who ~= mv.whoToChase then
                mv.whoToChase = who
                printf('\ayI Will Now Chase %s', who)
            end
            if mv.returnToCamp then
                mv.returnToCamp = false
                if save then _config.set('General', 'ReturnToCamp', '0') end
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
        _state.pull.mapSet = false
        if _state.session.chaseAssist then
            _state.session.chaseAssist = false
            _config.set('General', 'ChaseAssist', '0')  -- the mac saves this one (mac:8425)
            _config.save()
            stickOff()
            printf('\ay>> ChaseAssist Off')
        end
        printf('\ay>> New camp set %.1f, %.1f', mv.campY or 0, mv.campX or 0)
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
        _state.session.chaseAssist   = false
        _state.movement.returnToCamp = false
        stickOff()
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

return Control
