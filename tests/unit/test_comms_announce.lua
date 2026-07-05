-- tests/unit/test_comms_announce.lua
-- Regression test for the broadcast parse-error bug: rez/cure announcements went
-- out as `/bc o "msg"`, which EQBC cannot parse. EQBC is deprecated in the Lua
-- port, so Comms.announce routes over DanNet (/dgtell all) when peers are present,
-- else a local /echo. Mirrors .mac Sub BroadCast (mac:12820).
--
-- \a in a Lua string is the bell byte (0x07) — that IS the MQ colour escape, so
-- '\ao' == an orange colour code and the DanNet assertions below use it literally.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_comms_announce')

    -- Comms requires 'actors' at load; stub it so Comms.init can register a mailbox
    -- without the live actor system.
    package.loaded['actors'] = { register = function() return { send = function() end } end }
    package.loaded['modules.comms'] = nil
    local Comms = require('modules.comms')

    local state = { session = { danNetOn = false } }

    -- Program which plugins/TLOs are "present". Plugin is invoked as
    -- mq.TLO.Plugin(name)() — a double call — so the inner result must itself be
    -- callable (return a function, matching the TLO proxy).
    local function setEnv(opts)
        MockMQ.reset()
        MockMQ.set('TLO.Plugin', function(name)
            local loaded = (name == 'MQ2DanNet' and opts.danNetLoaded) or false
            return function() return loaded end
        end)
        MockMQ.set('TLO.DanNet.PeerCount', opts.peers or 0)
        state.session.danNetOn = opts.danNetOn or false
    end

    -- Comms.init probes mq.TLO.Plugin('MQ2DanNet')(), so seed a benign env first.
    setEnv({})
    Comms.init(state, { debug = function() end })

    -- 1. DanNet with peers → /dgtell all with an MQ colour code ------------------
    setEnv({ danNetOn = true, danNetLoaded = true, peers = 3 })
    Comms.announce('CURING: >> Gerath << with Pure Blood', 'o')
    TH.assert_true(MockMQ.cmdCalled('/dgtell all \ao CURING: >> Gerath << with Pure Blood \aw'),
        'DanNet peers → /dgtell all with colour')
    TH.assert_false(MockMQ.cmdMatched('/bc '), 'never emits an EQBC /bc command')

    -- 2. Neither connected → local /echo fallback --------------------------------
    setEnv({})
    Comms.announce('BATTLE REZZED =>> Gerath <<=', 'o')
    TH.assert_true(MockMQ.cmdCalled('/echo BATTLE REZZED =>> Gerath <<='),
        'no DanNet → /echo fallback')

    -- 3. DanNet enabled but zero peers → /echo (not a silent /dgtell) ------------
    setEnv({ danNetOn = true, danNetLoaded = true, peers = 0 })
    Comms.announce('REZZED =>> Gerath <<=', 'o')
    TH.assert_true(MockMQ.cmdCalled('/echo REZZED =>> Gerath <<='),
        'DanNet with 0 peers → /echo fallback')

    -- 4. danNetOn flag off (plugin present) → /echo, not /dgtell -----------------
    setEnv({ danNetLoaded = true, peers = 3 })  -- danNetOn stays false
    Comms.announce('REZZED =>> Braelynn <<=', 'o')
    TH.assert_true(MockMQ.cmdCalled('/echo REZZED =>> Braelynn <<='),
        'danNetOn=false → /echo even with peers')

    -- 5. Default colour is white when omitted ------------------------------------
    setEnv({ danNetOn = true, danNetLoaded = true, peers = 2 })
    Comms.announce('plain message')
    TH.assert_true(MockMQ.cmdCalled('/dgtell all \aw plain message \aw'),
        'omitted colour defaults to w')

    -- Cleanup so later suites re-require real modules.
    package.loaded['actors']        = nil
    package.loaded['modules.comms'] = nil
end

return M
