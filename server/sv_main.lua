local QBCore = exports['qb-core']:GetCoreObject()
local speakers = {}

-- Vehicle "speakers" exist only while someone is actively casting to a vehicle
-- from their phone. Keyed by uuid ('veh:<netId>').
local vehicleSpeakers = {}

local connections = {}

local function getVehicleUuid(netId) return 'veh:' .. tostring(netId) end
local function isVehicleSpeakerUuid(uuid)
    return type(uuid) == 'string' and uuid:sub(1, 4) == 'veh:'
end

local function generateUUID()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

local function generateSpeakerCode()
    local chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    local len = #chars
    for _ = 1, 20 do
        local code = ''
        for _ = 1, 4 do
            local idx = math.random(1, len)
            code = code .. chars:sub(idx, idx)
        end
        local taken = false
        for _, sp in ipairs(speakers) do
            if sp.code == code then taken = true; break end
        end
        if not taken then return code end
    end

    return string.format('%04X', math.random(0, 0xffff))
end

local function isPlayerAdmin(source)
    if QBCore.Functions.HasPermission(source, 'admin')
    or QBCore.Functions.HasPermission(source, 'god')
    or IsPlayerAceAllowed(source, 'command') then
        return true
    end
    return false
end

-- vehicle keys check
local function hasVehicleKeys(source, veh)
    if not Config.requireVehicleKeys then return true end
    if not source or not veh or veh == 0 or not DoesEntityExist(veh) then
        return false
    end

    -- qbx_vehiclekeys
    if GetResourceState('qbx_vehiclekeys') == 'started' then
        local sessionId = Entity(veh).state.sessionId
        local keysList = Player(source).state.keysList
        if sessionId and keysList and keysList[sessionId] then return true end

        local owner = Entity(veh).state.owner
        if owner then
            local player = QBCore.Functions.GetPlayer(source)
            if player and player.PlayerData.citizenid == owner then
                return true
            end
        end
        return false
    end

    -- Add other vehicle keys scripts below
    return true
end

local function getPlacedCount(citizenid)
    local count = 0
    for _, sp in ipairs(speakers) do
        if sp.citizenid == citizenid then
            count = count + 1
        end
    end
    return count
end

local function findSpeaker(uuid)
    if vehicleSpeakers[uuid] then
        return vehicleSpeakers[uuid], nil
    end
    for i, sp in ipairs(speakers) do
        if sp.uuid == uuid then
            return sp, i
        end
    end
    return nil, nil
end

local function addItem(source, item, amount)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false end
    local inventory = GetInventory()
    if inventory == 'ox_inventory' then
        return exports.ox_inventory:AddItem(source, item, amount or 1)
    else
        local success = player.Functions.AddItem(item, amount or 1)
        if success then
            TriggerClientEvent('qb-inventory:client:ItemBox', source, QBCore.Shared.Items[item], 'add', amount)
        end
        return success
    end
end

local function removeItem(source, item, amount, slot)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false end
    local inventory = GetInventory()
    if inventory == 'ox_inventory' then
        return exports.ox_inventory:RemoveItem(source, item, amount or 1, nil, slot)
    else
        if not slot then
            local foundItem = player.Functions.GetItemByName(item)
            slot = foundItem and foundItem.slot
        end
        local success = player.Functions.RemoveItem(item, amount or 1, slot)
        if success then
            TriggerClientEvent('qb-inventory:client:ItemBox', source, QBCore.Shared.Items[item], 'remove', amount)
        end
        return success
    end
end

local activeSounds = {}

local function nowMs() return GetGameTimer() end

local function recordSoundStart(uuid, url, volume, sp)
    activeSounds[uuid] = {
        url = url,
        volume = volume or Config.defaultVolume,
        coords = sp.coords and vector3(sp.coords.x, sp.coords.y, sp.coords.z) or nil,
        distance = sp.distance,
        seekTime = 0,
        seekedAt = nowMs(),
        paused = false,
    }
end

local function recordSeek(uuid, time)
    local s = activeSounds[uuid]
    if not s then return end
    s.seekTime = tonumber(time) or 0
    s.seekedAt = nowMs()
end

local function recordPause(uuid)
    local s = activeSounds[uuid]
    if not s or s.paused then return end

    s.seekTime = s.seekTime + (nowMs() - s.seekedAt) / 1000
    s.seekedAt = nowMs()
    s.paused = true
end

local function recordResume(uuid)
    local s = activeSounds[uuid]
    if not s or not s.paused then return end
    s.paused = false
    s.seekedAt = nowMs()
end

local function recordStop(uuid)
    activeSounds[uuid] = nil
end

local function recordVolume(uuid, volume)
    local s = activeSounds[uuid]
    if not s then return end
    s.volume = tonumber(volume) or s.volume
end

local function estimateCurrentPosition(uuid)
    local s = activeSounds[uuid]
    if not s then return 0 end
    if s.paused then return s.seekTime end
    return s.seekTime + (nowMs() - s.seekedAt) / 1000
end

-- Push current stream to one player. Used on zone enter / reconnect.
local function syncSpeakerForPlayer(source, uuid)
    local s = activeSounds[uuid]
    if not s then return end
    if not source or not GetPlayerName(source) then return end

    local position = estimateCurrentPosition(uuid)
    TriggerClientEvent('meteo-speakers:client:audio:play', source, {
        uuid = uuid,
        url = s.url,
        volume = s.volume,
        startTime = position,
        paused = s.paused or false,
    })
end

local function stopSpeakerSound(uuid)
    TriggerClientEvent('meteo-speakers:client:audio:stop', -1, { uuid = uuid })
    recordStop(uuid)
end

local function broadcastConnectionChange(uuid)
    local driver = connections[uuid]
    TriggerClientEvent('meteo-speakers:client:connectionChanged', -1, uuid, driver and {
        citizenid = driver.citizenid,
        accountId = driver.accountId,
        source = driver.source,
        song = driver.song,
    } or nil)
end

local function maybeRetireVehicleSpeaker(uuid)
    if vehicleSpeakers[uuid] then
        vehicleSpeakers[uuid] = nil
        TriggerClientEvent('meteo-speakers:client:removeSpeaker', -1, uuid)
    end
end

local function stopDriverVehicleMonitor(uuid, driverSource)
    if isVehicleSpeakerUuid(uuid) and driverSource and GetPlayerName(driverSource) then
        TriggerClientEvent('meteo-speakers:client:stopVehicleCastMonitor', driverSource)
    end
end

local function releaseConnection(uuid, reason, stopAudio)

    if stopAudio then
        stopSpeakerSound(uuid)
    end

    local driver = connections[uuid]
    if not driver then
        maybeRetireVehicleSpeaker(uuid)
        return
    end

    local driverSource = driver.source
    connections[uuid] = nil

    if driverSource and GetPlayerName(driverSource) then
        TriggerClientEvent('meteo-speakers:client:phoneDisconnected', driverSource, uuid, reason or 'forced')
    end
    stopDriverVehicleMonitor(uuid, driverSource)

    broadcastConnectionChange(uuid)
    DebugPrint('Released connection on', uuid, 'reason:', reason or 'forced')

    maybeRetireVehicleSpeaker(uuid)
end

local function releaseConnectionSilent(uuid, stopAudio)
    if stopAudio then stopSpeakerSound(uuid) end

    local driver = connections[uuid]
    if not driver then
        maybeRetireVehicleSpeaker(uuid)
        return
    end

    local driverSource = driver.source
    connections[uuid] = nil
    stopDriverVehicleMonitor(uuid, driverSource)
    broadcastConnectionChange(uuid)
    DebugPrint('Released connection silently on', uuid)

    maybeRetireVehicleSpeaker(uuid)
end

local function releaseConnectionsBySource(source, reason)
    for uuid, driver in pairs(connections) do
        if driver.source == source then
            releaseConnection(uuid, reason, true)
        end
    end
end

lib.callback.register('meteo-speakers:server:isAdmin', function(source)
    return isPlayerAdmin(source)
end)

lib.callback.register('meteo-speakers:server:getSpeakers', function(source)
    local result = {}
    for _, sp in ipairs(speakers) do
        local driver = connections[sp.uuid]
        result[#result + 1] = {
            uuid = sp.uuid,
            code = sp.code,
            item = sp.item,
            label = sp.label,
            model = sp.model,
            coords = sp.coords,
            heading = sp.heading,
            citizenid = sp.citizenid,
            distance = sp.distance,
            driver = driver and {
                citizenid = driver.citizenid,
                accountId = driver.accountId,
                source = driver.source,
                song = driver.song,
            } or nil,
        }
    end
    for uuid, vsp in pairs(vehicleSpeakers) do
        local driver = connections[uuid]
        result[#result + 1] = {
            uuid = uuid,
            kind = 'vehicle',
            vehicleNetId = vsp.vehicleNetId,
            plate = vsp.plate,
            distance = vsp.distance,
            driver = driver and {
                citizenid = driver.citizenid,
                accountId = driver.accountId,
                source = driver.source,
                song = driver.song,
            } or nil,
        }
    end
    return result
end)

lib.callback.register('meteo-speakers:server:place', function(source, item, coords, heading, itemSlot)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return nil end

    local itemConfig = Config.items[item]
    if not itemConfig then return nil end

    local citizenid = player.PlayerData.citizenid
    if getPlacedCount(citizenid) >= Config.maxPlacedPerPlayer then
        return nil
    end

    if not removeItem(source, item, 1, itemSlot) then return nil end

    local uuid = generateUUID()
    local code = generateSpeakerCode()
    local speaker = {
        uuid = uuid,
        code = code,
        item = item,
        label = itemConfig.label,
        model = itemConfig.model,
        coords = { x = coords.x, y = coords.y, z = coords.z },
        heading = heading,
        citizenid = citizenid,
        distance = itemConfig.distance,
    }

    speakers[#speakers + 1] = speaker
    TriggerClientEvent('meteo-speakers:client:addSpeaker', -1, speaker)

    DebugPrint('Player', citizenid, 'placed speaker', uuid)
    return uuid
end)

lib.callback.register('meteo-speakers:server:pickup', function(source, uuid)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false end

    local sp, index = findSpeaker(uuid)
    if not sp then return false end

    releaseConnection(uuid, 'pickup', true)

    addItem(source, sp.item, 1)
    table.remove(speakers, index)

    TriggerClientEvent('meteo-speakers:client:removeSpeaker', -1, uuid)

    DebugPrint('Player picked up speaker', uuid)
    return true
end)

lib.callback.register('meteo-speakers:server:adminDelete', function(source, uuid)
    if not isPlayerAdmin(source) then return false end

    local sp, index = findSpeaker(uuid)
    if not sp then return false end

    releaseConnection(uuid, 'admin_delete', true)
    table.remove(speakers, index)
    TriggerClientEvent('meteo-speakers:client:removeSpeaker', -1, uuid)

    DebugPrint('Admin deleted speaker', uuid)
    return true
end)

local function isUrlAllowed(url)
    if not url or url == '' then return false end
    if not string.find(url, '^https?://') then return false end

    local lower = string.lower(url)

    if string.find(lower, 'spotify%.com') or string.find(lower, 'spoti%.fi') then
        return false
    end
    if string.find(lower, 'youtube%.com') or string.find(lower, 'youtu%.be') then
        return false
    end

    return true
end

local function localControlAllowed(uuid, source)
    local driver = connections[uuid]
    if not driver then return true end
    return driver.source == source
end

-- meteo-phone
RegisterNetEvent('meteo-speakers:server:playMusic', function(uuid, url)
    local source = source
    local sp = findSpeaker(uuid)
    if not sp then return end

    if not localControlAllowed(uuid, source) then
        DebugPrint('Blocked local play - speaker is driven by phone', uuid)
        return
    end

    if not isUrlAllowed(url) then
        DebugPrint('Rejected disallowed URL from', source, url)
        return
    end

    stopSpeakerSound(uuid)
    recordSoundStart(uuid, url, Config.defaultVolume, sp)

    TriggerClientEvent('meteo-speakers:client:audio:play', -1, {
        uuid = uuid,
        url = url,
        volume = Config.defaultVolume,
        startTime = 0,
    })
end)

RegisterNetEvent('meteo-speakers:server:pauseMusic', function(uuid)
    local source = source
    if not findSpeaker(uuid) then return end
    if not localControlAllowed(uuid, source) then return end
    recordPause(uuid)
    TriggerClientEvent('meteo-speakers:client:audio:pause', -1, { uuid = uuid })
end)

RegisterNetEvent('meteo-speakers:server:resumeMusic', function(uuid)
    local source = source
    if not findSpeaker(uuid) then return end
    if not localControlAllowed(uuid, source) then return end
    recordResume(uuid)
    TriggerClientEvent('meteo-speakers:client:audio:resume', -1, { uuid = uuid })
end)

RegisterNetEvent('meteo-speakers:server:stopMusic', function(uuid)
    local source = source
    if not findSpeaker(uuid) then return end
    if not localControlAllowed(uuid, source) then return end
    stopSpeakerSound(uuid)
end)

RegisterNetEvent('meteo-speakers:server:setVolume', function(uuid, volume)
    local source = source
    if not findSpeaker(uuid) then return end
    if not localControlAllowed(uuid, source) then return end
    local vol = math.max(0.0, math.min(1.0, volume))
    recordVolume(uuid, vol)
    TriggerClientEvent('meteo-speakers:client:audio:setBaseVolume', -1, { uuid = uuid, volume = vol })
end)

RegisterNetEvent('meteo-speakers:server:seekMusic', function(uuid, time)
    local source = source
    if not findSpeaker(uuid) then return end
    if not localControlAllowed(uuid, source) then return end
    local t = tonumber(time) or 0
    recordSeek(uuid, t)
    TriggerClientEvent('meteo-speakers:client:audio:seek', -1, { uuid = uuid, time = t })
end)

RegisterNetEvent('meteo-speakers:server:audioDurationKnown', function(uuid, duration)
    if type(uuid) ~= 'string' then return end
    if type(duration) ~= 'number' or duration <= 0 then return end
    local s = activeSounds[uuid]
    if not s then return end
    if not s.duration or s.duration <= 0 then
        s.duration = duration
    end
end)

-- spam check. 1 sync request per second per (source, uuid)
local syncRequestThrottle = {}

RegisterNetEvent('meteo-speakers:server:requestSpeakerSync', function(uuid)
    local source = source
    if type(uuid) ~= 'string' then return end
    if not findSpeaker(uuid) then return end

    local now = GetGameTimer()
    local perPlayer = syncRequestThrottle[source]
    if not perPlayer then
        perPlayer = {}
        syncRequestThrottle[source] = perPlayer
    end
    if (now - (perPlayer[uuid] or 0)) < 1000 then return end
    perPlayer[uuid] = now

    syncSpeakerForPlayer(source, uuid)
end)

local function getMySpeakers(source)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return {} end
    local citizenid = player.PlayerData.citizenid

    local result = {}
    for _, sp in ipairs(speakers) do
        if sp.citizenid == citizenid then
            local driver = connections[sp.uuid]
            result[#result + 1] = {
                uuid = sp.uuid,
                code = sp.code,
                label = sp.label or (Config.items[sp.item] and Config.items[sp.item].label) or sp.item,
                item = sp.item,
                coords = sp.coords,
                connectedBy = driver and {
                    citizenid = driver.citizenid,
                    accountId = driver.accountId,
                    isMe = driver.source == source,
                } or nil,
            }
        end
    end
    return result
end
exports('GetMySpeakers', getMySpeakers)

local function connectToSpeaker(source, uuid, accountId)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return { success = false, message = 'player_not_found' } end

    local sp = findSpeaker(uuid)
    if not sp then return { success = false, message = 'speaker_not_found' } end

    local citizenid = player.PlayerData.citizenid
    if sp.citizenid ~= citizenid then
        return { success = false, message = 'not_owner' }
    end

    local existing = connections[uuid]
    if existing and existing.source ~= source then
        return { success = false, message = 'already_connected' }
    end

    for otherUuid, otherDriver in pairs(connections) do
        if otherUuid ~= uuid and otherDriver.source == source then
            releaseConnectionSilent(otherUuid, true)
        end
    end

    stopSpeakerSound(uuid)

    connections[uuid] = {
        source = source,
        citizenid = citizenid,
        accountId = accountId,
        since = os.time(),
        song = nil,
    }

    broadcastConnectionChange(uuid)
    DebugPrint('Phone driver connected', citizenid, 'to speaker', uuid, 'account', accountId)
    return { success = true, uuid = uuid }
end
exports('ConnectToSpeaker', connectToSpeaker)

local function disconnectFromSpeaker(source, uuid)
    local driver = connections[uuid]
    if not driver then return { success = true } end
    if driver.source ~= source then
        return { success = false, message = 'not_driver' }
    end
    releaseConnection(uuid, 'manual', true)
    return { success = true }
end
exports('DisconnectFromSpeaker', disconnectFromSpeaker)

-- cast to the vehicle the player is currently in
local function connectVehicleSpeaker(source, vehicleNetId, accountId)
    if not vehicleNetId or vehicleNetId == 0 then
        return { success = false, message = 'invalid_netid' }
    end

    local player = QBCore.Functions.GetPlayer(source)
    if not player then return { success = false, message = 'player_not_found' } end

    local veh = NetworkGetEntityFromNetworkId(vehicleNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return { success = false, message = 'vehicle_not_found' }
    end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return { success = false, message = 'no_ped' } end
    if GetVehiclePedIsIn(ped) ~= veh then
        return { success = false, message = 'not_in_vehicle' }
    end

    if not GetIsVehicleEngineRunning(veh) then
        return { success = false, message = 'engine_off' }
    end

    if not hasVehicleKeys(source, veh) then
        return { success = false, message = 'no_keys' }
    end

    local uuid = getVehicleUuid(vehicleNetId)

    local existing = connections[uuid]
    if existing and existing.source ~= source then
        return { success = false, message = 'already_connected' }
    end

    for otherUuid, otherDriver in pairs(connections) do
        if otherUuid ~= uuid and otherDriver.source == source then
            releaseConnectionSilent(otherUuid, true)
        end
    end

    stopSpeakerSound(uuid)

    local plate = GetVehicleNumberPlateText(veh) or ''
    plate = plate:gsub('%s+', '')

    vehicleSpeakers[uuid] = {
        uuid = uuid,
        kind = 'vehicle',
        vehicleNetId = vehicleNetId,
        plate = plate,
        distance = Config.vehicleSpeakerDistance or 10.0,
    }

    TriggerClientEvent('meteo-speakers:client:addSpeaker', -1, vehicleSpeakers[uuid])

    connections[uuid] = {
        source = source,
        citizenid = player.PlayerData.citizenid,
        accountId = accountId,
        since = os.time(),
        song = nil,
    }

    broadcastConnectionChange(uuid)

    TriggerClientEvent('meteo-speakers:client:startVehicleCastMonitor', source, vehicleNetId)
    DebugPrint('Vehicle cast:', player.PlayerData.citizenid, 'plate', plate, 'uuid', uuid)
    return { success = true, uuid = uuid }
end
exports('ConnectVehicleSpeaker', connectVehicleSpeaker)

local function disconnectVehicleSpeaker(source, vehicleNetId)
    if not vehicleNetId then return { success = false } end
    local uuid = getVehicleUuid(vehicleNetId)
    local driver = connections[uuid]
    if driver and driver.source ~= source then
        return { success = false, message = 'not_driver' }
    end
    releaseConnection(uuid, 'manual', true)
    return { success = true }
end
exports('DisconnectVehicleSpeaker', disconnectVehicleSpeaker)

local playSeq = {}

-- Server broadcasts the play intent; each client's NUI handles its own
-- <audio> element. Latest seq wins per uuid.
local function playOnSpeaker(source, uuid, song)
    local sp = findSpeaker(uuid)
    if not sp then return { success = false, message = 'speaker_not_found' } end

    local driver = connections[uuid]
    if not driver or driver.source ~= source then
        return { success = false, message = 'not_driver' }
    end

    local url = song and (song.audioUrl or song.audio_url)
    if not isUrlAllowed(url) then
        return { success = false, message = 'invalid_url' }
    end

    local startTime = tonumber(song.startTime) or 0
    local volume = tonumber(song.volume)
    if volume then
        volume = math.max(0.0, math.min(1.0, volume))
    else
        volume = Config.defaultVolume
    end

    local mySeq = (playSeq[uuid] or 0) + 1
    playSeq[uuid] = mySeq

    recordSoundStart(uuid, url, volume, sp)
    if startTime > 1 then
        recordSeek(uuid, startTime)
    end

    if song.duration then
        local s = activeSounds[uuid]
        if s then s.duration = tonumber(song.duration) end
    end

    TriggerClientEvent('meteo-speakers:client:audio:play', -1, {
        uuid = uuid,
        url = url,
        volume = volume,
        startTime = startTime,
        seq = mySeq,
    })

    driver.song = {
        id = song.id,
        title = song.title,
        artist = song.artist,
        cover = song.cover,
    }
    broadcastConnectionChange(uuid)

    DebugPrint('Phone playing', song.title or url, 'on speaker', uuid, 'from', startTime, 'seq', mySeq)
    return { success = true }
end
exports('PlayOnSpeaker', playOnSpeaker)

local function requireDriver(source, uuid)
    local driver = connections[uuid]
    return driver and driver.source == source
end

exports('PauseOnSpeaker', function(source, uuid)
    if not requireDriver(source, uuid) then return { success = false } end
    recordPause(uuid)
    TriggerClientEvent('meteo-speakers:client:audio:pause', -1, { uuid = uuid })
    return { success = true }
end)

exports('ResumeOnSpeaker', function(source, uuid)
    if not requireDriver(source, uuid) then return { success = false } end
    recordResume(uuid)
    TriggerClientEvent('meteo-speakers:client:audio:resume', -1, { uuid = uuid })
    return { success = true }
end)

exports('StopOnSpeaker', function(source, uuid)
    if not requireDriver(source, uuid) then return { success = false } end
    stopSpeakerSound(uuid)
    return { success = true }
end)

exports('SeekOnSpeaker', function(source, uuid, time)
    if not requireDriver(source, uuid) then return { success = false } end
    local t = tonumber(time) or 0
    recordSeek(uuid, t)
    TriggerClientEvent('meteo-speakers:client:audio:seek', -1, { uuid = uuid, time = t })
    return { success = true }
end)

exports('SetSpeakerVolume', function(source, uuid, volume)
    if not requireDriver(source, uuid) then return { success = false } end
    local vol = math.max(0.0, math.min(1.0, tonumber(volume) or Config.defaultVolume))
    recordVolume(uuid, vol)
    TriggerClientEvent('meteo-speakers:client:audio:setBaseVolume', -1, { uuid = uuid, volume = vol })
    return { success = true }
end)

exports('IsDrivenByPhone', function(uuid) return connections[uuid] ~= nil end)
exports('GetSpeakerDriver', function(uuid)
    local d = connections[uuid]
    if not d then return nil end
    return { citizenid = d.citizenid, accountId = d.accountId, source = d.source, song = d.song }
end)

exports('ForcePhoneDisconnect', function(source, uuid)
    local driver = connections[uuid]
    if not driver or driver.source ~= source then return false end
    releaseConnection(uuid, 'forced', true)
    return true
end)

-- Server-authoritative playhead for cross-resource use (phone progress bar)
exports('GetServerSpeakerTime', function(uuid)
    local s = activeSounds[uuid]
    if not s then return nil end
    return {
        current = estimateCurrentPosition(uuid),
        duration = s.duration or 0,
        paused = s.paused or false,
    }
end)

exports('ForceDisconnectAllForSource', function(source, reason)
    releaseConnectionsBySource(source, reason or 'forced')
    return true
end)

exports('ForceDisconnectOtherAccountsForSource', function(source, currentAccountId)
    if not currentAccountId then return false end
    for uuid, driver in pairs(connections) do
        if driver.source == source and driver.accountId ~= currentAccountId then
            releaseConnection(uuid, 'forced', true)
        end
    end
    return true
end)

AddEventHandler('playerDropped', function()
    local source = source
    releaseConnectionsBySource(source, 'player_dropped')
    syncRequestThrottle[source] = nil
end)

RegisterNetEvent('meteo-speakers:server:playerDied', function()
    local source = source
    releaseConnectionsBySource(source, 'player_died')
end)

AddEventHandler('entityRemoved', function(entity)
    if GetEntityType(entity) ~= 2 then return end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId == 0 then return end
    local uuid = getVehicleUuid(netId)
    if connections[uuid] or vehicleSpeakers[uuid] then
        releaseConnection(uuid, 'vehicle_gone', true)
    end
end)

RegisterNetEvent('meteo-speakers:server:vehicleCastAutoDisconnect', function(netId, reason)
    local source = source
    if not netId then return end
    local uuid = getVehicleUuid(netId)
    local driver = connections[uuid]
    if not driver or driver.source ~= source then return end
    releaseConnection(uuid, reason or 'auto', true)
end)

RegisterNetEvent('meteo-speakers:server:phoneDisconnect', function(uuid)
    local source = source
    local driver = connections[uuid]
    if not driver or driver.source ~= source then return end
    releaseConnection(uuid, 'manual', true)
end)

CreateThread(function()
    Wait(1000)
    for itemName, itemConfig in pairs(Config.items) do
        QBCore.Functions.CreateUseableItem(itemName, function(source, item)
            local player = QBCore.Functions.GetPlayer(source)
            if not player then return end

            local citizenid = player.PlayerData.citizenid
            if getPlacedCount(citizenid) >= Config.maxPlacedPerPlayer then
                QBCore.Functions.Notify(source, locale('notify_max_placed', Config.maxPlacedPerPlayer), 'error')
                return
            end

            TriggerClientEvent('meteo-speakers:client:startPlacement', source, itemName, itemConfig.model, item and item.slot)
        end)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for uuid in pairs(connections) do
        connections[uuid] = nil
    end
    for _, sp in ipairs(speakers) do
        stopSpeakerSound(sp.uuid)
    end
    for uuid in pairs(vehicleSpeakers) do
        stopSpeakerSound(uuid)
        vehicleSpeakers[uuid] = nil
    end
end)