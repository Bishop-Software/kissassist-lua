-- tests/unit/test_comms_chat_relay.lua
-- #243: guild/fellowship chat relay over actors (Event_GUEQBC / Event_FSEQBC,
-- mac:11589-11607), gated by [General] ChatRelay 1 guild / 2 fellowship / 3 both.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_comms_chat_relay')

    local sent = {}
    package.loaded['actors'] = { register = function() return { send = function(_, msg) sent[#sent + 1] = msg end } end }
    package.loaded['modules.comms'] = nil
    local Comms = require('modules.comms')

    local state = { session = { danNetOn = false } }
    MockMQ.reset()
    Comms.init(state, { debug = function() end })
    TH.assert_eq(state.session.chatRelay, 0, 'ChatRelay default 0: relay off')

    local function env(guild, fsID)
        MockMQ.reset()
        MockMQ.set('TLO.Me.CleanName', 'Relayer')
        MockMQ.set('TLO.Me.Guild', guild)
        MockMQ.set('TLO.Me.Fellowship.ID', fsID)
    end

    -- ---- sending ----
    env('Some Guild', 77)
    sent = {}
    Comms.relayChat('guild', 'Speaker', "'hello all'")
    TH.assert_eq(#sent, 0, 'relay off: nothing sent')

    state.session.chatRelay = 1
    Comms.relayChat('guild', 'Speaker', "'hello all'")
    TH.assert_eq(#sent, 1, 'ChatRelay 1: guild line sent')
    TH.assert_eq(sent[1].msgType, 'CHATRELAY', 'message type CHATRELAY')
    TH.assert_eq(sent[1].text, 'hello all', 'EQ quotes stripped')
    TH.assert_eq(sent[1].guild, 'Some Guild', 'sender guild attached')
    Comms.relayChat('fellowship', 'Speaker', "'hi'")
    TH.assert_eq(#sent, 1, 'ChatRelay 1: fellowship not sent')

    state.session.chatRelay = 2
    Comms.relayChat('fellowship', 'Speaker', "'hi'")
    TH.assert_eq(#sent, 2, 'ChatRelay 2: fellowship line sent')
    TH.assert_eq(sent[2].fellowship, 77, 'sender fellowship ID attached')
    Comms.relayChat('guild', 'Speaker', "'x'")
    TH.assert_eq(#sent, 2, 'ChatRelay 2: guild not sent')

    state.session.chatRelay = 3
    Comms.relayChat('guild', 'Relayer', "'my own line'")
    TH.assert_eq(#sent, 2, 'own lines not relayed')
    Comms.relayChat('guild', 'Speaker', "'both'")
    Comms.relayChat('fellowship', 'Speaker', "'both'")
    TH.assert_eq(#sent, 4, 'ChatRelay 3: both channels sent')

    -- ---- receiving ----
    local printed = {}
    local realPrintf = printf
    printf = function(fmt, ...) printed[#printed + 1] = string.format(fmt, ...) end  -- luacheck: ignore 121

    env('Other Guild', 5)
    Comms._onChatRelay({ channel = 'guild', speaker = 'Speaker', text = 'raid at 8', guild = 'Some Guild' })
    TH.assert_eq(#printed, 1, 'not in that guild: printed')
    TH.assert_true(printed[1] and printed[1]:find('Speaker tells Guild: raid at 8', 1, true) ~= nil, 'format: <who> tells Guild: <text>')

    Comms._onChatRelay({ channel = 'guild', speaker = 'Speaker', text = 'raid at 8', guild = 'Some Guild' })
    TH.assert_eq(#printed, 1, 'same line from a second relayer: printed once')

    env('Some Guild', 5)
    Comms._onChatRelay({ channel = 'guild', speaker = 'Speaker', text = 'new line', guild = 'Some Guild' })
    TH.assert_eq(#printed, 1, 'in the same guild: skipped (already seen in game)')

    Comms._onChatRelay({ channel = 'fellowship', speaker = 'Speaker', text = 'camp up', fellowship = 77 })
    TH.assert_eq(#printed, 2, 'other fellowship: printed')
    TH.assert_true(printed[2] and printed[2]:find('Speaker tells Fellowship: camp up', 1, true) ~= nil, 'format: <who> tells Fellowship: <text>')

    env('', 77)
    Comms._onChatRelay({ channel = 'fellowship', speaker = 'Speaker', text = 'again', fellowship = 77 })
    TH.assert_eq(#printed, 2, 'same fellowship: skipped')

    Comms._onChatRelay({ channel = 'tell', speaker = 'Speaker', text = 'x' })
    TH.assert_eq(#printed, 2, 'unknown channel ignored')

    printf = realPrintf  -- luacheck: ignore 121
    package.loaded['actors'] = nil
    package.loaded['modules.comms'] = nil
end

return M
