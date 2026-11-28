-- tests/unit/test_control.lua
-- modules/control.lua (kactl design, phase 1): Control.set is the one setter
-- behind /togglevariable, /changevarint and the GUI. Checks name resolution for
-- every key the GUI sets, value conversion, saving, the side effects, and that
-- the two mac commands still behave as before.
local M = {}

local function deepCopy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end

-- Fake Config: records set/save calls.
local function fakeConfig()
    local cfg = { sets = {}, saves = 0 }
    function cfg.set(section, key, value) cfg.sets[#cfg.sets + 1] = { section, key, value } end
    function cfg.save() cfg.saves = cfg.saves + 1 end
    function cfg.get() return nil end
    function cfg.last() local s = cfg.sets[#cfg.sets]; return s and (s[1] .. '/' .. s[2] .. '=' .. tostring(s[3])) end
    function cfg.reset() cfg.sets = {}; cfg.saves = 0 end
    return cfg
end

function M.run(TH, MockMQ)
    TH.setSuite('test_control')
    MockMQ.reset()

    package.loaded['modules.state'] = nil
    local state = deepCopy(require('modules.state'))
    package.loaded['modules.state'] = nil
    local cfg = fakeConfig()

    -- GroupWatch has its own suite; a stub checks Control routes to it.
    local savedGW = package.loaded['modules.groupwatch']
    local gw = { saved = 0 }
    function gw.isVar(n) return tostring(n):lower() == 'groupwatchon' end
    function gw.setVar(_, v) if v == 'bad' then return nil end return '1|' .. v end
    function gw.save() gw.saved = gw.saved + 1 end
    package.loaded['modules.groupwatch'] = gw

    package.loaded['modules.control'] = nil
    local Control = require('modules.control')
    Control.init(state, cfg)

    -- ── resolve: every key the GUI sets lands on the field it wrote before ──
    local GUI_KEYS = {
        { 'MezRadius', 'mez', 'radius' },           { 'MezStopHPs', 'mez', 'stopHPs' },
        { 'MezMinLevel', 'mez', 'minLevel' },       { 'MezMaxLevel', 'mez', 'maxLevel' },
        { 'CharmRadius', 'charm', 'radius' },       { 'CharmMinLevel', 'charm', 'minLevel' },
        { 'CharmMaxLevel', 'charm', 'maxLevel' },   { 'CharmOn', 'charm', 'on' },
        { 'CharmKeep', 'charm', 'keep' },           { 'AssistAt', 'combat', 'assistAt' },
        { 'MeleeDistance', 'combat', 'meleeDistance' }, { 'DPSSkip', 'combat', 'dpsSkip' },
        { 'DPSInterval', 'combat', 'dpsInterval' }, { 'AERadius', 'combat', 'aeRadius' },
        { 'MeleeOn', 'combat', 'meleeOn' },         { 'TargetSwitchingOn', 'combat', 'targetSwitchingOn' },
        { 'AutoFireOn', 'combat', 'autoFireOn' },   { 'AutoHide', 'misc', 'autoHide' },
        { 'AggroOn', 'combat', 'aggroOn' },         { 'BurnOn', 'combat', 'burnOn' },
        { 'UseTribute', 'combat', 'useTribute' },   { 'AEOn', 'combat', 'aeOn' },
        { 'LOSBeforeCombat', 'combat', 'losBeforeCombat' },
        { 'HealsOn', 'heal', 'healsOn' },           { 'RezGuildFellowship', 'heal', 'rezGuildFellowship' },
        { 'MaxRadius', 'pull', 'maxRadius' },       { 'MaxZRange', 'pull', 'maxZRange' },
        { 'PullRadiusToUse', 'pull', 'radiusToUse' }, { 'ChainPullHP', 'pull', 'chainPullHP' },
        { 'PullWait', 'pull', 'pullWait' },         { 'ChainPull', 'pull', 'chainPull' },
        { 'PullOnReturn', 'pull', 'pullOnReturn' }, { 'PullLocsOn', 'pull', 'pullLocsOn' },
        { 'PullMeleeStick', 'pull', 'meleeStick' }, { 'PullRoleToggle', 'pull', 'roleToggle' },
        { 'PullTwistOn', 'bard', 'pullTwistOn' },   { 'PullHold', 'pull', 'hold' },
        { 'CampRadius', 'movement', 'campRadius' }, { 'ChaseDistance', 'movement', 'chaseDistance' },
        { 'MedStart', 'heal', 'medStart' },         { 'MedStop', 'heal', 'medStop' },
        { 'HealWhilePaused', 'session', 'healWhilePaused' },
        { 'MoveWhilePaused', 'session', 'moveWhilePaused' },
        { 'WarnAggroWhilePaused', 'session', 'warnAggroWhilePaused' },
        { 'ConOn', 'cond', 'on' },                  { 'CampfireOn', 'misc', 'campfireOn' },
        { 'ClickBacktoCamp', 'afk', 'clickBacktoCamp' },
        { 'CheckBuffsTimer', 'buffs', 'checkBuffsTimer' },
        { 'MiscGem', 'cast', 'miscGem' },           { 'MiscGemLW', 'cast', 'miscGemLW' },
        { 'CheckStuckGem', 'cast', 'checkStuckGem' },
        { 'CastingInterruptOn', 'cast', 'castingInterruptOn' },
        { 'BuffsOn', 'buffs', 'buffsOn' },          { 'RebuffOn', 'buffs', 'rebuffOn' },
        { 'MountOn', 'misc', 'mountOn' },           { 'MercAssistAt', 'merc', 'assistAt' },
        { 'MercOn', 'merc', 'on' },                 { 'PetOn', 'pet', 'on' },
        { 'PetBuffsOn', 'buffs', 'petBuffsOn' },    { 'PetShrinkOn', 'pet', 'shrinkOn' },
        { 'PetToysOn', 'pet', 'toysOn' },           { 'PetSuspend', 'pet', 'suspend' },
        { 'PetHoldOn', 'pet', 'holdOn' },           { 'PetTauntOverride', 'pet', 'tauntOverride' },
        { 'PetForceHealOnMed', 'pet', 'forceHealOnMed' },
        { 'MoveWhenHit', 'pet', 'moveWhenHit' },
    }
    for _, k in ipairs(GUI_KEYS) do
        local tbl, field = Control.resolve(k[1])
        TH.assert_true(tbl == state[k[2]] and field == k[3],
            string.format('resolve %s -> %s.%s', k[1], k[2], k[3]))
    end
    -- the mac's names
    local tbl, field = Control.resolve('pethold')
    TH.assert_true(tbl == state.pet and field == 'holdOn', 'resolve mac PetHold -> pet.holdOn')
    tbl, field = Control.resolve('chaseassist')
    TH.assert_true(tbl == state.session and field == 'chaseAssist', 'resolve is case-insensitive')
    TH.assert_nil(Control.resolve('NoSuchSetting'), 'resolve: unknown name -> nil')

    -- ── values ──────────────────────────────────────────────────────────────
    local ok, msg, info = Control.set('MeleeOn', true)
    TH.assert_true(ok and msg == 'set', 'set returns ok, set')
    TH.assert_true(state.combat.meleeOn == true and info ~= nil and info.on == true, 'boolean on -> boolean field')
    Control.set('MeleeOn', false)
    TH.assert_eq(state.combat.meleeOn, false, 'boolean off -> boolean field')
    Control.set('AutoFireOn', true)
    TH.assert_eq(state.combat.autoFireOn, 1, 'boolean on -> number field 1')
    Control.set('AutoFireOn', false)
    TH.assert_eq(state.combat.autoFireOn, 0, 'boolean off -> number field 0')
    Control.set('CastingInterruptOn', true)
    TH.assert_eq(state.cast.castingInterruptOn, 62, 'CastingInterruptOn on -> 62 (all)')
    Control.set('MeleeDistance', 25)
    TH.assert_eq(state.combat.meleeDistance, 25, 'number -> number field')
    Control.set('MeleeDistance', '30')
    TH.assert_eq(state.combat.meleeDistance, 30, 'typed number -> number field')
    Control.set('MeleeOn', 'on')
    TH.assert_true(state.combat.meleeOn, "'on' -> on")
    Control.set('MeleeOn', '')
    TH.assert_false(state.combat.meleeOn, 'no value -> off (the mac)')
    ok, msg = Control.set('NoSuchSetting', 1)
    TH.assert_true(not ok and msg == 'unknown', 'unknown name -> unknown')
    ok, msg = Control.set('DPSMeter', 1)
    TH.assert_true(not ok and msg == 'unsupported', 'DPSMeter -> unsupported')

    -- ── saving ──────────────────────────────────────────────────────────────
    cfg.reset()
    Control.set('MeleeOn', true)
    TH.assert_eq(#cfg.sets, 0, 'no save option: nothing written')
    Control.set('MeleeOn', true, { section = 'Melee', save = true })
    TH.assert_eq(cfg.last(), 'Melee/MeleeOn=1', 'GUI boolean saved as 1')
    TH.assert_eq(cfg.saves, 1, 'Config.save called once')
    Control.set('HealsOn', false, { section = 'Heals', save = true })
    TH.assert_eq(cfg.last(), 'Heals/HealsOn=0', 'GUI boolean on a number field saved as 0')
    Control.set('CastingInterruptOn', true, { section = 'Spells', save = true })
    TH.assert_eq(cfg.last(), 'Spells/CastingInterruptOn=62', 'saved as the field value (62)')
    Control.set('MeleeDistance', 40, { section = 'Melee', save = true })
    TH.assert_eq(cfg.last(), 'Melee/MeleeDistance=40', 'number saved as text')
    cfg.reset()
    Control.set('MeleeOn', true, { save = true })
    TH.assert_eq(#cfg.sets, 0, 'save without a section: nothing written')

    -- ── side effects ────────────────────────────────────────────────────────
    state.session.iAmMA = false
    Control.set('TargetSwitchingOn', true)
    TH.assert_false(state.combat.targetSwitchingOn, 'TargetSwitchingOn stays off for a non-MA')
    state.session.iAmMA = true
    Control.set('TargetSwitchingOn', true)
    TH.assert_true(state.combat.targetSwitchingOn, 'TargetSwitchingOn on for the MA')

    Control.set('MaxRadius', 300)
    TH.assert_eq(state.movement.campRadiusExceed, 500, 'MaxRadius updates campRadiusExceed (+200)')

    Control.set('BuffsOn', 2)
    TH.assert_true(state.buffs.buffsOn and state.buffs.buffGroupPets, 'BuffsOn 2: on + group pets')
    Control.set('BuffsOn', 1)
    TH.assert_true(state.buffs.buffsOn and not state.buffs.buffGroupPets, 'BuffsOn 1: no group pets')
    state.buffs.buffGroupPets = true
    Control.set('BuffsOn', 0)
    TH.assert_true(not state.buffs.buffsOn and state.buffs.buffGroupPets, 'BuffsOn 0: group pets kept')

    -- HealsOn is a mode 0-4 (#358): the number is kept, saved as given, and
    -- session.heals (castMem guard) follows it.
    cfg.reset()
    Control.set('HealsOn', 4, { section = 'Heals', save = true })
    TH.assert_eq(state.heal.healsOn, 4, 'HealsOn 4 kept (not 1)')
    TH.assert_eq(cfg.last(), 'Heals/HealsOn=4', 'HealsOn 4 saved as 4')
    TH.assert_true(state.session.heals, 'HealsOn 4: session.heals on')
    Control.set('HealsOn', 0, { section = 'Heals', save = true })
    TH.assert_eq(state.heal.healsOn, 0, 'HealsOn 0: off')
    TH.assert_false(state.session.heals, 'HealsOn 0: session.heals off')
    Control.set('HealsOn', 2, { section = 'Heals', save = true })
    TH.assert_eq(state.heal.healsOn, 2, 'HealsOn off then 2: 2, not 1')
    TH.assert_eq(cfg.last(), 'Heals/HealsOn=2', 'HealsOn 2 saved as 2')

    Control.set('DPSOn', '2')
    TH.assert_true(state.combat.dpsOn and state.combat.dpsOnOoc, 'DPSOn 2: dpsOnOoc')
    Control.set('DPSOn', '1')
    TH.assert_false(state.combat.dpsOnOoc, 'DPSOn 1: no dpsOnOoc')

    state.movement.returnToCamp = true
    state.movement.whoToChase = ''
    Control.set('ChaseAssist', 'on', { who = 'Leader' })
    TH.assert_eq(state.movement.whoToChase, 'Leader', 'ChaseAssist on: chase target set')
    TH.assert_false(state.movement.returnToCamp, 'ChaseAssist on: ReturnToCamp off')

    MockMQ.set('TLO.Me.X', 11)
    MockMQ.set('TLO.Me.Y', 22)
    MockMQ.set('TLO.Me.FloorZ', 3)
    cfg.reset()
    Control.set('ReturnToCamp', 'on')
    TH.assert_true(state.movement.campX == 11 and state.movement.campY == 22, 'ReturnToCamp on: camp right here')
    TH.assert_false(state.session.chaseAssist, 'ReturnToCamp on: chase off')
    TH.assert_eq(cfg.last(), 'General/ChaseAssist=0', 'ReturnToCamp on: ChaseAssist 0 saved (mac:8425)')

    state.session.chaseAssist = true
    ok, msg = Control.set('waithere')
    TH.assert_true(ok and msg == 'waithere', 'waithere handled')
    TH.assert_true(not state.session.chaseAssist and not state.movement.returnToCamp, 'waithere: chase and camp off')

    ok, msg, info = Control.set('GroupWatchOn', '30', { save = true })
    TH.assert_true(ok and msg == 'set' and info ~= nil and info.shown == '1|30',
        'GroupWatch settings go through GroupWatch.setVar')
    TH.assert_eq(gw.saved, 1, 'GroupWatch saved with save')
    ok, msg = Control.set('GroupWatchOn', 'bad')
    TH.assert_true(not ok and msg == 'badvalue', 'GroupWatch bad value -> badvalue')

    -- ── 3c: the GUI's remaining settings (#363) ─────────────────────────────
    -- Names the GUI now sets through Control instead of writing State/Config.
    for _, k in ipairs({
        { 'AFKGMAction', 'afk', 'gmAction' },   { 'AFKPCRadius', 'afk', 'pcRadius' },
        { 'AFKToolsOn', 'afk', 'on' },          { 'CharmSpell', 'charm', 'spell' },
        { 'PetSpell', 'pet', 'spell' },         { 'PetShrinkSpell', 'pet', 'shrinkSpell' },
        { 'StickHow', 'movement', 'dStickHow' }, { 'MezOn', 'mez', 'on' },
        { 'MezDebuffSpell', 'mez', 'mezDebuffSpell' }, { 'DebuffOn', 'debuff', 'on' },
        { 'CuresOn', 'heal', 'curesOn' },       { 'XTarHeal', 'heal', 'xTarHeal' },
        { 'XTarHealList', 'heal', 'xTarHealList' }, { 'FaceMobOn', 'movement', 'faceMobOn' },
        { 'BurnAllNamed', 'combat', 'burnAllNamed' }, { 'LoadSpellSet', 'cast', 'loadSpellSet' },
        { 'SpellSetName', 'cast', 'spellSetName' }, { 'MiscGemRemem', 'cast', 'miscGemRemem' },
    }) do
        tbl, field = Control.resolve(k[1])
        TH.assert_true(tbl == state[k[2]] and field == k[3],
            string.format('resolve %s -> %s.%s', k[1], k[2], k[3]))
    end

    -- Stubs for the modules the side effects and SPECIAL settings call.
    local stubNames = { 'modules.movement', 'modules.healing', 'modules.pull', 'modules.combat.settings' }
    local savedStubs = {}
    for _, n in ipairs(stubNames) do savedStubs[n] = package.loaded[n] end
    local calls = {}
    package.loaded['modules.movement'] = { resolveStickHow = function() calls.stick = (calls.stick or 0) + 1 end }
    package.loaded['modules.healing']  = { setXTargetHealList = function(v) calls.xtar = v end }
    package.loaded['modules.pull'] = {
        setPullLevel = function(v) state.pull.levelSetting = v; calls.level = v end,
        setPullPause = function(v) state.pull.pauseSetting = v; calls.pause = v end,
    }
    local meleeLoaded = true
    package.loaded['modules.combat.settings'] = {
        setMQ2Melee = function(st, on)
            if on and not meleeLoaded then return false end
            st.combat.useMQ2Melee = on
            calls.melee = on
            return true
        end,
    }

    -- text: kept exactly as given, empty included
    cfg.reset()
    Control.set('CharmSpell', 'Beguile', { section = 'Charm', save = true, text = true })
    TH.assert_eq(state.charm.spell, 'Beguile', 'text setting: spell name set')
    TH.assert_eq(cfg.last(), 'Charm/CharmSpell=Beguile', 'text setting: saved as typed')
    Control.set('CharmSpell', '', { section = 'Charm', save = true, text = true })
    TH.assert_eq(state.charm.spell, '', "text setting: empty stays empty (not '0')")
    TH.assert_eq(cfg.last(), 'Charm/CharmSpell=', 'text setting: empty saved')

    -- StickHow: the INI value, then resolved by role
    calls.stick = 0
    Control.set('StickHow', 'behind', { section = 'Melee', save = true, text = true })
    TH.assert_eq(state.movement.dStickHow, 'behind', 'StickHow sets dStickHow')
    TH.assert_eq(calls.stick, 1, 'StickHow re-resolves the stick')

    -- XTarHealList: the slot list is applied
    Control.set('XTarHealList', '5|6', { text = true })
    TH.assert_eq(calls.xtar, '5|6', 'XTarHealList applied (setXTargetHealList)')

    -- AutoHide: saving drops the old [General] key
    cfg.reset()
    Control.set('AutoHide', true, { section = 'Melee', save = true })
    local dropped = false
    for _, s in ipairs(cfg.sets) do
        if s[1] == 'General' and s[2] == 'AutoHide' and s[3] == nil then dropped = true end
    end
    TH.assert_true(dropped, 'AutoHide save drops [General] AutoHide')

    -- AFK: MQ2Posse gets the PC radius
    MockMQ.set('TLO.Plugin', function() return { IsLoaded = function() return true end } end)
    Control.set('AFKPCRadius', 750, { section = 'AFKTools', save = true })
    TH.assert_eq(state.afk.pcRadius, 750, 'AFKPCRadius set')
    TH.assert_true(MockMQ.cmdCalled('/posse radius 750'), 'AFKPCRadius: /posse radius sent')
    Control.set('AFKToolsOn', 2)
    TH.assert_eq(state.afk.on, 2, 'AFKToolsOn 2 set')

    -- MezSpell / MezAESpell: 'spell|count' into two fields
    cfg.reset()
    Control.set('MezSpell', 'Mesmerize|3', { section = 'Mez', save = true, text = true })
    TH.assert_true(state.mez.spell == 'Mesmerize' and state.mez.singleCount == 3, 'MezSpell: spell + count')
    TH.assert_eq(cfg.last(), 'Mez/MezSpell=Mesmerize|3', 'MezSpell saved as spell|count')
    Control.set('MezSpell', 'Mesmerize|1')
    TH.assert_eq(state.mez.singleCount, 2, 'MezSpell: count at least 2 (mac)')
    Control.set('MezAESpell', 'Color Slant|0')
    TH.assert_true(state.mez.aeSpell == 'Color Slant' and state.mez.aeCount == 0, 'MezAESpell: 0 = off')
    state.mez.aeCount = 4
    Control.set('MezAESpell', 'Color Flux')
    TH.assert_true(state.mez.aeSpell == 'Color Flux' and state.mez.aeCount == 4, 'MezAESpell: no count keeps it')

    -- PullLevel / PullPause: parsed by the pull module, saved as it keeps them
    cfg.reset()
    ok = Control.set('PullLevel', '10|20', { section = 'Pull', save = true, text = true })
    TH.assert_true(ok and calls.level == '10|20', 'PullLevel goes to Pull.setPullLevel')
    TH.assert_eq(cfg.last(), 'Pull/PullLevel=10|20', 'PullLevel saved')
    Control.set('PullPause', '30|5', { section = 'Pull', save = true, text = true })
    TH.assert_eq(calls.pause, '30|5', 'PullPause goes to Pull.setPullPause')

    -- UseMQ2Melee 0 / 1 / 2
    cfg.reset()
    state.combat.mq2MeleeMode = 1
    ok = Control.set('UseMQ2Melee', 2, { section = 'Melee', save = true })
    TH.assert_true(ok and state.combat.useMQ2Melee and state.combat.mq2MeleeMode == 2, 'UseMQ2Melee 2: on, INI stickcmd')
    TH.assert_eq(cfg.last(), 'Melee/UseMQ2Melee=2', 'UseMQ2Melee 2 saved')
    Control.set('UseMQ2Melee', false, { section = 'Melee', save = true })
    TH.assert_true(not state.combat.useMQ2Melee and state.combat.mq2MeleeMode == 2, 'UseMQ2Melee off keeps mode 2')
    TH.assert_eq(cfg.last(), 'Melee/UseMQ2Melee=0', 'UseMQ2Melee off saved as 0')
    Control.set('UseMQ2Melee', true, { section = 'Melee', save = true })
    TH.assert_eq(cfg.last(), 'Melee/UseMQ2Melee=2', 'UseMQ2Melee on (boolean) keeps mode 2')
    ok, msg = Control.set('UseMQ2Melee', 5)
    TH.assert_true(not ok and msg == 'badvalue', 'UseMQ2Melee 5 -> badvalue')
    meleeLoaded = false
    state.combat.useMQ2Melee = false
    cfg.reset()
    ok, msg = Control.set('UseMQ2Melee', true, { section = 'Melee', save = true })
    TH.assert_true(not ok and msg == 'noplugin', 'UseMQ2Melee without the plugin -> noplugin')
    TH.assert_eq(#cfg.sets, 0, 'UseMQ2Melee without the plugin: nothing saved')

    -- ── Control.setEntries: the GUI's list editors ──────────────────────────
    local reloads = {}
    local function note(what) reloads[#reloads + 1] = what end
    local savedEntryMods = {}
    for _, n in ipairs({ 'modules.buffs', 'modules.debuff', 'modules.cond' }) do
        savedEntryMods[n] = package.loaded[n] or false
    end
    package.loaded['modules.combat.settings'] = { loadList = function(st, sec)
        TH.assert_true(st == state, 'combat loadList gets State'); note('combat:' .. sec) end }
    package.loaded['modules.healing'] = { loadList = function(sec) note('heal:' .. sec) end }
    package.loaded['modules.buffs']   = { loadList = function(name) note('buffs:' .. name) end }
    package.loaded['modules.debuff']  = { loadList = function() note('debuff') end }
    package.loaded['modules.cond']    = { load = function() note('cond') end }

    local function setOf(section, key)
        for i = #cfg.sets, 1, -1 do
            local s = cfg.sets[i]
            if s[1] == section and s[2] == key then return s[3] end
        end
    end
    local LISTS = {
        { 'dps', 'DPS', 'DPS', 'DPSSize', 'combat:DPS' },
        { 'burn', 'Burn', 'Burn', 'BurnSize', 'combat:Burn' },
        { 'aggro', 'Aggro', 'Aggro', 'AggroSize', 'combat:Aggro' },
        { 'ae', 'AE', 'AE', 'AESize', 'combat:AE' },
        { 'debuff', 'Debuff', 'Debuff', 'DebuffSize', 'debuff' },
        { 'heals', 'Heals', 'Heals', 'HealsSize', 'heal:Heals' },
        { 'cures', 'Cures', 'Cures', 'CuresSize', 'heal:Cures' },
        { 'buffs', 'Buffs', 'Buffs', 'BuffsSize', 'buffs:Buffs' },
        { 'petbuffs', 'Pet', 'PetBuffs', 'PetBuffsSize', 'buffs:PetBuffs' },
        { 'pettoys', 'Pet', 'PetToys', 'PetToysSize', 'buffs:PetToys' },
        { 'cond', 'KConditions', 'Cond', 'CondSize', 'cond' },
        { 'gom', 'GoM', 'GoMSpell', 'GoMSize', nil },
    }
    for _, l in ipairs(LISTS) do
        cfg.reset()
        reloads = {}
        local arr = { 'Entry One|50', 'null' }
        ok = Control.setEntries(l[1], arr, 2)
        TH.assert_true(ok, 'setEntries ' .. l[1] .. ': ok')
        TH.assert_true(setOf(l[2], l[3]) == arr, string.format('setEntries %s: [%s] %s saved', l[1], l[2], l[3]))
        TH.assert_eq(setOf(l[2], l[4]), '2', string.format('setEntries %s: %s saved', l[1], l[4]))
        TH.assert_eq(cfg.saves, 1, 'setEntries ' .. l[1] .. ': Config.save once')
        TH.assert_eq(table.concat(reloads, ','), l[5] or '', 'setEntries ' .. l[1] .. ': reloaded by its module')
    end
    cfg.reset()
    Control.setEntries('DPS', { 'x' })
    TH.assert_nil(setOf('DPS', 'DPSSize'), 'setEntries: no size -> size key left alone (any-case name)')
    Control.setEntries('gems', { 'Spell A', 'Spell B' }, 8)
    TH.assert_true(setOf('Spells', 'Gems') ~= nil and #cfg.sets == 2, 'setEntries gems: saved, no size key')
    ok, msg = Control.setEntries('nosuch', {})
    TH.assert_true(not ok and msg == 'unknown list', 'setEntries: unknown list')
    ok, msg = Control.setEntries('dps', 'text')
    TH.assert_true(not ok and msg == 'bad entries', 'setEntries: entries must be a table')

    for _, n in ipairs(stubNames) do package.loaded[n] = savedStubs[n] end
    for n, v in pairs(savedEntryMods) do package.loaded[n] = v or nil end

    -- ── Control.defer: the GUI's buttons run on the main loop ──────────────
    local ran = {}
    Control.verb('zzdefer', 'zzdefer', function(words) ran[#ran + 1] = words[1] or ''; return true end)
    Control.defer('zzdefer', { 'a' })
    Control.defer('zzdefer', { 'b' })
    TH.assert_eq(#ran, 0, 'defer: nothing runs until runDeferred')
    Control.runDeferred()
    TH.assert_eq(table.concat(ran, ','), 'a,b', 'runDeferred: queued verbs run in order')
    Control.runDeferred()
    TH.assert_eq(#ran, 2, 'runDeferred: the queue is emptied')

    -- ── /togglevariable and /changevarint adapters ──────────────────────────
    local saved = { aliases = package.loaded['modules.aliases'], bind = MockMQ.bind }
    package.loaded['modules.aliases'] = { sync = function() return 0, 0 end }
    package.loaded['modules.binds'] = nil
    local bound = {}
    MockMQ.bind = function(cmd, fn) bound[cmd] = fn end
    local Binds = require('modules.binds')
    Binds.register(state, {}, {}, {}, cfg, nil)

    cfg.reset()
    bound['/togglevariable']('MeleeOn', 'on')
    TH.assert_true(state.combat.meleeOn, '/togglevariable MeleeOn on')
    TH.assert_eq(#cfg.sets, 0, '/togglevariable does not save')
    bound['/togglevariable']('MeleeOn')
    TH.assert_false(state.combat.meleeOn, '/togglevariable MeleeOn (no value) -> off')
    state.pet.holdOn = 1
    bound['/togglevariable']('PetHold', '0')
    TH.assert_eq(state.pet.holdOn, 0, '/togglevariable PetHold 0 (mac name)')

    bound['/changevarint']('Melee', 'AssistAt', '55')
    TH.assert_eq(state.combat.assistAt, 55, '/changevarint Melee AssistAt 55')
    TH.assert_eq(cfg.last(), 'Melee/AssistAt=55', '/changevarint saves under the section')
    TH.assert_true(cfg.saves >= 1, '/changevarint calls Config.save')
    cfg.reset()
    bound['/changevarint']('AssistAt', '60')
    TH.assert_eq(state.combat.assistAt, 60, '/changevarint AssistAt 60 (old form)')
    TH.assert_eq(#cfg.sets, 0, '/changevarint old form does not save')
    bound['/changevarint']('Mez', 'MezRadius', '45')
    TH.assert_eq(state.mez.radius, 45, '/changevarint Mez MezRadius 45 (INI key, newly resolvable)')

    local before = state.combat.assistAt
    bound['/changevarint']('Melee', 'NoSuchSetting', '5')
    TH.assert_eq(state.combat.assistAt, before, '/changevarint unknown name: nothing changes')

    MockMQ.bind = saved.bind
    package.loaded['modules.aliases']    = saved.aliases
    package.loaded['modules.binds']      = nil
    package.loaded['modules.control']    = nil
    package.loaded['modules.groupwatch'] = savedGW
end

return M
