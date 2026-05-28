-- FULL CREDITS to Radio Guy (Obtaizen) for the original implementation:
--   https://github.com/Obtaizen/ob_radio_2/blob/main/client/environment.lua
-- This file is a port of his work, adapted for placed/static speakers and
-- vehicle casts. Used under the MIT License (see NOTICES.md).

envFilterFreq = 22000
envVolumeMul = 1.0

local COVER_CHECK_HEIGHT = 30.0
local UNDERGROUND_Z = -5.0
local MAX_WIND_SPEED = 40.

local ACTIVE_INTERVAL = 300
local IDLE_INTERVAL = 1000

local function castUpward(coords, entity)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        coords.x, coords.y, coords.z + 0.5,
        coords.x, coords.y, coords.z + COVER_CHECK_HEIGHT,
        1, entity, 0
    )
    local _, hit, hitCoords = GetShapeTestResult(handle)
    return hit == 1, hitCoords
end

local function detectListenerEnv(ped)
    if IsEntityInWater(ped) then
        return 600, 0.55, 'underwater'
    end

    local interior = GetInteriorFromEntity(ped)
    if interior ~= 0 then
        local roomKey = GetRoomKeyFromEntity(ped)
        if roomKey ~= 0 and roomKey ~= -1 then
            return 4000, 0.7, 'interior_room'
        end
        return 6000, 0.88, 'interior_open'
    end

    local coords = GetEntityCoords(ped)
    if coords.z < UNDERGROUND_Z then
        return 2800, 0.75, 'underground'
    end

    local hasCover, hitCoords = castUpward(coords, ped)
    if hasCover and hitCoords then
        local cover = hitCoords.z - coords.z
        if cover < 8.0 then
            return 5500, 0.92, 'tunnel'
        end
        return 9500, 0.97, 'overpass'
    end

    return 22000, 1.0, 'outdoor'
end

local function detectVehicleEnv(veh)
    local class = GetVehicleClass(veh)
    -- Bikes have no cabin
    if class == 8 or class == 13 then
        return 18000, 0.95, 'bike', 0
    end
    -- Helis / planes - heavy engine + cabin noise
    if class == 15 or class == 16 then
        return 5000, 0.85, 'aircraft', 0
    end

    local hasRoof = DoesVehicleHaveRoof(veh)
    local roofState = GetConvertibleRoofState and GetConvertibleRoofState(veh) or 0
    local isOpen = (not hasRoof) or roofState == 2

    if isOpen then
        return 18000, 0.95, 'convertible_open', 1.0
    end

    local openness = 0
    for i = 0, 3 do
        if not IsVehicleWindowIntact(veh, i) then openness = openness + 0.2 end
    end
    local doorCount = GetNumberOfVehicleDoors(veh)
    for i = 0, doorCount - 1 do
        if GetVehicleDoorAngleRatio(veh, i) > 0.1 or IsVehicleDoorDamaged(veh, i) then
            openness = openness + 0.25
        end
    end
    openness = math.min(1.0, openness)

    if openness > 0.05 then
        return 9000, 0.88, 'cabin_open', openness
    end
    return 5500, 0.75, 'cabin_closed', 0
end

local function applyWindEffects(veh, baseFilter, baseVolume, openness)
    if not openness or openness < 0.05 then return baseFilter, baseVolume end

    local speed = GetEntitySpeed(veh)
    local speedRatio = math.min(1.0, speed / MAX_WIND_SPEED)
    local windIntensity = openness * speedRatio
    if windIntensity < 0.05 then return baseFilter, baseVolume end

    local filterDrop = windIntensity * 18000
    local volumeDrop = windIntensity * 0.30
    local newFilter = math.max(3000, baseFilter - filterDrop)
    local newVolume = baseVolume * (1.0 - volumeDrop)
    return newFilter, newVolume
end

local lastDebugLog = 0
local lastEnvLabel = nil

local function detectAndApply()
    local ped = PlayerPedId()
    if not ped or ped == 0 then
        envFilterFreq, envVolumeMul = 22000, 1.0
        return
    end

    local veh = cache and cache.vehicle or GetVehiclePedIsIn(ped, false)
    if veh == 0 then veh = nil end

    local f, v, label
    if veh then
        -- In vehicle
        local openness
        f, v, label, openness = detectVehicleEnv(veh)
        f, v = applyWindEffects(veh, f, v, openness)
    else
        -- On foot
        f, v, label = detectListenerEnv(ped)
    end

    envFilterFreq, envVolumeMul = f, v

    if Config.debug then
        local now = GetGameTimer()
        if label ~= lastEnvLabel or (now - lastDebugLog) > 3000 then
            lastEnvLabel = label
            lastDebugLog = now
            DebugPrint('env:', label, 'filter:', math.floor(f), 'volMul:', string.format('%.2f', v))
        end
    end
end

CreateThread(function()
    while true do
        local speakers = MeteoSpeakers_GetSpeakers and MeteoSpeakers_GetSpeakers() or nil
        local hasAny = speakers and next(speakers) ~= nil

        if hasAny then
            detectAndApply()
            Wait(ACTIVE_INTERVAL)
        else
            -- No speakers exist - skip the raycast / native calls entirely
            Wait(IDLE_INTERVAL)
        end
    end
end)
