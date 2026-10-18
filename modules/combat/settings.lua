-- combat/settings.lua — loads combat settings from the INI into State at startup.
-- Body of the former Combat.init (mirrors Bind_Settings DPS/Melee/Burn/General
-- sections, kissassist.mac:14750). Called once from Combat.init.

local mq     = require('mq')
local Config = require('modules.config')

local Settings = {}

function Settings.load(state, utils)
    local _state = state

    -- Engagement toggles; DPSOn==2 enables out-of-combat DPS rotation (mac DPSOn)
    local dpsOnVal            = tonumber(Config.get('DPS', 'DPSOn', '1')) or 1
    _state.combat.dpsOn       = dpsOnVal >= 1
    _state.combat.dpsOnOoc    = dpsOnVal == 2
    _state.combat.dpsSkip     = tonumber(Config.get('DPS', 'DPSSkip',     '20')) or 20
    _state.combat.dpsInterval = tonumber(Config.get('DPS', 'DPSInterval', '2'))  or 2
    _state.combat.meleeOn           = Config.get('Melee', 'MeleeOn',           '1') == '1'
    _state.combat.useMQ2Melee       = Config.get('Melee', 'UseMQ2Melee',       '0') == '1'
    -- MQ2Melee must actually be loaded, otherwise nothing turns auto-attack on (mac:16348-16366).
    -- Unlike the mac we don't load it ourselves: MQ2Melee skips its casting checks
    -- for bards and can fire abilities mid-song; loading it coincided with broken
    -- bard songs in testing.
    if _state.combat.useMQ2Melee then
        if mq.TLO.Plugin('MQ2Melee').IsLoaded() then
            mq.cmd('/squelch /melee aggro=0')
            mq.cmd('/squelch /melee melee=1')
            mq.cmd('/squelch /melee petassist=0')
            mq.cmd('/squelch /melee on')
            mq.cmd('/squelch /melee stickmode=0')
        else
            printf('\ayMQ2Melee plugin is not loaded. Setting UseMQ2Melee off for this session.')
            _state.combat.useMQ2Melee = false
        end
    end
    _state.combat.targetSwitchingOn = Config.get('Melee', 'TargetSwitchingOn', '0') == '1'
    _state.combat.manualTargetMode  = Config.get('Melee', 'ManualTargetMode',  '0') == '1'

    -- Manual role: disable all automation at startup (mac:8827-8834)
    if _state.session.role == 'manual' then
        if Config.get('Melee', 'UseMQ2Melee', '0') == '1' then
            mq.cmd('/squelch /melee aggro=0')
        end
        _state.combat.meleeOn        = false
        _state.combat.dpsOn          = false
        _state.combat.dpsOnOoc       = false
        _state.session.chaseAssist   = false
        _state.movement.returnToCamp = false
        _state.buffs.buffsOn         = false
    end

    -- Assist-at percent: prefer INI; fall back to CLI-parsed session value (default 95)
    _state.combat.assistAt    = tonumber(Config.get('Melee', 'AssistAt',
                                    tostring(_state.session.assistAt)))
                                or _state.session.assistAt

    _state.combat.meleeDistance = tonumber(Config.get('Melee', 'MeleeDistance', '30')) or 30
    _state.combat.autoFireOn    = tonumber(Config.get('Melee', 'AutoFireOn',    '0'))  or 0
    _state.misc.autoHide        = Config.get('General', 'AutoHide', '0') == '1'

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
    -- |mash-tagged entries go to mashArray (fired every tick via mashButtons).
    -- |ambush-tagged entries go to beforeArray (fired pre-combat via beforeAttack).
    -- |weave-tagged entries are skipped (weave not yet ported).
    -- Raw strings are used for tag detection so |cond suffixes are preserved.
    local rawDps = Config.get('DPS', 'DPS', nil)
    if type(rawDps) == 'table' then
        local mashIdx   = 1
        local ambushIdx = 1
        local parsed    = Config.parseCondArray(rawDps)
        for i, rawEntry in ipairs(rawDps) do
            if not rawEntry or rawEntry == '' then goto next_dps_entry end
            if rawEntry:find('|mash', 1, true) then
                _state.arrays.mashArray[mashIdx] = rawEntry:gsub('|mash', '', 1)
                mashIdx = mashIdx + 1
            elseif rawEntry:find('|ambush', 1, true) then
                _state.arrays.beforeArray[ambushIdx] = rawEntry:gsub('|ambush', '', 1)
                ambushIdx = ambushIdx + 1
            elseif not rawEntry:find('|weave', 1, true) then
                local slot = parsed[i]
                if slot and slot.name and slot.name ~= '' then
                    _state.combat.dpsArray[#_state.combat.dpsArray + 1] = slot
                end
            end
            ::next_dps_entry::
        end
    end

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
    _state.pet.assistAt            = tonumber(Config.get('Pet', 'PetAssistAt',       '100')) or 100
    _state.pet.attackRange         = tonumber(Config.get('Pet', 'PetAttackDistance', '115')) or 115
    _state.pet.combatOn            = Config.get('Pet', 'PetCombatOn',                '1') == '1'
    _state.combat.petTargetSwitch  = Config.get('General', 'PetTargetSwitch',        '0') == '1'

    -- Named-mob watch list — zone-scoped MobsToBurn from KissAssist_Info.ini (shared across chars).
    local _infoFile = _state.session.infoFileName or ''
    local _zone     = _state.session.zoneName     or ''
    local _rawBurn  = (_infoFile ~= '' and _zone ~= '')
        and (mq.TLO.Ini(_infoFile, _zone, 'MobsToBurn')() or '') or ''
    _state.combat.namedWatchList = {}
    for entry in (_rawBurn .. ','):gmatch('([^,]+),') do
        local e = entry:match('^%s*(.-)%s*$')
        if e ~= '' and e ~= 'null' then
            _state.combat.namedWatchList[#_state.combat.namedWatchList + 1] = e:lower()
        end
    end

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
