function DebugPrint(...)
    if not Config.debug then return end
    local msg = {}
    for _, v in ipairs({...}) do
        msg[#msg+1] = tostring(v)
    end
    print("^6[METEO SPEAKERS]^0 " .. table.concat(msg, ", "))
end

function GetTarget()
    if Config.target ~= 'auto' then
        if Config.target == 'ox_target' or Config.target == 'qb-target' then
            return Config.target
        end
    end
    if GetResourceState('ox_target') == 'started' then
        return 'ox_target'
    elseif GetResourceState('qb-target') == 'started' then
        return 'qb-target'
    end
    return nil
end

function GetInventory()
    if Config.inventory ~= 'auto' then
        if Config.inventory == 'ox_inventory' or Config.inventory == 'qb-inventory' then
            return Config.inventory
        end
    end
    if GetResourceState('ox_inventory') == 'started' then
        return 'ox_inventory'
    elseif GetResourceState('qb-inventory') == 'started'
        or GetResourceState(Rename.prefix .. 'inventory') == 'started' then
        return 'qb-inventory'
    end
    return nil
end