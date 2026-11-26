-- tests/integration/test_camp_cmds.lua
-- Integration tests for /makecamphere, /stayhere, /campoff, /campon binds.
-- Covers test plan section S2.4.x.
--
-- Run in-game while kissassist is running: /katest camp_cmds
local M = {}

local D = 250  -- ms delay after each mq.cmd() to let the deferred bind execute

function M.run(mq, State, TH)
    TH.setSuite('test_camp_cmds')

    -- Snapshot original movement state for restore at end.
    local origReturn   = State.movement.returnToCamp
    local origCampX    = State.movement.campX
    local origCampY    = State.movement.campY
    local origCampZ    = State.movement.campZ
    local origCampZone = State.movement.campZone
    local origChase    = State.session.chaseAssist

    -- /makecamphere ---------------------------------------------------------
    State.movement.returnToCamp = false
    State.session.chaseAssist   = true

    local preX   = mq.TLO.Me.X()
    local preY   = mq.TLO.Me.Y()
    local preZ   = mq.TLO.Me.FloorZ()
    local zoneID = mq.TLO.Zone.ID()

    mq.cmd('/makecamphere') ; mq.delay(D)

    TH.assert_true(State.movement.returnToCamp,  '/makecamphere → returnToCamp=true')
    TH.assert_false(State.session.chaseAssist,   '/makecamphere → chaseAssist=false')
    TH.assert_near(State.movement.campX, preX, 1.0, '/makecamphere → campX matches Me.X')
    TH.assert_near(State.movement.campY, preY, 1.0, '/makecamphere → campY matches Me.Y')
    TH.assert_near(State.movement.campZ, preZ, 1.0, '/makecamphere → campZ matches Me.FloorZ')
    TH.assert_eq(State.movement.campZone, zoneID,   '/makecamphere → campZone matches Zone.ID')

    -- /campoff (this toon only) keeps the spot; /campon goes back to it ------
    -- (/campoff group isn't run here: it would break camp for the live group.)
    mq.cmd('/campoff') ; mq.delay(D)
    TH.assert_false(State.movement.returnToCamp, '/campoff → returnToCamp=false')
    TH.assert_near(State.movement.campX, preX, 1.0, '/campoff → camp spot kept')

    State.session.chaseAssist = true
    mq.cmd('/campon') ; mq.delay(D)
    TH.assert_true(State.movement.returnToCamp, '/campon → returnToCamp=true')
    TH.assert_false(State.session.chaseAssist,  '/campon → chaseAssist=false')
    TH.assert_near(State.movement.campX, preX, 1.0, '/campon → same camp spot')

    State.movement.returnToCamp = false
    State.movement.campX, State.movement.campY = 0, 0
    mq.cmd('/campon') ; mq.delay(D)
    TH.assert_false(State.movement.returnToCamp, '/campon with no camp → stays off')

    -- /stayhere ------------------------------------------------------------
    State.movement.returnToCamp = false
    State.session.chaseAssist   = true

    local preX2 = mq.TLO.Me.X()
    local preY2 = mq.TLO.Me.Y()

    mq.cmd('/stayhere') ; mq.delay(D)

    TH.assert_true(State.movement.returnToCamp, '/stayhere → returnToCamp=true')
    TH.assert_false(State.session.chaseAssist,  '/stayhere → chaseAssist=false')
    TH.assert_near(State.movement.campX, preX2, 1.0, '/stayhere → campX matches Me.X')
    TH.assert_near(State.movement.campY, preY2, 1.0, '/stayhere → campY matches Me.Y')

    -- Restore original state
    State.movement.returnToCamp = origReturn
    State.movement.campX        = origCampX
    State.movement.campY        = origCampY
    State.movement.campZ        = origCampZ
    State.movement.campZone     = origCampZone
    State.session.chaseAssist   = origChase
end

return M
