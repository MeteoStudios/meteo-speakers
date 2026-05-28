-- FULL CREDITS to Radio Guy (Obtaizen) for the original implementation:
--   https://github.com/Obtaizen/ob_radio_2/blob/main/client/spatial.lua
-- This file is a port of his work, adapted for placed/static speakers and
-- vehicle casts. Used under the MIT License (see NOTICES.md).

local ACTIVE_INTERVAL = 200
local IDLE_INTERVAL = 1000
local DISTANT_FILTER = 600

local function distanceVolume(dist, maxDist)
    if dist >= maxDist then return 0 end
    if dist <= 0 then return 1 end
    local ratio = dist / maxDist
    if ratio < 0.5 then
        return 1.0 - (ratio * 0.4)
    end
    local t = (ratio - 0.5) / 0.5
    return 0.8 * (1.0 - t * t)
end

local function sourceVehicleOcclusion(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return 1.0, 22000, 1.0
    end

    local class = GetVehicleClass(veh)
    -- Bikes / no body: barely any occlusion, full range
    if class == 8 or class == 13 then
        return 0.85, 18000, 2.5
    end

    local hasRoof = DoesVehicleHaveRoof(veh)
    if not hasRoof then
        return 0.78, 16000, 2.5
    end

    local roofState = GetConvertibleRoofState and GetConvertibleRoofState(veh) or 0
    if roofState == 2 then
        return 0.78, 16000, 2.5
    end

    local volMul = 0.20
    local filter = 2200
    local distMul = 1.0

    local openVents = 0
    for i = 0, 3 do
        if not IsVehicleWindowIntact(veh, i) then openVents = openVents + 1 end
    end
    local doorCount = GetNumberOfVehicleDoors(veh)
    for i = 0, doorCount - 1 do
        if GetVehicleDoorAngleRatio(veh, i) > 0.1 or IsVehicleDoorDamaged(veh, i) then
            openVents = openVents + 1
        end
    end

    if openVents > 0 then
        volMul = math.min(0.85, volMul + openVents * 0.13)
        filter = math.min(18000, filter + openVents * 3500)
        distMul = math.min(2.5, distMul + openVents * 0.20)
    end

    return volMul, filter, distMul
end

local function emitSilent(uuid)
    SendNUIMessage({
        action = 'meteoSpeakersAudio:updateSpatial',
        uuid = uuid,
        volume = 0,
    })
end

local sourceDebugLast = {}
local function debugSource(uuid, veh, sourceVolMul, sourceFilter, distMul, dist, maxDist, finalVolume)
    if not Config.debug then return end
    local now = GetGameTimer()
    if (now - (sourceDebugLast[uuid] or 0)) < 2000 then return end
    sourceDebugLast[uuid] = now

    local openVents = 0
    for i = 0, 3 do
        if not IsVehicleWindowIntact(veh, i) then openVents = openVents + 1 end
    end
    local doorCount = GetNumberOfVehicleDoors(veh)
    local openDoors = 0
    for i = 0, doorCount - 1 do
        if GetVehicleDoorAngleRatio(veh, i) > 0.1 or IsVehicleDoorDamaged(veh, i) then
            openDoors = openDoors + 1
            openVents = openVents + 1
        end
    end

    DebugPrint('src:', uuid,
        'vents:', openVents, '(doors:', openDoors, ')',
        'volMul:', string.format('%.2f', sourceVolMul),
        'filter:', math.floor(sourceFilter),
        'distMul:', string.format('%.2f', distMul),
        'dist:', string.format('%.1f', dist), '/', string.format('%.1f', maxDist),
        'final:', string.format('%.2f', finalVolume))
end

local function tickSpeaker(uuid, sp, pCoords, listenerVehHandle, listenerVehNetId, envFilter, envVolMul)
    local sCoords
    local sourceVolMul = 1.0
    local sourceFilter = 22000
    local distMul = 1.0
    local insideSourceVehicle = false
    local sourceVeh = nil

    if sp.kind == 'vehicle' then
        local netId = sp.vehicleNetId
        if not netId or netId == 0 then
            emitSilent(uuid)
            return
        end

        if listenerVehNetId and listenerVehNetId == netId then
            insideSourceVehicle = true
            sourceVeh = listenerVehHandle
            sCoords = GetEntityCoords(listenerVehHandle)
        else
            -- NetworkDoesNetworkIdExist short-circuits silently. Calling
            -- NetworkGetEntityFromNetworkId on a missing id spams a warning
            -- every tick, which happens whenever the source vehicle drops
            -- out of our scope briefly.
            if not NetworkDoesNetworkIdExist(netId) then
                emitSilent(uuid)
                return
            end
            local veh = NetworkGetEntityFromNetworkId(netId)
            if not veh or veh == 0 or not DoesEntityExist(veh) then
                emitSilent(uuid)
                return
            end
            sCoords = GetEntityCoords(veh)
            sourceVeh = veh

            -- Fallback handle check (shouldn't happen if net id matched above)
            if listenerVehHandle and listenerVehHandle == veh then
                insideSourceVehicle = true
            else
                -- Outside the source vehicle - sound gets occluded by its
                -- body, and an open cabin lets it carry further too
                sourceVolMul, sourceFilter, distMul = sourceVehicleOcclusion(veh)
            end
        end
    else
        sCoords = vector3(sp.coords.x, sp.coords.y, sp.coords.z)
    end

    local dist = #(pCoords - sCoords)
    local maxDist = (sp.distance or 15.0) * distMul
    if dist > maxDist then
        if sourceVeh and not insideSourceVehicle then
            debugSource(uuid, sourceVeh, sourceVolMul, sourceFilter, distMul, dist, maxDist, 0)
        end
        emitSilent(uuid)
        return
    end

    local effectiveEnvVol = insideSourceVehicle and 1.0 or envVolMul
    local effectiveEnvFilter = insideSourceVehicle and 22000 or envFilter

    local distVol = distanceVolume(dist, maxDist)
    local volume = distVol * effectiveEnvVol * sourceVolMul

    local ratio = math.min(1.0, dist / maxDist)
    local distFilter = 22000 - ratio * (22000 - DISTANT_FILTER)
    local finalFilter = math.min(distFilter, effectiveEnvFilter, sourceFilter)

    if sourceVeh and not insideSourceVehicle then
        debugSource(uuid, sourceVeh, sourceVolMul, sourceFilter, distMul, dist, maxDist, volume)
    end

    SendNUIMessage({
        action = 'meteoSpeakersAudio:updateSpatial',
        uuid = uuid,
        volume = volume,
        filterFreq = finalFilter,
    })
end

local listenerVehHandle = nil
local listenerVehNetId = nil

local function setListenerVehicle(handle)
    if handle and handle ~= 0 and DoesEntityExist(handle) then
        listenerVehHandle = handle
        if NetworkGetEntityIsNetworked(handle) then
            listenerVehNetId = NetworkGetNetworkIdFromEntity(handle)
        else
            listenerVehNetId = nil
        end
    else
        listenerVehHandle = nil
        listenerVehNetId = nil
    end
end

lib.onCache('vehicle', function(vehicle)
    setListenerVehicle(vehicle or nil)
end)

CreateThread(function()
    -- Prime once on script start in case we loaded already inside a vehicle.
    -- After this, lib.onCache handles all updates.
    if cache and cache.vehicle then
        setListenerVehicle(cache.vehicle)
    end

    while true do
        local speakers = MeteoSpeakers_GetSpeakers and MeteoSpeakers_GetSpeakers() or nil
        local loaded = MeteoSpeakers_IsLoaded and MeteoSpeakers_IsLoaded()
        local hasAny = speakers and next(speakers) ~= nil

        if loaded and hasAny then
            local pCoords = GetEntityCoords(PlayerPedId())
            local envFilter = (envFilterFreq or 22000)
            local envVolMul = (envVolumeMul or 1.0)

            for uuid, sp in pairs(speakers) do
                tickSpeaker(uuid, sp, pCoords, listenerVehHandle, listenerVehNetId, envFilter, envVolMul)
            end

            Wait(ACTIVE_INTERVAL)
        else
            Wait(IDLE_INTERVAL)
        end
    end
end)
