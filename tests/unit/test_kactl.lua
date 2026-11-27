-- tests/unit/test_kactl.lua
-- /kactl verbs (control API phase 3, #363): the verb router and
-- ${KissAssist.LastResult}, set (values, toggle, save under the INI section),
-- pause, stop, target, charm, medley, list, test (3a); the replacements for the
-- mac's commands (backoff, burn, ignore, switch, ma, cast, debug, buff, ini,
-- set PullRanking, list toobuff, info, parse) and the once-per-session
-- deprecation notice on the mac's commands (3b); Control.run; and that the
-- Lua-only commands are no longer bound. (mode is in test_camp_toggle; ui needs
-- the ImGui window and is covered in game.)
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
                    namedWatchList = {}, assistAt = 95, burnOn = false, burnID = 0, calledTargetID = 0 },
        cast    = { castingInterruptOn = 0 },
        misc    = { mountOn = false, pendingTest = '' },
        charm   = { on = false, keep = false, petId = 0, petZone = '', immuneIds = '', aaImmune = false },
        bard    = { medleyQuiet = false },
        pull    = { mapSet = true, mobsToIgnoreByID = 'null', ranking = false },
        dps     = { paused = false },
        debug   = { all = false, combat = false, logging = false },
        buffs   = { extendedList = '' },
        timers  = {},
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
    local calls = { reset = 0, buffs = 0 }
    local combat = {
        combatReset       = function(...) calls.reset = calls.reset + 1; calls.resetArgs = { ... } end,
        combatTargetCheck = function() end,
    }
    local cast  = { castWhat = function(what, id) calls.cast = { what, id } end }
    local buffs = { checkBuffs = function() calls.buffs = calls.buffs + 1 end }
    Binds.register(state, buffs, cast, combat, cfg, nil)

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
    -- A fake Spawn: ID 42 is an NPC called 'a mob'. Set again after each MockMQ.reset().
    local function fakeSpawn()
        MockMQ.set('TLO.Spawn', function(q)
            local id = tonumber(tostring(q):match('id (%d+)'))
            return { ID = function() return id == 42 and 42 or 0 end, CleanName = function() return 'a mob' end,
                     Type = function() return id == 42 and 'NPC' or nil end }
        end)
    end
    fakeSpawn()
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
    TH.assert_false(kactl('list', 'nolist', 'add'), 'list: unknown list fails')
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

    -- ── 3b: replacements for the mac's commands ─────────────────────────────
    fakeSpawn()  -- the medley checks reset the mock
    TH.assert_true(kactl('backoff', 'on'), 'backoff on')
    TH.assert_true(state.dps.paused and calls.reset > 0, 'backoff on: backed off, combat reset')
    TH.assert_true(kactl('backoff', 'toggle'), 'backoff toggle')
    TH.assert_false(state.dps.paused, 'backoff toggle: fighting again')
    TH.assert_false(kactl('backoff'), 'backoff needs on, off or toggle')

    state.combat.myTargetID = 0
    TH.assert_true(kactl('burn', '42'), 'burn 42')
    TH.assert_true(state.combat.burnOn and state.combat.burnID == 42, 'burn: BurnOn on, burning ID 42')
    TH.assert_false(kactl('burn', 'now'), 'burn: a non-number is rejected')

    TH.assert_true(kactl('ignore', '42'), 'ignore 42')
    TH.assert_true(state.pull.mobsToIgnoreByID:find('|42|', 1, true) ~= nil, 'ignore: ID on the session list')
    TH.assert_false(kactl('ignore', '99'), 'ignore: no such NPC fails')
    TH.assert_true(kactl('ignore', 'clear'), 'ignore clear')
    TH.assert_eq(state.pull.mobsToIgnoreByID, 'null', 'ignore clear: session list empty')

    state.session.iAmMA = true
    TH.assert_false(kactl('switch', '42'), 'switch: refused on the MA')
    state.session.iAmMA = false
    local before = calls.reset
    TH.assert_true(kactl('switch', '42'), 'switch 42 (non-MA)')
    TH.assert_true(state.combat.calledTargetID == 42 and calls.reset == before + 1, 'switch: called target, combat reset')
    state.session.iAmMA = true

    local savedRoles = package.loaded['modules.roles']
    local maCall
    package.loaded['modules.roles'] = { switchMA = function(...) maCall = { ... } end }
    TH.assert_true(kactl('ma', 'Tank'), 'ma Tank')
    TH.assert_true(maCall[1] == 'Tank' and maCall[2] == nil and maCall[3] == false, 'ma: no broadcast without group')
    TH.assert_true(kactl('ma', 'Tank', 'pettank', 'group'), 'ma Tank pettank group')
    TH.assert_true(maCall[2] == 'pettank' and maCall[3] == true, 'ma: role and group passed')
    TH.assert_false(kactl('ma'), 'ma needs a name')
    package.loaded['modules.roles'] = savedRoles

    TH.assert_true(kactl('cast', 'Spear', 'of', 'Bloodwretch', '42'), 'cast <spell> <id>')
    TH.assert_true(calls.cast[1] == 'Spear of Bloodwretch' and calls.cast[2] == 42, 'cast: name joined, trailing ID')
    TH.assert_false(kactl('cast'), 'cast needs a spell')

    TH.assert_true(kactl('debug', 'combat', 'on'), 'debug combat on')
    TH.assert_true(state.debug.combat, 'debug combat: on')
    TH.assert_false(kactl('debug', 'nowhere', 'on'), 'debug: unknown area fails')
    TH.assert_false(kactl('debug', 'combat'), 'debug needs on, off or toggle')

    TH.assert_true(kactl('buff', 'now'), 'buff now')
    TH.assert_eq(calls.buffs, 1, 'buff now: a buff pass')
    TH.assert_false(kactl('buff'), 'buff needs now')

    local saves = cfg.saves
    TH.assert_true(kactl('ini', 'write'), 'ini write')
    TH.assert_eq(cfg.saves, saves + 1, 'ini write: config saved')

    TH.assert_true(kactl('list', 'toobuff', 'add', '42'), 'list toobuff add 42')
    TH.assert_eq(state.buffs.extendedList, 'a mob|', 'toobuff: name on the list')
    TH.assert_true(kactl('list', 'toobuff', 'clear'), 'list toobuff clear')
    TH.assert_eq(state.buffs.extendedList, '', 'toobuff clear: empty')
    TH.assert_false(kactl('list', 'toobuff', 'add', 'Bob'), 'toobuff takes an ID, not a name')
    TH.assert_false(kactl('list', 'mezimmune', 'add', 'a mob'), 'mezimmune adds the target; no name')

    local savedPull, savedUtil = package.loaded['modules.pull'], package.loaded['modules.pull.util']
    local rank
    package.loaded['modules.pull'] = { setRanking = function(on, quiet) rank = { on, quiet } end }
    package.loaded['modules.pull.util'] = { isPullerRole = function(r) return r == 'puller' end }
    state.session.role = 'puller'
    TH.assert_true(kactl('set', 'PullRanking', 'on'), 'set PullRanking on')
    TH.assert_true(state.pull.ranking and rank[1] == true, 'PullRanking: pull list rebuilt ranked')
    state.session.role = 'assist'
    kactl('set', 'PullRanking', 'on')
    TH.assert_true(rank[1] == false and rank[2] == true, 'PullRanking: not a puller, turned off quietly')
    package.loaded['modules.pull'], package.loaded['modules.pull.util'] = savedPull, savedUtil

    TH.assert_false(kactl('info'), 'info needs zone or aggro')
    TH.assert_false(kactl('parse'), 'parse needs an expression')

    -- Control.run: the GUI's way in, no LastResult
    kactl('dance')
    TH.assert_true(Control.run('buff', { 'now' }), 'Control.run buff now')
    TH.assert_eq(Control.lastResult, 'error: unknown verb', 'Control.run leaves LastResult alone')

    -- ── 3b: deprecation notice on the mac's commands ────────────────────────
    -- Binds.shownNotices(): every notice shown, '<key> -> <replacement>'.
    local function noticesFor(text)
        local n = 0
        for _, line in ipairs(Binds.shownNotices()) do
            if line:find(text, 1, true) then n = n + 1 end
        end
        return n
    end
    state.session.legacyCmdNotice = true
    bound['/buffgroup']()
    bound['/buffgroup']()
    TH.assert_eq(noticesFor('/kactl buff now'), 1, '/buffgroup: one notice per session')
    bound['/togglevariable']('MeleeOn', 'on')
    TH.assert_eq(noticesFor('/togglevariable MeleeOn'), 1, '/togglevariable: the notice names the variable')
    TH.assert_eq(noticesFor('/kactl set MeleeOn'), 1, '/togglevariable: points at /kactl set')
    bound['/togglevariable']('ReturnToCamp', 'off')
    TH.assert_eq(noticesFor('/kactl mode camp'), 1, '/togglevariable ReturnToCamp (the /camphere alias): points at mode')
    bound['/changevarint']('Melee', 'AssistAt', '80')
    TH.assert_eq(noticesFor('/kactl set AssistAt <value> save'), 1, '/changevarint <Section>: points at set ... save')
    TH.assert_eq(state.combat.assistAt, 80, 'the mac command still works after the notice')
    state.session.legacyCmdNotice = false
    bound['/iniwrite']()
    TH.assert_eq(noticesFor('/kactl ini write'), 0, 'LegacyCmdNotice off: no notice')

    MockMQ.bind = saved.bind
    package.loaded['modules.aliases'] = saved.aliases
    package.loaded['modules.binds']   = nil
    package.loaded['modules.control'] = nil
    package.loaded['modules.pause']   = savedPause
end

return M
