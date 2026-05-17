local mq = require('mq')

local Loot = {}
local _state, _utils

function Loot.init(state, utils)
    _state = state
    _utils = utils

    if not mq.TLO.Plugin('MQ2AutoLoot').IsLoaded() then
        printf('\arKissAssist: \awMQ2AutoLoot not loaded — looting disabled.')
        _state.loot.on = 0
    end
end

function Loot.sell()    mq.cmd('/autoloot sell')    end
function Loot.deposit() mq.cmd('/autoloot deposit') end
function Loot.barter()  mq.cmd('/autoloot barter')  end

return Loot
