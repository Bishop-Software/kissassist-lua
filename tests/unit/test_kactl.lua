-- tests/unit/test_kactl.lua
-- /kactl verbs (control API phase 3a, #363): the verb router and
-- ${KissAssist.LastResult}, set (values, toggle, save under the INI section),
-- pause, stop, target, charm, medley, list, test; and that the Lua-only
-- commands they replace are no longer bound. (mode is in test_camp_toggle;
-- ui needs the ImGui window and is covered in game.)
local M = {}

local function fakeConfig()
    local cfg = { sets = {}, saves = 0 }
    function cfg.set(section, key, value) cfg.sets[#cfg.sets + 1] = section .. '/' .. key .. '=' .. tostring(value) end
    function cfg.save() cfg.saves = cfg.saves + 1 end
    function cfg.get() return nil end
    function cfg.defaultCfg()
        return {
            Melee  = { MeleeOn = '1', ManualTargetMode = '0' },
            Spells = { CastingInterruptOn = '62' },
            Charm  = { CharmOn = '0' },
            Twice  = { Dup = '1' }, Other = { Dup = '0' },
        }
    end
    function cfg.last() return cfg.sets[#cfg.sets] end
    return cfg
end

local function newState()
    return {
        session = { chaseAssist = false, iAmACharmClass = true, iAmABard = true,
                    infoFileName = '', zoneName = '', iAmMA = true },
        movement = { returnToCamp = false, campX = 0, campY = 0, whoToChase = '' },
        combat  = { meleeOn = true, manualTargetMode = false, myTargetID = 5, aggroTargetID = '',
                    namedWatchList = {} },
        cast    = { castingInterruptOn = 0 },
        misc    = { mountOn = false, pendingTest = '' },
        charm   = { on = false, keep = false, petId = 0, petZone = '', immuneIds = '', aaImmune = false },
        bard    = { medleyQuiet = false },
        pull    = { mapSet = true },
    }
end

function M.run(TH, MockMQ)
    TH.setSuite('test_kactl')
    MockMQ.reset()

    local savedPause = package.loaded['modules.pause']
    local pause = { on = false }
    package.loaded['modules.pause'] = {
        isPaused = function() return pause.on end,
        set = function(on) pause.on = on; return true end,
    }

    package.loaded['modules.control'] = nil
    local Control = require('modules.control')
    local state, cfg = newState(), fakeConfig()
    Control.init(state, cfg, nil)

    local saved = { aliases = package.loaded['modules.aliases'], bind = MockMQ.bind }
    package.loaded['modules.aliases'] = { sync = function() return 0, 0 end }
    package.loaded['modules.binds'] = nil
    local bound = {}
    MockMQ.bind = function(cmd, fn) bound[cmd] = fn end
    local Binds = require('modules.binds')
    Binds.register(state, {}, {}, {}, cfg, nil)

    local function kactl(...) return Control.command({ ... }) end

    -- ── the Lua-only commands are gone ──────────────────────────────────────
    for _, cmd in ipairs({ '/kapause', '/kastop', '/katest', '/kaswitchtarget', '/katargetmode',
                           '/kainterrupton', '/mounton', '/mountoff', '/kamedleyquiet', '/addburn',
                           '/charmon', '/charmkeep', '/setcharmed', '/resetcharmed', '/addcimmune' }) do
        TH.assert_nil(bound[cmd], cmd .. ' is no longer bound')
    end
    TH.assert_not_nil(bound['/kactl'], '/kactl is bound')
    TH.assert_not_nil(bound['/addignore'], 'mac commands stay (/addignore)')

    -- ── router and LastResult ───────────────────────────────────────────────
    TH.assert_false(kactl('dance'), 'unknown verb fails')
    TH.assert_eq(Control.lastResult, 'error: unknown verb', 'LastResult after an unknown verb')
    TH.assert_true(kactl('stop', 'verbose'), "'verbose' is not passed to the verb")
    TH.assert_eq(Control.lastResult, 'ok', 'LastResult ok')
    TH.assert_true(state.terminate, 'stop: terminate set')
    state.terminate = nil
    TH.assert_false(kactl('stop', 'now'), 'stop takes no arguments')
    TH.assert_eq(Control.lastResult, 'error: takes no arguments', 'LastResult carries the reason')

    package.loaded['modules.tlo'] = nil
    local Tlo = require('modules.tlo')
    Tlo.init(state)
    TH.assert_eq(select(2, Tlo.members.LastResult()), 'error: takes no arguments', '${KissAssist.LastResult}')
    package.loaded['modules.tlo'] = nil

    -- ── set ─────────────────────────────────────────────────────────────────
    TH.assert_true(kactl('set', 'MeleeOn', 'off'), 'set MeleeOn off')
    TH.assert_false(state.combat.meleeOn, 'set: value applied')
    TH.assert_eq(#cfg.sets, 0, 'set without save: nothing written')
    TH.assert_true(kactl('set', 'MeleeOn', 'toggle'), 'set MeleeOn toggle')
    TH.assert_true(state.combat.meleeOn, 'set toggle: flipped')
    TH.assert_true(kactl('set', 'castinginterrupton', 'toggle', 'save'), 'set number toggle save')
    TH.assert_eq(state.cast.castingInterruptOn, 62, 'set toggle on a number field: on (62)')
    TH.assert_eq(cfg.last(), 'Spells/CastingInterruptOn=62', 'set save: INI section and key spelling found')
    TH.assert_true(kactl('set', 'ManualTargetMode', 'on', 'save'), 'set ManualTargetMode on save')
    TH.assert_true(state.combat.manualTargetMode, 'ManualTargetMode on (was /katargetmode)')
    TH.assert_eq(cfg.last(), 'Melee/ManualTargetMode=1', 'ManualTargetMode saved under Melee')
    TH.assert_true(kactl('set', 'MountOn', 'on'), 'set MountOn on (was /mounton)')
    TH.assert_true(state.misc.mountOn, 'MountOn on')
    TH.assert_false(kactl('set', 'MeleeOn'), 'set needs a value (no "no value means off")')
    TH.assert_false(kactl('set', 'NoSuchSetting', 'on'), 'set unknown name fails')
    TH.assert_false(kactl('set', 'MountOn', 'on', 'save'), 'set save with no known section fails')
    TH.assert_eq(Control.sectionOf('Dup'), nil, 'sectionOf: a key in two sections is ambiguous')
    TH.assert_false(kactl('set', 'MeleeOn', 'on', 'extra'), 'set: extra words rejected')

    -- ── pause ───────────────────────────────────────────────────────────────
    TH.assert_true(kactl('pause', 'on'), 'pause on')
    TH.assert_true(pause.on, 'pause on: paused')
    TH.assert_true(kactl('pause', 'toggle'), 'pause toggle')
    TH.assert_false(pause.on, 'pause toggle: resumed')
    TH.assert_false(kactl('pause'), 'pause needs on, off or toggle')
    TH.assert_false(kactl('pause', '1'), 'pause 1 rejected (strict)')

    -- ── target ──────────────────────────────────────────────────────────────
    MockMQ.set('TLO.Spawn', function(q)
        local id = tonumber(tostring(q):match('id (%d+)'))
        return { ID = function() return id == 42 and 42 or 0 end, CleanName = function() return 'a mob' end }
    end)
    TH.assert_true(kactl('target', '42'), 'target 42')
    TH.assert_eq(state.combat.aggroTargetID, '42', 'target: aggroTargetID set')
    TH.assert_eq(state.combat.myTargetID, 0, 'target: current target dropped')
    state.combat.myTargetID = 9
    TH.assert_false(kactl('target', '99'), 'target with no such spawn fails')
    TH.assert_true(state.combat.myTargetID == 9 and state.combat.aggroTargetID == '42',
        'target with no such spawn: nothing changed')
    TH.assert_true(kactl('target', 'clear'), 'target clear')
    TH.assert_eq(state.combat.aggroTargetID, '', 'target clear: cleared')
    TH.assert_false(kactl('target'), 'target needs an ID or clear')

    -- ── charm ───────────────────────────────────────────────────────────────
    cfg.sets = {}
    TH.assert_true(kactl('charm', 'on'), 'charm on')
    TH.assert_true(state.charm.on, 'charm on: CharmOn')
    TH.assert_eq(#cfg.sets, 0, 'charm on without save: nothing written')
    TH.assert_true(kactl('charm', 'keep', 'toggle', 'save'), 'charm keep toggle save')
    TH.assert_true(state.charm.keep, 'charm keep: on')
    TH.assert_eq(cfg.last(), 'Charm/CharmKeep=1', 'charm keep saved under Charm')
    MockMQ.set('TLO.Me.Pet.ID', 77)
    MockMQ.set('TLO.Zone.ShortName', 'zone')
    TH.assert_true(kactl('charm', 'set'), 'charm set')
    TH.assert_true(state.charm.petId == 77 and state.charm.petZone == 'zone', 'charm set: pet recorded')
    TH.assert_true(kactl('charm', 'reset'), 'charm reset')
    TH.assert_eq(state.charm.petId, 0, 'charm reset: cleared')
    state.session.iAmACharmClass = false
    TH.assert_false(kactl('charm', 'on'), 'charm on: not a charm class fails')
    state.session.iAmACharmClass = true
    TH.assert_false(kactl('charm', 'maybe'), 'charm: bad word fails')

    -- ── medley ──────────────────────────────────────────────────────────────
    MockMQ.reset()
    TH.assert_true(kactl('medley', 'quiet', 'on'), 'medley quiet on')
    TH.assert_true(state.bard.medleyQuiet and MockMQ.cmdCalled('/medley quiet'), 'medley quiet on: sent once')
    MockMQ.reset()
    TH.assert_true(kactl('medley', 'quiet', 'on'), 'medley quiet on again')
    TH.assert_false(MockMQ.cmdCalled('/medley quiet'), 'medley quiet on again: nothing sent (no flip back)')
    state.session.iAmABard = false
    TH.assert_false(kactl('medley', 'quiet', 'off'), 'medley: bard only')
    state.session.iAmABard = true

    -- ── list ────────────────────────────────────────────────────────────────
    TH.assert_false(kactl('list', 'burn', 'add', 'a mob'), 'list burn add: fails before the zone is known')
    TH.assert_false(kactl('list', 'pull', 'add'), 'list pull: not in this step')
    TH.assert_false(kactl('list', 'burn', 'remove'), 'list: only add for now')
    MockMQ.set('TLO.Target.ID', 0)
    TH.assert_false(kactl('list', 'charmimmune', 'add'), 'list charmimmune add: needs an NPC target')
    MockMQ.set('TLO.Target.ID', 42)
    MockMQ.set('TLO.Target.Type', 'NPC')
    MockMQ.set('TLO.Target.CleanName', 'a mob')
    TH.assert_true(kactl('list', 'charmimmune', 'add'), 'list charmimmune add (was /addcimmune)')
    TH.assert_eq(state.charm.immuneIds, '|42', 'charmimmune: ID on the runtime list')

    -- ── test ────────────────────────────────────────────────────────────────
    TH.assert_true(kactl('test', 'camp_cmds'), 'test camp_cmds')
    TH.assert_eq(state.misc.pendingTest, 'camp_cmds', 'test: queued for the main loop')
    TH.assert_false(kactl('test', 'nosuite'), 'test: unknown suite fails')
    TH.assert_false(kactl('test'), 'test: needs a suite')

    MockMQ.bind = saved.bind
    package.loaded['modules.aliases'] = saved.aliases
    package.loaded['modules.binds']   = nil
    package.loaded['modules.control'] = nil
    package.loaded['modules.pause']   = savedPause
end

return M
