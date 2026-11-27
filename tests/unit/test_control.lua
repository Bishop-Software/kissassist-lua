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
