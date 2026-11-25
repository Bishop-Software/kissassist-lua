-- tests/unit/test_misc.lua
-- Tests DoMiscStuff housekeeping and RezAcceptOn (#320): Misc.decide (trades,
-- invites, familiar, stuck cursor), the doMiscStuff combat gate, rezCommands,
-- setupRez and the AcceptInvitesOn / RezAcceptOn load.
local M = {}

function M.run(TH, MockMQ)
    local Config = require('modules.config')
    local Misc   = require('modules.misc')

    TH.setSuite('test_misc')

    local TRADE = '/notify TradeWnd TRDW_Trade_Button leftmouseup'

    local function newState()
        return {
            misc   = { acceptInvitesOn = 1, rezAcceptOn = '1|90', cursorID = 0, cursorSince = 0 },
            combat = { combatStart = false, aggroTargetID = '' },
            pull   = { chainPull = 0 },
        }
    end

    -- A quiet snapshot: nothing to do. Fields can be overridden.
    local function snap(over)
        local s = {
            tradeOpen = false, hisTradeReady = false, inviteShowing = false,
            class = 'WAR', myName = 'Toon', petName = '',
            cursorID = 0, cursorName = '', freeInventory = 10,
        }
        for k, v in pairs(over or {}) do s[k] = v end
        return s
    end

    local function has(list, item)
        for _, v in ipairs(list) do if v == item then return true end end
        return false
    end

    -- ── decide: nothing to do ───────────────────────────────────────────────
    local st = newState()
    local cmds, msgs = Misc.decide(snap(), st, 0)
    TH.assert_eq(#cmds + #msgs, 0, 'decide: quiet snapshot → no commands or messages')

    -- ── trades ──────────────────────────────────────────────────────────────
    cmds = Misc.decide(snap({ tradeOpen = true, hisTradeReady = true }), newState(), 0)
    TH.assert_true(has(cmds, TRADE), 'trade: open + his side ready → click Trade')
    cmds = Misc.decide(snap({ tradeOpen = true, hisTradeReady = false }), newState(), 0)
    TH.assert_false(has(cmds, TRADE), 'trade: his side not ready → wait')
    cmds = Misc.decide(snap({ tradeOpen = true, hisTradeReady = true, cursorID = 55, cursorName = 'Bread' }),
        newState(), 0)
    TH.assert_false(has(cmds, TRADE), 'trade: item on the cursor → no click')
    cmds = Misc.decide(snap({ hisTradeReady = true }), newState(), 0)
    TH.assert_false(has(cmds, TRADE), 'trade: window closed → no click')

    -- ── invites ─────────────────────────────────────────────────────────────
    cmds = Misc.decide(snap({ inviteShowing = true }), newState(), 0)
    TH.assert_true(has(cmds, '/invite'), 'invite: pending + AcceptInvitesOn=1 → /invite')
    st = newState(); st.misc.acceptInvitesOn = 0
    cmds = Misc.decide(snap({ inviteShowing = true }), st, 0)
    TH.assert_false(has(cmds, '/invite'), 'invite: AcceptInvitesOn=0 → ignored')
    cmds = Misc.decide(snap(), newState(), 0)
    TH.assert_false(has(cmds, '/invite'), 'invite: none pending → nothing')

    -- ── familiar ────────────────────────────────────────────────────────────
    cmds = Misc.decide(snap({ class = 'WIZ', petName = 'Toon`s familiar' }), newState(), 0)
    TH.assert_true(has(cmds, '/pet get lost'), 'familiar: WIZ with Name`s familiar → /pet get lost')
    cmds = Misc.decide(snap({ class = 'WIZ', petName = "Toon's familiar" }), newState(), 0)
    TH.assert_true(has(cmds, '/pet get lost'), 'familiar: apostrophe spelling also matches')
    cmds = Misc.decide(snap({ class = 'MAG', petName = 'Toon`s familiar' }), newState(), 0)
    TH.assert_false(has(cmds, '/pet get lost'), 'familiar: non-WIZ → left alone (mac WIZ only)')
    cmds = Misc.decide(snap({ class = 'WIZ', petName = 'Other`s familiar' }), newState(), 0)
    TH.assert_false(has(cmds, '/pet get lost'), 'familiar: someone else\'s name → left alone')
    cmds = Misc.decide(snap({ class = 'WIZ', petName = 'Gobaner' }), newState(), 0)
    TH.assert_false(has(cmds, '/pet get lost'), 'familiar: a real pet → left alone')

    -- ── stuck cursor ────────────────────────────────────────────────────────
    local WAIT = Misc.CURSOR_WAIT_MS
    st = newState()
    local item = snap({ cursorID = 101, cursorName = 'Rod of Mystical Transvergance' })
    cmds, msgs = Misc.decide(item, st, 1000)
    TH.assert_eq(#msgs, 1, 'cursor: first sight → one warning')
    TH.assert_eq(msgs[1], 'Rod of Mystical Transvergance is stuck on my cursor. Dropping it into inventory in 20s.',
        'cursor: warning names the item and the wait')
    TH.assert_false(has(cmds, '/autoinventory'), 'cursor: not dropped on first sight')
    TH.assert_eq(st.misc.cursorID, 101, 'cursor: item remembered')

    cmds, msgs = Misc.decide(item, st, 1000 + WAIT - 1)
    TH.assert_eq(#msgs, 0, 'cursor: warning not repeated')
    TH.assert_false(has(cmds, '/autoinventory'), 'cursor: not dropped before 20 s')

    cmds = Misc.decide(item, st, 1000 + WAIT)
    TH.assert_true(has(cmds, '/autoinventory'), 'cursor: dropped at 20 s')
    cmds = Misc.decide(item, st, 1000 + WAIT + 50)
    TH.assert_true(has(cmds, '/autoinventory'), 'cursor: keeps trying each pass while it is still there')

    -- A different item restarts the timer
    cmds, msgs = Misc.decide(snap({ cursorID = 202, cursorName = 'Bread' }), st, 1000 + WAIT + 100)
    TH.assert_eq(#msgs, 1, 'cursor: new item → new warning')
    TH.assert_false(has(cmds, '/autoinventory'), 'cursor: new item → timer restarted')
    TH.assert_eq(st.misc.cursorSince, 1000 + WAIT + 100, 'cursor: start time reset for the new item')

    -- Empty cursor resets, so the same item coming back warns again
    Misc.decide(snap(), st, 50000)
    TH.assert_eq(st.misc.cursorID, 0, 'cursor: empty → tracking reset')
    msgs = select(2, Misc.decide(snap({ cursorID = 202, cursorName = 'Bread' }), st, 51000))
    TH.assert_eq(#msgs, 1, 'cursor: same item after an empty cursor warns again')

    -- Full inventory: warn, never /autoinventory until space frees up
    st = newState()
    local full = snap({ cursorID = 303, cursorName = 'Water', freeInventory = 0 })
    msgs = select(2, Misc.decide(full, st, 0))
    TH.assert_eq(msgs[1], 'HEY YOUR INVENTORY IS FULL!', 'cursor: full inventory → mac warning')
    cmds = Misc.decide(full, st, WAIT * 2)
    TH.assert_false(has(cmds, '/autoinventory'), 'cursor: full inventory → no /autoinventory')
    cmds = Misc.decide(snap({ cursorID = 303, cursorName = 'Water', freeInventory = 1 }), st, WAIT * 2)
    TH.assert_true(has(cmds, '/autoinventory'), 'cursor: dropped once a slot frees up')

    -- ── doMiscStuff: the mac's combat gate (mac:8483) ───────────────────────
    local realSnapshot = Misc.snapshot
    Misc.snapshot = function() return snap({ inviteShowing = true }) end

    local function gated(mutate)
        MockMQ.reset()
        st = newState()
        Misc.init(st)  -- Config has no _cfg here, so defaults load
        mutate(st)
        Misc.doMiscStuff()
        return MockMQ.cmdCalled('/invite')
    end
    TH.assert_true(gated(function() end), 'gate: out of combat → runs')
    TH.assert_false(gated(function(s) s.combat.combatStart = true end), 'gate: in combat → skipped')
    TH.assert_false(gated(function(s) s.combat.aggroTargetID = '1234' end), 'gate: mob on me → skipped')
    TH.assert_true(gated(function(s) s.combat.combatStart = true; s.pull.chainPull = 1 end),
        'gate: in combat but chain pulling → runs')
    Misc.snapshot = realSnapshot

    -- ── rezCommands ─────────────────────────────────────────────────────────
    local r = Misc.rezCommands('1|90')
    TH.assert_eq(#r, 3, 'rez 1|90: three commands')
    TH.assert_eq(r[1], '/squelch /rez accept on', 'rez 1|90: accept on')
    TH.assert_eq(r[2], '/squelch /rez loot off', 'rez 1|90: loot off')
    TH.assert_eq(r[3], '/squelch /rez pct 90', 'rez 1|90: pct 90')
    TH.assert_eq(#Misc.rezCommands('1'), 2, 'rez 1: no pct')
    TH.assert_eq(#Misc.rezCommands('1|0'), 2, 'rez 1|0: no pct')
    TH.assert_eq(Misc.rezCommands(' 1 | 75 ')[3], '/squelch /rez pct 75', 'rez: spaces ignored')
    for _, v in ipairs({ '0', '0|90', '', 'yes' }) do
        local c = Misc.rezCommands(v)
        TH.assert_true(#c == 1 and c[1] == '/squelch /rez accept off', 'rez "' .. v .. '": accept off')
    end
    TH.assert_eq(Misc.rezCommands(nil)[1], '/squelch /rez accept off', 'rez nil: accept off')

    -- ── setupRez ────────────────────────────────────────────────────────────
    st = newState()
    Misc.init(st)
    st.misc.rezAcceptOn = '1|80'
    MockMQ.set('TLO.Plugin', function() return function() return 'MQ2Rez' end end)
    local sent = {}
    TH.assert_true(Misc.setupRez(function(c) sent[#sent + 1] = c end), 'setupRez: MQ2Rez loaded → sent')
    TH.assert_eq(sent[3], '/squelch /rez pct 80', 'setupRez: uses state.misc.rezAcceptOn')
    MockMQ.set('TLO.Plugin', function() return function() return nil end end)
    sent = {}
    TH.assert_false(Misc.setupRez(function(c) sent[#sent + 1] = c end), 'setupRez: MQ2Rez missing → not sent')
    TH.assert_eq(#sent, 0, 'setupRez: nothing sent without MQ2Rez')

    -- ── init: settings load ─────────────────────────────────────────────────
    Config._setCfg({ General = { AcceptInvitesOn = '0', RezAcceptOn = '0|50' } })
    st = newState()
    Misc.init(st)
    TH.assert_eq(st.misc.acceptInvitesOn, 0, 'init: AcceptInvitesOn loaded as a number')
    TH.assert_eq(st.misc.rezAcceptOn, '0|50', 'init: RezAcceptOn loaded')
    Config._setCfg({})
    st = newState()
    Misc.init(st)
    TH.assert_eq(st.misc.acceptInvitesOn, 1, 'init: AcceptInvitesOn defaults to 1')
    TH.assert_eq(st.misc.rezAcceptOn, '1|90', 'init: RezAcceptOn defaults to 1|90')

    -- ── CanIDoStuff: decideBusy (mac:8532) ──────────────────────────────────
    local function bsnap(over)
        local b = { combatState = 'COMBAT', moving = false, meState = 'STAND', invis = false,
                    stunned = false, ducking = false, class = 'CLR', lootOpen = false, window = nil }
        for k, v in pairs(over or {}) do b[k] = v end
        return b
    end
    local function bstate(over)
        local b = { combat = { combatStart = false, aggroTargetID = '' }, session = { chaseAssist = false } }
        for k, v in pairs(over or {}) do b[k] = v end
        return b
    end
    local busy = Misc.decideBusy

    TH.assert_nil(busy(bsnap(), bstate()), 'busy: combat state, nothing holding -> free')
    TH.assert_nil(busy(bsnap({ combatState = 'ACTIVE', window = 'MerchantWnd' }), bstate()),
        'busy: not in the combat state -> free even with a merchant open')
    TH.assert_nil(busy(bsnap({ window = 'BankWnd' }),
        bstate({ combat = { combatStart = true, aggroTargetID = '' } })), 'busy: our own fight -> free')
    TH.assert_nil(busy(bsnap({ window = 'BankWnd' }),
        bstate({ combat = { combatStart = false, aggroTargetID = '123' } })), 'busy: aggro target -> free')

    TH.assert_eq(busy(bsnap({ window = 'MerchantWnd' }), bstate()), 'MerchantWnd open', 'busy: merchant window')
    TH.assert_eq(busy(bsnap({ window = 'SpellBookWnd' }), bstate()), 'SpellBookWnd open', 'busy: spellbook')
    TH.assert_eq(busy(bsnap({ moving = true }), bstate()), 'moving', 'busy: moving')
    TH.assert_eq(busy(bsnap({ meState = 'FEIGN' }), bstate()), 'feigned', 'busy: feigned')
    TH.assert_eq(busy(bsnap({ stunned = true }), bstate()), 'stunned', 'busy: stunned')
    TH.assert_eq(busy(bsnap({ ducking = true }), bstate()), 'ducking', 'busy: ducking')
    TH.assert_eq(busy(bsnap({ meState = 'BIND' }), bstate()), 'binding wounds', 'busy: binding wounds')
    TH.assert_nil(busy(bsnap({ meState = 'BIND', lootOpen = true }), bstate()), 'busy: BIND with the loot window -> free')

    TH.assert_eq(busy(bsnap({ invis = true }), bstate()), 'invisible', 'busy: invisible, not chasing')
    TH.assert_nil(busy(bsnap({ invis = true }), bstate({ session = { chaseAssist = true } })),
        'busy: invisible while chasing -> free')
    TH.assert_nil(busy(bsnap({ invis = true, class = 'ROG' }), bstate()), 'busy: invisible rogue -> free')

    -- canIDoStuff: reads the game through the mock
    MockMQ.reset()
    MockMQ.set('TLO.Me.CombatState', 'COMBAT')
    MockMQ.set('TLO.Window', function(w)
        return { Open = function() return w == 'GiveWnd' end }
    end)
    st = newState()
    st.combat.combatStart, st.combat.aggroTargetID = false, ''
    st.session = { chaseAssist = false, iAmABard = false }
    Misc.init(st)
    TH.assert_false(Misc.canIDoStuff(), 'canIDoStuff: give window open in the combat state -> hold')
    MockMQ.set('TLO.Me.CombatState', 'ACTIVE')
    TH.assert_true(Misc.canIDoStuff(), 'canIDoStuff: out of the combat state -> go on')
end

return M
