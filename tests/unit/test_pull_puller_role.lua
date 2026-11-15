-- tests/unit/test_pull_puller_role.lua
-- #276: puller / pullertank / pullerpettank role setup from CheckRoles
-- (mac:8688-8734, 8803-8826), and StickHow resolution by role (mac:8659-8743,
-- 8840, 16362-16373).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_puller_role')
    MockMQ.reset()
    local Pull     = require('modules.pull')
    local Movement = require('modules.movement')

    local state = {
        session  = { role = 'puller', infoFileName = '', zoneName = '', chaseAssist = true },
        pull     = {},
        timers   = {},
        heal     = { medOn = false },
        combat   = { aggroTargetID = '' },
        pet      = { attackRange = 100 },
        misc     = {},
        movement = { campX = 0, campY = 0, campRadius = 30 },
    }
    local utils = { debug = function() end, zoneIniGet = function() return nil end }
    Movement.init(state, utils)
    Pull.init(state, utils)
    local s = state

    local function setup(role, opts)
        opts = opts or {}
        MockMQ.reset()
        MockMQ.set('TLO.Me.Pet.ID', opts.pet and 55 or 0)
        MockMQ.set('TLO.Me.Pet.Distance', opts.petDist or 10)
        s.session.role, s.session.chaseAssist = role, true
        s.movement.returnToCamp, s.movement.campRadiusExceed, s.movement.campRadius = false, 400, 30
        s.pull.maxRadius      = 350
        s.combat.assistAt     = 95
        s.combat.meleeOn      = true
        s.combat.useMQ2Melee  = opts.melee or false
        s.misc.mountOn        = true
        s.pet.assistAt        = 90
        Pull.setupPullerRole()
    end

    -- ---- all three ----
    for _, role in ipairs({ 'puller', 'pullertank', 'pullerpettank' }) do
        setup(role)
        TH.assert_true(s.movement.returnToCamp, role .. ': ReturnToCamp forced on')
        TH.assert_false(s.session.chaseAssist, role .. ': ChaseAssist off')
        TH.assert_eq(s.movement.campRadiusExceed, 550, role .. ': CampRadiusExceed = MaxRadius + 200')
    end

    -- ---- per role ----
    setup('puller', { melee = true })
    TH.assert_eq(s.combat.assistAt, 95, 'puller: AssistAt untouched')
    TH.assert_true(s.combat.meleeOn, 'puller: MeleeOn untouched')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee aggro=0'), 'puller: melee aggro=0')

    setup('pullertank', { melee = true })
    TH.assert_eq(s.combat.assistAt, 100, 'pullertank: AssistAt 100')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee aggro=1'), 'pullertank: melee aggro=1')
    TH.assert_true(s.misc.mountOn, 'pullertank: MountOn untouched')

    setup('pullerpettank', { melee = true })
    TH.assert_eq(s.combat.assistAt, 100, 'pullerpettank: AssistAt 100')
    TH.assert_false(s.combat.meleeOn, 'pullerpettank: MeleeOn off')
    TH.assert_false(s.misc.mountOn, 'pullerpettank: MountOn off')
    TH.assert_eq(s.pet.assistAt, 100, 'pullerpettank: PetAssistAt 100')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee aggro=0'), 'pullerpettank: melee aggro=0')

    setup('puller')
    TH.assert_false(MockMQ.cmdMatched('melee'), 'MQ2Melee off: no /melee command')
    setup('puller', { pet = true, petDist = 10 })
    TH.assert_true(MockMQ.cmdCalled('/pet guard'), 'pet within CampRadius: /pet guard')
    setup('puller', { pet = true, petDist = 80 })
    TH.assert_true(MockMQ.cmdCalled('/pet follow'), 'pet farther away: /pet follow')

    setup('tank')
    TH.assert_false(s.movement.returnToCamp, 'tank: ReturnToCamp untouched')
    TH.assert_eq(s.movement.campRadiusExceed, 400, 'tank: CampRadiusExceed untouched')
    TH.assert_true(s.session.chaseAssist, 'tank: ChaseAssist untouched')

    -- ---- StickHow ----
    local function stick(role, raw, melee)
        s.session.role, s.movement.dStickHow, s.combat.useMQ2Melee = role, raw, melee or false
        return Movement.resolveStickHow()
    end
    TH.assert_eq(stick('assist', '0'), 'snaproll', "assist, '0': auto -> snaproll")
    TH.assert_eq(stick('assist', 'auto'), 'snaproll', 'assist, auto: snaproll')
    TH.assert_eq(stick('puller', 'AUTO'), 'snaproll', 'puller, auto (any case): snaproll')
    TH.assert_eq(stick('tank', 'auto'), 'snaproll front moveback', 'tank, auto: snaproll front moveback')
    TH.assert_eq(stick('pullertank', 'auto'), 'snaproll front moveback', 'pullertank, auto: snaproll front moveback')
    TH.assert_eq(stick('hunter', 'auto'), 'moveback', 'hunter, auto: moveback')
    TH.assert_eq(stick('pettank', 'auto'), '0', 'pettank, auto: plain stick')
    TH.assert_eq(stick('assist', 'behind'), 'behind', 'a set value is used as written')
    TH.assert_eq(stick('assist', 'I'), 'I', "'I' (no stick) is kept")
    TH.assert_eq(stick('assist', 'null'), '0', 'null: plain stick')
    TH.assert_eq(stick('assist', 'behind', true), '0', 'MQ2Melee on: MQ2Melee sticks, plain 0')
    TH.assert_eq(s.movement.dStickHow, 'behind', 'the INI value (dStickHow) is not changed')

    package.loaded['modules.pull']     = nil
    package.loaded['modules.movement'] = nil
end

return M
