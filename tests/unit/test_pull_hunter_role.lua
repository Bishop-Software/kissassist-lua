-- tests/unit/test_pull_hunter_role.lua
-- #274: hunter / hunterpettank role setup from CheckRoles (mac:8735-8798).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_hunter_role')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session  = { role = 'hunter', infoFileName = '', zoneName = '', chaseAssist = true },
        pull     = {},
        timers   = {},
        heal     = { medOn = false },
        combat   = { aggroTargetID = '' },
        pet      = { attackRange = 100 },
        misc     = {},
        movement = { campX = 0, campY = 0, campRadius = 30 },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    local s = state

    local function setup(role, rtc, opts)
        opts = opts or {}
        MockMQ.reset()
        MockMQ.set('TLO.Me.Pet.ID', opts.pet or 0)
        s.session.role          = role
        s.session.chaseAssist   = true
        s.misc.mountOn          = true
        s.pet.assistAt          = 90
        s.combat.assistAt       = 95
        s.combat.useMQ2Melee    = opts.melee or false
        s.movement.returnToCamp = rtc
        s.movement.stayPut      = false
        s.pull.pullOnReturn     = false
        Pull.setupHunterRole()
    end

    -- hunter, ReturnToCamp off: stay put and pull on the way back
    setup('hunter', false)
    TH.assert_eq(s.combat.assistAt, 100, 'hunter: AssistAt 100')
    TH.assert_true(s.movement.stayPut, 'RTC off: StayPut on')
    TH.assert_true(s.pull.pullOnReturn, 'RTC off: PullOnReturn on')
    TH.assert_false(s.movement.returnToCamp, 'RTC off: stays off')
    TH.assert_true(s.session.chaseAssist, 'hunter: ChaseAssist untouched')
    TH.assert_true(s.misc.mountOn, 'hunter: MountOn untouched')
    TH.assert_eq(s.pet.assistAt, 90, 'hunter: PetAssistAt untouched')

    -- hunter, ReturnToCamp on: turned off, StayPut off, PullOnReturn as set
    setup('hunter', true)
    TH.assert_false(s.movement.returnToCamp, 'RTC on: turned off')
    TH.assert_false(s.movement.stayPut, 'RTC on: StayPut off')
    TH.assert_false(s.pull.pullOnReturn, 'RTC on: PullOnReturn left as set')

    -- hunterpettank extras
    setup('hunterpettank', false)
    TH.assert_false(s.session.chaseAssist, 'hunterpettank: ChaseAssist off')
    TH.assert_false(s.misc.mountOn, 'hunterpettank: MountOn off')
    TH.assert_eq(s.pet.assistAt, 100, 'hunterpettank: PetAssistAt 100')
    TH.assert_eq(s.combat.assistAt, 100, 'hunterpettank: AssistAt 100')

    -- MQ2Melee aggro and pet follow
    setup('hunter', false, { melee = true, pet = 55 })
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee aggro=1'), 'hunter: melee aggro=1')
    TH.assert_true(MockMQ.cmdCalled('/pet follow'), 'pet up: /pet follow')
    setup('hunterpettank', false, { melee = true })
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee aggro=0'), 'hunterpettank: melee aggro=0')
    TH.assert_false(MockMQ.cmdCalled('/pet follow'), 'no pet: no /pet follow')
    setup('hunter', false)
    TH.assert_false(MockMQ.cmdMatched('melee'), 'MQ2Melee off: no /melee command')

    -- other roles untouched
    setup('pullertank', true)
    TH.assert_eq(s.combat.assistAt, 95, 'pullertank: AssistAt untouched')
    TH.assert_true(s.movement.returnToCamp, 'pullertank: ReturnToCamp untouched')
    TH.assert_false(s.movement.stayPut, 'pullertank: StayPut untouched')

    package.loaded['modules.pull'] = nil
end

return M
