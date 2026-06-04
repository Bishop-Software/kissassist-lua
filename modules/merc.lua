local mq     = require('mq')
local Config = require('modules.config')

local Merc = {}

local _state, _utils

function Merc.init(state, utils)
    _state = state
    _utils = utils

    _state.merc.on       = tonumber(Config.get('Merc', 'MercOn',       '0')) or 0
    _state.merc.assistAt = tonumber(Config.get('Merc', 'MercAssistAt', '100')) or 100

    -- Detect merc name and inGroup at startup (mac:8571)
    local member1 = mq.TLO.Group.Member(1)
    if member1() and member1.Owner.Name() == (mq.TLO.Me.CleanName() or '') then
        _state.merc.myMerc = member1.Name() or ''
    end
    if (mq.TLO.Mercenary.State() or '') == 'Active' then
        _state.merc.inGroup = true
    end
end

-- Mirrors Sub MercsDoWhat (mac:8569-8590).
function Merc.check()
    local mercState = mq.TLO.Mercenary.State() or ''

    -- Track inGroup before the merc.on gate so the UI checkbox can appear
    -- even when the merc system starts disabled (mac:8573)
    if mercState == 'Active' then _state.merc.inGroup = true end

    if _state.merc.on == 0 then return end

    -- Detect merc name if not yet captured (mac:8571)
    if _state.merc.myMerc == '' then
        local member1 = mq.TLO.Group.Member(1)
        if member1() and member1.Owner.Name() == (mq.TLO.Me.CleanName() or '') then
            _state.merc.myMerc = member1.Name() or ''
        end
    end

    -- Auto-revive dead merc via UI button when it was previously in group (mac:8575)
    if _state.merc.inGroup
       and (mq.TLO.Window('MMGW_ManageWnd').Child('MMGW_SuspendButton').Enabled() or false)
       and mercState == 'DEAD' then
        mq.cmd('/notify MMGW_ManageWnd MMGW_SuspendButton LeftMouseUp')
    end

    local myTargetID = _state.combat.myTargetID or 0
    local isPuller   = (_state.session.role or ''):find('puller')

    if _state.merc.assisting == 0 then
        -- Not yet assisting: engage when target HP is at or below threshold (mac:8577)
        local mobPct = myTargetID ~= 0 and (mq.TLO.Spawn('id ' .. myTargetID).PctHPs() or 100) or 100
        if mobPct <= _state.merc.assistAt
           and mercState == 'Active'
           and (_state.combat.combatStart or (isPuller and (_state.pull.mob or 0) ~= 0)) then
            mq.cmd('/mercassist')
            _utils.debug('merc', 'MercsDoWhat1: assisting on %d', myTargetID)
            _state.merc.assisting = myTargetID
        end
    elseif myTargetID ~= 0 and _state.merc.assisting ~= myTargetID then
        -- Target changed: re-direct merc (mac:8582-8585)
        if mercState == 'Active' then
            mq.cmd('/mercassist')
            _utils.debug('merc', 'MercsDoWhat2: re-assisting on %d', myTargetID)
            _state.merc.assisting = myTargetID
        end
    elseif myTargetID == 0 then
        -- No target: clear assisting state (mac:8586-8588)
        _state.merc.assisting = 0
    end
end

return Merc
