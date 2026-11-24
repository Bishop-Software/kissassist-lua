-- combat/settings.lua — loads combat settings from the INI into State at startup.
-- Body of the former Combat.init (mirrors Bind_Settings DPS/Melee/Burn/General
-- sections, kissassist.mac:14750). Called once from Combat.init.

local mq     = require('mq')
local Config = require('modules.config')
local Utils  = require('modules.utils')

local Settings = {}

-- Remove the first case-insensitive occurrence of tag ('|mash' etc.) from raw.
-- Returns nil when the tag isn't present. The mac matches tags with ${String.Find[]},
-- which ignores case (mac:1666), so 'Foo|99|Weave' is a weave entry.
local function stripTag(raw, tag)
    local p = raw:lower():find(tag, 1, true)
    if not p then return nil end
    return raw:sub(1, p - 1) .. raw:sub(p + #tag)
end

local function resetArr(arr)
    for k = 1, #arr do arr[k] = 'null' end
end

-- Split the raw [DPS] entries into the rotation and the tag arrays (mac Bind_Settings):
--   |mash   -> arrays.mashArray   (fired every pass via mashButtons)
--   |ambush -> arrays.beforeArray (fired pre-combat via beforeAttack)
--   |weave  -> arrays.weaveArray  (fired during the spell global cooldown via castWeave)
--   rest    -> combat.dpsArray    (CombatCast rotation)
-- Tag arrays keep the entry text minus the tag, |cond suffix included. Called at load
-- and by the DPS editor, so edits keep the arrays in sync.
function Settings.splitDps(state, rawDps)
    local arrays = state.arrays
    state.combat.dpsArray = {}
    resetArr(arrays.mashArray); resetArr(arrays.beforeArray); resetArr(arrays.weaveArray)
    if type(rawDps) ~= 'table' then return end
    local mashIdx, ambushIdx, weaveIdx = 1, 1, 1
    local parsed = Config.parseCondArray(rawDps)
    for i, rawEntry in ipairs(rawDps) do
        if not rawEntry or rawEntry == '' or rawEntry == 'null' then goto next_dps_entry end
        local stripped = stripTag(rawEntry, '|mash')
        if stripped then
            arrays.mashArray[mashIdx] = stripped
            mashIdx = mashIdx + 1
            goto next_dps_entry
        end
        stripped = stripTag(rawEntry, '|ambush')
        if stripped then
            arrays.beforeArray[ambushIdx] = stripped
            ambushIdx = ambushIdx + 1
            goto next_dps_entry
        end
        stripped = stripTag(rawEntry, '|weave')
        if stripped then
            arrays.weaveArray[weaveIdx] = stripped
            weaveIdx = weaveIdx + 1
            goto next_dps_entry
        end
        do
            local slot = parsed[i]
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                state.combat.dpsArray[#state.combat.dpsArray + 1] = slot
            end
        end
        ::next_dps_entry::
    end
end

-- Named-mob watch list: this zone's MobsToBurn from KissAssist_Info.ini (shared
-- across characters). Called at startup and again after zoning.
function Settings.loadNamedList(state)
    local infoFile = state.session.infoFileName or ''
    local zone     = state.session.zoneName     or ''
    local rawBurn  = Utils.zoneIniGet(infoFile, zone, 'MobsToBurn') or ''
    state.combat.namedWatchList = {}
    for entry in (rawBurn .. ','):gmatch('([^,]+),') do
        local e = entry:match('^%s*(.-)%s*$')
        if e ~= '' and e:lower() ~= 'null' then
            state.combat.namedWatchList[#state.combat.namedWatchList + 1] = e:lower()
        end
    end
end

-- Turn MQ2Melee handling on or off for this session. Returns false (and leaves
-- it off) when enabling but the plugin isn't loaded: with UseMQ2Melee on,
-- checkStick only sends /killthis, so without the plugin nothing attacks.
-- Unlike the mac (mac:16348-16366) we don't load it ourselves: MQ2Melee skips
-- its casting checks for bards and can fire abilities mid-song; loading it
-- coincided with broken bard songs in testing. With the setting off we also
-- don't unload it (mac:16369-16371): melee=0 + off is enough to keep it out of
-- the way, and the Combat tab switch can turn it back on mid-session.
-- combat.mq2MeleeMode (UseMQ2Melee 1 or 2) picks MQ2Melee's stickmode: 1 = its
-- own automatic sticking (stickmode=0), 2 = the stickcmd from MQ2Melee's INI
-- (stickmode=1) (mac:16356-16361).
function Settings.setMQ2Melee(state, on)
    if on then
        if not mq.TLO.Plugin('MQ2Melee').IsLoaded() then
            state.combat.useMQ2Melee = false
            return false
        end
        mq.cmd('/squelch /melee aggro=0')
        mq.cmd('/squelch /melee melee=1')
        mq.cmd('/squelch /melee petassist=0')
        mq.cmd('/squelch /melee on')
        mq.cmdf('/squelch /melee stickmode=%d', state.combat.mq2MeleeMode == 2 and 1 or 0)
    elseif mq.TLO.Plugin('MQ2Melee').IsLoaded() then
        -- Stop the plugin attacking/sticking on its own so it doesn't fight
        -- our /attack + /stick handling.
        mq.cmd('/squelch /melee melee=0')
        mq.cmd('/squelch /melee off')
    end
    state.combat.useMQ2Melee = on
    return true
end

function Settings.load(state, utils)
    local _state = state

    -- DPSOn: 0 off; 1 on, each entry from its HP%; 2 on at any HP and wait out the
    -- global spell cooldown instead of skipping a gem spell (mac:1727, 1750)
    local dpsOnVal            = tonumber(Config.get('DPS', 'DPSOn', '0')) or 0
    _state.combat.dpsOn       = dpsOnVal >= 1
    _state.combat.dpsOnOoc    = dpsOnVal == 2
    _state.combat.dpsSkip     = tonumber(Config.get('DPS', 'DPSSkip',     '20')) or 20
    _state.combat.dpsInterval = tonumber(Config.get('DPS', 'DPSInterval', '2'))  or 2
    _state.combat.meleeOn           = Config.get('Melee', 'MeleeOn',           '1') == '1'
    -- UseMQ2Melee: 0 off, 1 on (MQ2Melee sticks), 2 on with MQ2Melee's INI stickcmd (mac:16348-16374)
    local mq2MeleeVal = tonumber(Config.get('Melee', 'UseMQ2Melee', '0')) or 0
    _state.combat.useMQ2Melee  = false
    _state.combat.mq2MeleeMode = mq2MeleeVal == 2 and 2 or 1
    if mq2MeleeVal >= 1 then
        if not Settings.setMQ2Melee(_state, true) then
            printf('\ayMQ2Melee plugin is not loaded. Setting UseMQ2Melee off for this session.')
        end
    elseif mq.TLO.Plugin('MQ2Melee').IsLoaded() then
        -- Off but loaded: stop it attacking/sticking on its own settings.
        Settings.setMQ2Melee(_state, false)
    end
    _state.combat.targetSwitchingOn = Config.get('Melee', 'TargetSwitchingOn', '0') == '1'
    _state.combat.manualTargetMode  = Config.get('Melee', 'ManualTargetMode',  '0') == '1'

    -- The manual role's "everything off" setup is in modules/roles.lua (checkRoles).

    -- Assist-at percent: prefer INI; fall back to CLI-parsed session value (default 95)
    _state.combat.assistAt    = tonumber(Config.get('Melee', 'AssistAt',
                                    tostring(_state.session.assistAt)))
                                or _state.session.assistAt

    _state.combat.meleeDistance = tonumber(Config.get('Melee', 'MeleeDistance', '75')) or 75
    _state.combat.autoFireOn    = tonumber(Config.get('Melee', 'AutoFireOn',    '0'))  or 0
    -- AutoHide lives in [Melee] (mac:14689); older UI builds saved it to [General].
    -- Defaults on for rogues, as in the mac.
    local hideDefault           = mq.TLO.Me.Class.ShortName() == 'ROG' and '1' or '0'
    _state.misc.autoHide        = Config.get('Melee', 'AutoHide', hideDefault) == '1'
                                  or Config.get('General', 'AutoHide', '0') == '1'

    -- SpawnMaster mode: use Alert[5] instead of Spawn.Named for named-mob detection.
    _state.session.useSpawnMaster = Config.get('General', 'UseSpawnMaster', '0') == '1'

    -- GroupEscape: WIZ/DRU only — auto-evac group when MA dies mid-combat (mac:14611).
    local cls = (mq.TLO.Me.Class.ShortName() or ''):lower()
    if cls == 'wiz' or cls == 'dru' then
        _state.session.groupEscapeOn = tonumber(Config.get('General', 'GroupEscapeOn', '0')) or 0
    end

    -- Burn flags
    _state.combat.burnOn        = (Config.get('Burn', 'BurnOn', '1') ~= '0')
    _state.combat.burnAllNamed  = tonumber(Config.get('Burn',    'BurnAllNamed',  '0')) or 0
    _state.combat.autoBurnTimer   = tonumber(Config.get('General', 'AutoBurnTimer',   '0')) or 0
    _state.combat.losBeforeCombat = Config.get('General', 'LOSBeforeCombat', '0') == '1'

    -- DPS array: state.debuff.* is now loaded by Debuff.init()
    Settings.splitDps(_state, Config.get('DPS', 'DPS', nil))

    -- Burn spell/disc array
    local burnArr = Config.get('Burn', 'Burn', nil)
    if type(burnArr) == 'table' then
        for _, v in ipairs(burnArr) do
            if v and v ~= '' then
                _state.combat.burnArray[#_state.combat.burnArray + 1] = v
            end
        end
    end

    -- Aggro management array — parsed into { name, condNo } slots.
    _state.combat.aggroOn = Config.get('Aggro', 'AggroOn', '0') == '1'
    local rawAggro = Config.get('Aggro', 'Aggro', nil)
    if type(rawAggro) == 'table' then
        for _, slot in ipairs(Config.parseCondArray(rawAggro)) do
            if slot and slot.name and slot.name ~= '' then
                _state.combat.aggroArray[#_state.combat.aggroArray + 1] = slot
            end
        end
    end

    -- AE rotation array
    _state.combat.aeOn     = Config.get('AE', 'AEOn',     '0') == '1'
    _state.combat.aeRadius = tonumber(Config.get('AE', 'AERadius', '50')) or 50
    local rawAE = Config.get('AE', 'AE', nil)
    if type(rawAE) == 'table' then
        for i, v in ipairs(rawAE) do
            if v and v ~= '' then _state.combat.aeArray[i] = v end
        end
    end

    -- Pet combat config
    _state.pet.assistAt            = tonumber(Config.get('Pet', 'PetAssistAt',       '95'))  or 95
    _state.pet.attackRange         = tonumber(Config.get('Pet', 'PetAttackDistance', '115')) or 115
    _state.pet.combatOn            = Config.get('Pet', 'PetCombatOn',                '1') == '1'
    _state.combat.petTargetSwitch  = Config.get('General', 'PetTargetSwitch',        '0') == '1'

    Settings.loadNamedList(_state)

    utils.debug('combat', 'Combat.init: dpsOn=%s meleeOn=%s assistAt=%d meleeDistance=%d dps#=%d burn#=%d debuffCount=%d aggroOn=%s campRadius=%d',
        tostring(_state.combat.dpsOn),
        tostring(_state.combat.meleeOn),
        _state.combat.assistAt,
        _state.combat.meleeDistance,
        #_state.combat.dpsArray,
        #_state.combat.burnArray,
        _state.debuff.count,
        tostring(_state.combat.aggroOn),
        _state.movement.campRadius)

    -- XTSlot/XTSlot2: first two Auto Hater XTarget slots (mac:16211-16239). mobRadar's
    -- XTSlot post-check depends on this to see haters beyond MeleeDistance.
    _state.combat.xTSlot, _state.combat.xTSlot2 = 0, 0
    for n = 1, _state.combat.xSlotTotal do
        if (mq.TLO.Me.XTarget(n).TargetType() or '') == 'Auto Hater' then
            if _state.combat.xTSlot == 0 then
                _state.combat.xTSlot = n
            elseif _state.combat.xTSlot2 == 0 then
                _state.combat.xTSlot2 = n
                break
            end
        end
    end
    if _state.combat.xTSlot == 0 then
        printf('\arYou need at least 1 slot in your Extended Target Window set to Auto Hater.')
    elseif _state.pull.chainPull > 0 and _state.combat.xTSlot2 == 0 then
        printf('\arChain pulling needs at least 2 Extended Target slots set to Auto Hater.')
    end
end

return Settings
