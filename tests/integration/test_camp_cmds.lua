-- tests/integration/test_camp_cmds.lua
-- Integration tests for /makecamphere and /kactl mode (control API phase 2, #362).
-- Covers test plan section S2.4.x.
--
-- Not run here, since they would move the live group's other boxes:
-- /stayhere, /chaseme and any /kactl mode ... group|others other than the
-- /makecamphere already run (it sends the group to this toon's spot).
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
    local origWho      = State.movement.whoToChase

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
    TH.assert_eq(mq.TLO.KissAssist.Mode(), 'camp',  '${KissAssist.Mode} → camp')

    -- /kactl mode manual keeps the spot; /kactl mode camp resume goes back ----
    mq.cmd('/kactl mode manual') ; mq.delay(D)
    TH.assert_false(State.movement.returnToCamp, '/kactl mode manual → returnToCamp=false')
    TH.assert_near(State.movement.campX, preX, 1.0, '/kactl mode manual → camp spot kept')
    TH.assert_eq(mq.TLO.KissAssist.Mode(), 'manual', '${KissAssist.Mode} → manual')

    State.session.chaseAssist = true
    mq.cmd('/kactl mode camp resume') ; mq.delay(D)
    TH.assert_true(State.movement.returnToCamp, '/kactl mode camp resume → returnToCamp=true')
    TH.assert_false(State.session.chaseAssist,  '/kactl mode camp resume → chaseAssist=false')
    TH.assert_near(State.movement.campX, preX, 1.0, '/kactl mode camp resume → same camp spot')

    State.movement.returnToCamp = false
    State.movement.campX, State.movement.campY = 0, 0
    mq.cmd('/kactl mode camp resume') ; mq.delay(D)
    TH.assert_false(State.movement.returnToCamp, '/kactl mode camp resume with no camp → stays off')

    mq.cmd('/kactl mode camp here') ; mq.delay(D)
    TH.assert_true(State.movement.returnToCamp, '/kactl mode camp here → returnToCamp=true')
    TH.assert_near(State.movement.campX, preX, 1.0, '/kactl mode camp here → camp at Me.X')

    -- /kactl mode chase -------------------------------------------------------
    local me = mq.TLO.Me.CleanName() or ''
    mq.cmd('/kactl mode chase ' .. me) ; mq.delay(D)
    TH.assert_true(State.session.chaseAssist,    '/kactl mode chase <name> → chaseAssist=true')
    TH.assert_false(State.movement.returnToCamp, '/kactl mode chase <name> → returnToCamp=false')
    TH.assert_eq(State.movement.whoToChase, me,  '/kactl mode chase <name> → whoToChase set')
    TH.assert_eq(mq.TLO.KissAssist.Mode(), 'chase', '${KissAssist.Mode} → chase')

    -- bad arguments change nothing
    mq.cmd('/kactl mode camp clear') ; mq.delay(D)
    TH.assert_true(State.session.chaseAssist, '/kactl mode camp clear (bad) → nothing changed')

    -- Restore original state
    State.movement.returnToCamp = origReturn
    State.movement.campX        = origCampX
    State.movement.campY        = origCampY
    State.movement.campZ        = origCampZ
    State.movement.campZone     = origCampZone
    State.session.chaseAssist   = origChase
    State.movement.whoToChase   = origWho
end

return M
