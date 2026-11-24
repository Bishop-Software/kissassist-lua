-- modules/misc.lua
-- Port of the housekeeping in Sub DoMiscStuff (mac:8482): accept trades and
-- group invites, dismiss a wizard's familiar, drop a stuck cursor item into the
-- inventory. Plus the RezAcceptOn MQ2Rez setup from startup (mac:16403).
-- DoMiscStuff's MapSet/PaintMap and PullPause parts live in modules/pull/.
--
-- Split for testing: snapshot() reads the TLOs, decide() is pure and returns the
-- commands and messages, doMiscStuff() applies the mac's gate and sends them.
local mq     = require('mq')
local Config = require('modules.config')
local Utils  = require('modules.utils')

local Misc = {}

local _state

-- How long an item may sit on the cursor before it goes to the inventory
-- (mac CursorIDTimer 20s, CheckCursor mac:14049).
Misc.CURSOR_WAIT_MS = 20000

-- Loads [General] AcceptInvitesOn and RezAcceptOn (mac LoadIni, mac:14567-14568).
function Misc.init(state)
    _state = state
    _state.misc.acceptInvitesOn = tonumber(Config.get('General', 'AcceptInvitesOn', '1')) or 1
    _state.misc.rezAcceptOn     = Config.get('General', 'RezAcceptOn', '1|90')
end

-- Reads everything decide() needs from the game, once.
function Misc.snapshot()
    local trade = mq.TLO.Window('TradeWnd')
    return {
        tradeOpen     = trade.Open() == true,
        hisTradeReady = trade.HisTradeReady() == true,
        -- The Follow button only shows while an invite is pending.
        inviteShowing = mq.TLO.Window('GroupWindow').Child('GW_FollowButton').Open() == true,
        class         = mq.TLO.Me.Class.ShortName() or '',
        myName        = mq.TLO.Me.Name() or '',
        petName       = mq.TLO.Me.Pet.CleanName() or '',
        cursorID      = mq.TLO.Cursor.ID() or 0,
        cursorName    = mq.TLO.Cursor.Name() or '',
        freeInventory = mq.TLO.Me.FreeInventory() or 0,
    }
end

-- Pure DoMiscStuff housekeeping. Returns cmds, msgs (lists of strings) and
-- updates the cursor tracking in state.misc. now is mq.gettime() in ms.
function Misc.decide(snap, state, now)
    local cmds, msgs = {}, {}
    local m = state.misc

    -- Accept trades (mac:8486). The mac has no setting for this.
    if snap.tradeOpen and snap.hisTradeReady and snap.cursorID == 0 then
        cmds[#cmds + 1] = '/notify TradeWnd TRDW_Trade_Button leftmouseup'
    end

    -- Accept group invites (mac:8488).
    if snap.inviteShowing and (m.acceptInvitesOn or 0) ~= 0 then
        cmds[#cmds + 1] = '/invite'
    end

    -- Ditch a wizard's familiar (mac:8490).
    if snap.class == 'WIZ' and Utils.isFamiliarName(snap.petName, snap.myName) then
        cmds[#cmds + 1] = '/pet get lost'
    end

    -- Stuck cursor (mac:8492, CheckCursor mac:14034): warn when an item is first
    -- seen, drop it into the inventory once it has been there CURSOR_WAIT_MS.
    -- One /autoinventory per pass instead of the mac's blocking loop.
    if snap.cursorID == 0 then
        m.cursorID, m.cursorSince = 0, 0
    elseif snap.cursorID ~= m.cursorID then
        m.cursorID, m.cursorSince = snap.cursorID, now
        if snap.freeInventory > 0 then
            msgs[#msgs + 1] = string.format('%s is stuck on my cursor. Dropping it into inventory in %ds.',
                snap.cursorName, math.floor(Misc.CURSOR_WAIT_MS / 1000))
        else
            msgs[#msgs + 1] = 'HEY YOUR INVENTORY IS FULL!'
        end
    elseif now - m.cursorSince >= Misc.CURSOR_WAIT_MS and snap.freeInventory > 0 then
        cmds[#cmds + 1] = '/autoinventory'
    end

    return cmds, msgs
end

-- The /rez commands for a RezAcceptOn value 'A|P' (mac:16405-16414): A = 1 turns
-- MQ2Rez accept on (loot off, and pct P when P > 0); anything else turns it off.
function Misc.rezCommands(setting)
    local s = tostring(setting or '')
    local on  = s:match('^%s*([^|]*)') or ''
    local pct = tonumber(s:match('^[^|]*|%s*([^|]*)') or '') or 0
    if on:match('^%s*(.-)%s*$') ~= '1' then return { '/squelch /rez accept off' } end
    local cmds = { '/squelch /rez accept on', '/squelch /rez loot off' }
    pct = math.floor(pct)
    if pct > 0 then cmds[#cmds + 1] = '/squelch /rez pct ' .. pct end
    return cmds
end

-- Startup MQ2Rez setup (mac:16403). Config.checkPlugins() has already tried to
-- load MQ2Rez; without it, warn once and leave it. cmd is injectable for tests.
-- Returns true if the commands were sent.
function Misc.setupRez(cmd)
    if not mq.TLO.Plugin('MQ2Rez')() then
        printf('\ayKissAssist: MQ2Rez not loaded; RezAcceptOn (%s) not applied.', tostring(_state.misc.rezAcceptOn))
        return false
    end
    local run = cmd or mq.cmd
    for _, c in ipairs(Misc.rezCommands(_state.misc.rezAcceptOn)) do run(c) end
    return true
end

-- Main loop entry (mac:391). Like the mac, skipped in combat unless chain pulling.
function Misc.doMiscStuff()
    local s = _state
    local aggro = tonumber(s.combat.aggroTargetID) or 0
    if (s.pull.chainPull or 0) == 0 and (s.combat.combatStart or aggro > 0) then return end
    local cmds, msgs = Misc.decide(Misc.snapshot(), s, mq.gettime())
    for _, msg in ipairs(msgs) do printf('\ay%s', msg) end
    for _, cmd in ipairs(cmds) do mq.cmd(cmd) end
end

return Misc
