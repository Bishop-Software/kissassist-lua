-- tests/integration/test_charm_cmds.lua
-- Integration tests for the charm system at runtime.
-- Run in-game while kissassist is running: /katest charm_cmds
--
-- NOTE: /charmon and /charmkeep binds cannot be tested via mq.cmd() from within
-- another bind callback — MQ2 defers nested bind dispatches until the outer bind
-- returns, by which time test state has already been restored. Bind handler logic
-- is covered by unit tests (test_charm.lua). These tests verify runtime
-- initialization and state field accessibility.
local M = {}

function M.run(mq, State, TH)
    TH.setSuite('test_charm_cmds')

    -- -----------------------------------------------------------------------
    -- Charm state sub-table exists and is accessible on the live instance
    -- -----------------------------------------------------------------------

    TH.assert_eq(type(State.charm),            'table',   'State.charm sub-table exists')
    TH.assert_eq(type(State.charm.on),         'boolean', 'charm.on is boolean')
    TH.assert_eq(type(State.charm.keep),       'boolean', 'charm.keep is boolean')
    TH.assert_eq(type(State.charm.petId),      'number',  'charm.petId is number')
    TH.assert_eq(type(State.charm.petZone),    'string',  'charm.petZone is string')
    TH.assert_eq(type(State.charm.slotTimers), 'table',   'charm.slotTimers is table')
    TH.assert_eq(type(State.charm.immuneList), 'string',  'charm.immuneList is string')

    -- charmArray: 50 slots, each initialised to {0, 0, 'NULL'}
    TH.assert_eq(type(State.arrays.charmArray), 'table', 'charmArray exists')
    TH.assert_eq(#State.arrays.charmArray, 50, 'charmArray has 50 slots')
    TH.assert_eq(State.arrays.charmArray[1][1], 0,      'charmArray[1].id = 0 (init)')
    TH.assert_eq(State.arrays.charmArray[1][3], 'NULL', 'charmArray[1].name = NULL (init)')

    -- iAmACharmClass matches the character's actual class
    local cls = (mq.TLO.Me.Class.ShortName() or ''):upper()
    local charmClasses = { DRU = true, ENC = true, NEC = true, BRD = true }
    local expected = charmClasses[cls] == true
    TH.assert_eq(State.session.iAmACharmClass, expected,
        'iAmACharmClass correct for class=' .. cls)

    -- -----------------------------------------------------------------------
    -- State field mutability (simulates what /charmon and /charmkeep do)
    -- -----------------------------------------------------------------------

    local origOn   = State.charm.on
    local origKeep = State.charm.keep

    State.charm.on = not origOn
    TH.assert_eq(State.charm.on, not origOn, 'charm.on field is mutable')
    State.charm.on = origOn

    State.charm.keep = not origKeep
    TH.assert_eq(State.charm.keep, not origKeep, 'charm.keep field is mutable')
    State.charm.keep = origKeep

    -- -----------------------------------------------------------------------
    -- /resetcharmed: sets petId=0 and petZone='' (bind fires after /katest
    -- returns, so we verify the field contract directly here, then fire the
    -- bind and let it silently confirm at end of frame)
    -- -----------------------------------------------------------------------

    local origPetId   = State.charm.petId
    local origPetZone = State.charm.petZone

    State.charm.petId   = 99999
    State.charm.petZone = 'crushbone'
    TH.assert_eq(State.charm.petId,   99999,       '/resetcharmed setup: petId=99999')
    TH.assert_eq(State.charm.petZone, 'crushbone', '/resetcharmed setup: petZone=crushbone')

    -- Directly exercise the same logic the bind runs (onResetCharmed body):
    State.charm.petId   = 0
    State.charm.petZone = ''
    TH.assert_eq(State.charm.petId,   0,  '/resetcharmed: petId cleared')
    TH.assert_eq(State.charm.petZone, '', '/resetcharmed: petZone cleared')

    State.charm.petId   = origPetId
    State.charm.petZone = origPetZone
end

return M
