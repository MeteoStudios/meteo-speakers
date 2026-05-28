local QBCore = exports['qb-core']:GetCoreObject()
local isPlayerLoaded = false
local isAdmin = false

local speakerData = {}
local speakerPoints = {}
local speakerObjects = {}
local speakerTargets = {}
local syncedSpeakers = {}
local pendingRemovals = {}

local speakerDrivers = {}

local initInProgress = false
local eventQueue = {}

local isPlacing = false
local placementObj = nil
local placementItem = nil
local placementSlot = nil
local carryObj = nil

local isUIOpen = false
local activeUUID = nil

local myVehicleCastNetId = nil

function CanPerformAction()
    local ped = PlayerPedId()
    if IsEntityDead(ped) or GetEntityHealth(ped) <= 0 then return false end
    local playerData = QBCore.Functions.GetPlayerData()
    if playerData and playerData.metadata then
        if playerData.metadata['inlaststand'] then return false end
        if playerData.metadata['isdead'] then return false end
        if playerData.metadata['ishandcuffed'] then return false end
    end
    return true
end

local function localPlayerServerId()
    return GetPlayerServerId(PlayerId())
end

local function spawnSpeaker(uuid)
    if speakerObjects[uuid] then return end

    local sp = speakerData[uuid]
    if not sp then return end

    local model = GetHashKey(sp.model)
    lib.requestModel(model)

    local obj = CreateObject(model, sp.coords.x, sp.coords.y, sp.coords.z, false, false, false)
    SetEntityHeading(obj, sp.heading)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, true, true)
    PlaceObjectOnGroundProperly(obj)

    speakerObjects[uuid] = obj

    local targetSystem = GetTarget()

    if targetSystem == 'qb-target' then
        local options = {
            {
                type = 'client',
                event = 'meteo-speakers:client:openControls',
                icon = 'fas fa-music',
                label = locale('target_controls'),
                uuid = uuid,
            },
            {
                type = 'client',
                event = 'meteo-speakers:client:pickup',
                icon = 'fas fa-hand',
                label = locale('target_pickup'),
                uuid = uuid,
            },
        }

        if isAdmin then
            options[#options + 1] = {
                type = 'client',
                event = 'meteo-speakers:client:adminDelete',
                icon = 'fas fa-trash',
                label = locale('target_delete'),
                uuid = uuid,
            }
        end

        exports['qb-target']:AddTargetEntity(obj, {
            options = options,
            distance = Config.interactDistance,
        })
    else
        local options = {
            {
                name = 'speaker_controls_' .. uuid,
                icon = 'fas fa-music',
                label = locale('target_controls'),
                distance = Config.interactDistance,
                onSelect = function() openControls(uuid) end,
            },
            {
                name = 'speaker_pickup_' .. uuid,
                icon = 'fas fa-hand',
                label = locale('target_pickup'),
                distance = Config.interactDistance,
                onSelect = function() pickupSpeaker(uuid) end,
            },
        }

        if isAdmin then
            options[#options + 1] = {
                name = 'speaker_delete_' .. uuid,
                icon = 'fas fa-trash',
                label = locale('target_delete'),
                distance = Config.interactDistance,
                onSelect = function() adminDeleteSpeaker(uuid) end,
            }
        end

        exports.ox_target:addLocalEntity(obj, options)
    end

    speakerTargets[uuid] = true
    DebugPrint('Spawned speaker', uuid)
end

local function despawnSpeaker(uuid)
    if speakerTargets[uuid] and speakerObjects[uuid] then
        local targetSystem = GetTarget()
        pcall(function()
            if targetSystem == 'qb-target' then
                exports['qb-target']:RemoveTargetEntity(speakerObjects[uuid])
            else
                exports.ox_target:removeLocalEntity(speakerObjects[uuid])
            end
        end)
        speakerTargets[uuid] = nil
    end

    if speakerObjects[uuid] then
        if DoesEntityExist(speakerObjects[uuid]) then
            DeleteEntity(speakerObjects[uuid])
        end
        speakerObjects[uuid] = nil
    end

    DebugPrint('Despawned speaker', uuid)
end

local function createPoint(uuid)
    if speakerPoints[uuid] then return end

    local sp = speakerData[uuid]
    if not sp then return end

    local coords = vector3(sp.coords.x, sp.coords.y, sp.coords.z)

    local point = lib.points.new({
        coords = coords,
        distance = Config.renderDistance,
    })

    function point:onEnter()
        if not isPlayerLoaded then return end
        spawnSpeaker(uuid)
        if not syncedSpeakers[uuid] then
            syncedSpeakers[uuid] = true
            TriggerServerEvent('meteo-speakers:server:requestSpeakerSync', uuid)
        end
    end

    function point:onExit()
        despawnSpeaker(uuid)
    end

    speakerPoints[uuid] = point
end

local function removePoint(uuid)
    despawnSpeaker(uuid)

    if speakerPoints[uuid] then
        speakerPoints[uuid]:remove()
        speakerPoints[uuid] = nil
    end
end

local function sendOpenUIMessage(uuid)
    local driver = speakerDrivers[uuid]
    local isDriverMe = (driver and driver.source == localPlayerServerId()) or false
    local data = speakerData[uuid]

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'openUI',
        uuid = uuid,
        code = data and data.code or nil,
        label = data and (data.label or (Config.items[data.item] and Config.items[data.item].label)) or nil,
        defaultVolume = Config.defaultVolume,
        translations = CreateUITranslations(),
        lock = driver and {
            driverCitizenId = driver.citizenid,
            isDriverMe = isDriverMe,
            song = driver.song,
        } or nil,
    })
end

function openControls(uuid)
    if not CanPerformAction() then return end
    if isUIOpen then return end

    isUIOpen = true
    activeUUID = uuid

    sendOpenUIMessage(uuid)
    -- NUI reads time directly from its audio element
end

local function CloseUI()
    if not isUIOpen then return end
    isUIOpen = false
    activeUUID = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeUI' })
end

function CreateUITranslations()
    local placeholder = 'Direct audio URL (mp3, ogg, wav, m4a, ...)'

    return {
        ui_title = locale('ui_title'),
        ui_url_placeholder = placeholder,
        ui_no_music = locale('ui_no_music'),
        ui_now_playing = locale('ui_now_playing'),
        ui_custom_stream = locale('ui_custom_stream'),
        ui_status_playing = locale('ui_status_playing'),
        ui_status_paused = locale('ui_status_paused'),
        ui_status_stopped = locale('ui_status_stopped'),
        ui_recent_title = locale('ui_recent_title'),
        ui_no_recent = locale('ui_no_recent'),
        ui_locked_title = locale('ui_locked_title'),
        ui_locked_desc = locale('ui_locked_desc'),
        ui_locked_driver_self = locale('ui_locked_driver_self'),
        ui_locked_driver_other = locale('ui_locked_driver_other'),
        ui_disconnect = locale('ui_disconnect'),
    }
end

RegisterNUICallback('closeUI', function(data, cb)
    CloseUI()
    cb({})
end)

RegisterNUICallback('playMusic', function(data, cb)
    if not data.uuid or not data.url then cb({ ok = false }) return end

    local ok, errMsg = validateUrl(data.url)
    if not ok then
        QBCore.Functions.Notify(errMsg or 'Invalid URL', 'error')
        cb({ ok = false })
        return
    end

    TriggerServerEvent('meteo-speakers:server:playMusic', data.uuid, data.url)
    cb({ ok = true })
end)

RegisterNUICallback('pauseMusic', function(data, cb)
    if data.uuid then TriggerServerEvent('meteo-speakers:server:pauseMusic', data.uuid) end
    cb({})
end)

RegisterNUICallback('resumeMusic', function(data, cb)
    if data.uuid then TriggerServerEvent('meteo-speakers:server:resumeMusic', data.uuid) end
    cb({})
end)

RegisterNUICallback('stopMusic', function(data, cb)
    if data.uuid then TriggerServerEvent('meteo-speakers:server:stopMusic', data.uuid) end
    cb({})
end)

RegisterNUICallback('setVolume', function(data, cb)
    if data.uuid and data.volume then
        TriggerServerEvent('meteo-speakers:server:setVolume', data.uuid, data.volume)
    end
    cb({})
end)

RegisterNUICallback('seekMusic', function(data, cb)
    if data.uuid and data.time then
        TriggerServerEvent('meteo-speakers:server:seekMusic', data.uuid, data.time)
    end
    cb({})
end)

RegisterNUICallback('phoneDisconnect', function(data, cb)
    if data.uuid then
        TriggerServerEvent('meteo-speakers:server:phoneDisconnect', data.uuid)
        cb({ ok = true })
    else
        cb({ ok = false })
    end
end)

function pickupSpeaker(uuid)
    if not CanPerformAction() then return end

    local ped = cache.ped
    lib.requestAnimDict('pickup_object')
    TaskPlayAnim(ped, 'pickup_object', 'pickup_low', 5.0, 1.0, 1.0, 48, 0.0, false, false, false)

    QBCore.Functions.Progressbar('meteo_speaker_pickup', locale('progress_picking_up'), 200, false, true, {
        disableMovement = true,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true,
    }, {}, {}, {}, function()
        ClearPedTasks(ped)
        local success = lib.callback.await('meteo-speakers:server:pickup', false, uuid)
        if success then
            QBCore.Functions.Notify(locale('notify_picked_up'), 'success')
        end
    end, function()
        ClearPedTasks(ped)
    end)
end

function adminDeleteSpeaker(uuid)
    if not CanPerformAction() then return end

    local success = lib.callback.await('meteo-speakers:server:adminDelete', false, uuid)
    if success then
        QBCore.Functions.Notify(locale('notify_deleted'), 'success')
    end
end

RegisterNetEvent('meteo-speakers:client:openControls', function(data)
    if data and data.uuid then openControls(data.uuid) end
end)

RegisterNetEvent('meteo-speakers:client:pickup', function(data)
    if data and data.uuid then pickupSpeaker(data.uuid) end
end)

RegisterNetEvent('meteo-speakers:client:adminDelete', function(data)
    if data and data.uuid then adminDeleteSpeaker(data.uuid) end
end)

-- Spawn the prop + sync audio if already in render range.
local function maybeSpawnAndSync(uuid)
    local sp = speakerData[uuid]
    if not sp then return end
    if not isPlayerLoaded then return end
    local ped = PlayerPedId()
    if not DoesEntityExist(ped) then return end
    local dist = #(GetEntityCoords(ped) - vector3(sp.coords.x, sp.coords.y, sp.coords.z))
    if dist > Config.renderDistance then return end
    spawnSpeaker(uuid)
    if not syncedSpeakers[uuid] then
        syncedSpeakers[uuid] = true
        TriggerServerEvent('meteo-speakers:server:requestSpeakerSync', uuid)
    end
end

local function applyConnectionChanged(uuid, driver)
    speakerDrivers[uuid] = driver
    if isUIOpen and activeUUID == uuid then
        SendNUIMessage({
            action = 'connectionChanged',
            uuid = uuid,
            lock = driver and {
                driverCitizenId = driver.citizenid,
                isDriverMe = driver.source == localPlayerServerId(),
                song = driver.song,
            } or nil,
        })
    end
end

local function applyAddSpeaker(speaker)
    if not speaker or not speaker.uuid then return end
    if pendingRemovals[speaker.uuid] then return end
    speakerData[speaker.uuid] = speaker

    -- Vehicle "speakers" have no prop, no render zone, no target. Audio
    -- positioning rides on the vehicle entity from spatial.lua.
    if speaker.kind == 'vehicle' then
        if isPlayerLoaded and not syncedSpeakers[speaker.uuid] then
            syncedSpeakers[speaker.uuid] = true
            TriggerServerEvent('meteo-speakers:server:requestSpeakerSync', speaker.uuid)
        end
        DebugPrint('Added vehicle speaker', speaker.uuid, 'netId', speaker.vehicleNetId)
        return
    end

    if not speakerPoints[speaker.uuid] then
        createPoint(speaker.uuid)
    end
    maybeSpawnAndSync(speaker.uuid)
    DebugPrint('Added speaker', speaker.uuid)
end

local function applyRemoveSpeaker(uuid)
    if not uuid then return end
    pendingRemovals[uuid] = true
    removePoint(uuid)
    speakerData[uuid] = nil
    speakerDrivers[uuid] = nil
    syncedSpeakers[uuid] = nil
    SendNUIMessage({
        action = 'meteoSpeakersRemoved',
        uuid = uuid,
    })

    pendingRemovals[uuid] = nil
    DebugPrint('Removed speaker', uuid)
end

local function queueOrApplyAddSpeaker(speaker)
    if initInProgress then
        eventQueue[#eventQueue + 1] = function() applyAddSpeaker(speaker) end
    else
        applyAddSpeaker(speaker)
    end
end

local function queueOrApplyRemoveSpeaker(uuid)
    -- Mark immediately so initialize()'s snapshot pass can skip this uuid
    if uuid then pendingRemovals[uuid] = true end
    if initInProgress then
        eventQueue[#eventQueue + 1] = function() applyRemoveSpeaker(uuid) end
    else
        applyRemoveSpeaker(uuid)
    end
end

local function queueOrApplyConnectionChanged(uuid, driver)
    if initInProgress then
        eventQueue[#eventQueue + 1] = function() applyConnectionChanged(uuid, driver) end
    else
        applyConnectionChanged(uuid, driver)
    end
end

RegisterNetEvent('meteo-speakers:client:connectionChanged', function(uuid, driver)
    queueOrApplyConnectionChanged(uuid, driver)
end)

RegisterNetEvent('meteo-speakers:client:phoneDisconnected', function(uuid, reason)
    -- If we were the driver of a vehicle cast, stop the local monitor loop
    if type(uuid) == 'string' and uuid:sub(1, 4) == 'veh:' then
        myVehicleCastNetId = nil
    end
    SendNUIMessage({
        action = 'meteoSpeakersPhoneDisconnected',
        uuid = uuid,
        reason = reason,
    })
end)

RegisterNetEvent('meteo-speakers:client:startVehicleCastMonitor', function(netId)
    myVehicleCastNetId = netId
end)

RegisterNetEvent('meteo-speakers:client:stopVehicleCastMonitor', function()
    myVehicleCastNetId = nil
end)

RegisterNetEvent('meteo-speakers:client:addSpeaker', function(speaker)
    queueOrApplyAddSpeaker(speaker)
end)

RegisterNetEvent('meteo-speakers:client:removeSpeaker', function(uuid)
    queueOrApplyRemoveSpeaker(uuid)
end)

-- Forward server audio events to the NUI
local function forwardAudioEvent(action, data)
    -- Drop while on multichar - initialize() will sync in-range speakers after login
    if not isPlayerLoaded then return end
    if type(data) ~= 'table' or type(data.uuid) ~= 'string' then return end

    local payload = {
        action = 'meteoSpeakersAudio:' .. action,
        uuid = data.uuid,
    }
    if type(data.url) == 'string' then payload.url = data.url end
    if type(data.volume) == 'number' then payload.volume = data.volume end
    if type(data.startTime) == 'number' then payload.startTime = data.startTime end
    if type(data.time) == 'number' then payload.time = data.time end

    SendNUIMessage(payload)
end

RegisterNetEvent('meteo-speakers:client:audio:play', function(data)
    forwardAudioEvent('play', data)
end)

RegisterNetEvent('meteo-speakers:client:audio:pause', function(data)
    forwardAudioEvent('pause', data)
end)

RegisterNetEvent('meteo-speakers:client:audio:resume', function(data)
    forwardAudioEvent('resume', data)
end)

RegisterNetEvent('meteo-speakers:client:audio:seek', function(data)
    forwardAudioEvent('seek', data)
end)

RegisterNetEvent('meteo-speakers:client:audio:stop', function(data)
    forwardAudioEvent('stop', data)
end)

RegisterNetEvent('meteo-speakers:client:audio:setBaseVolume', function(data)
    forwardAudioEvent('setBaseVolume', data)
end)

RegisterNUICallback('audioDurationKnown', function(data, cb)
    if data and type(data.uuid) == 'string' and type(data.duration) == 'number' and data.duration > 0 then
        TriggerServerEvent('meteo-speakers:server:audioDurationKnown', data.uuid, data.duration)
    end
    cb({})
end)

function validateUrl(url)
    if not url or url == '' then return false, 'Please enter a URL' end
    if not string.find(url, '^https?://') then return false, 'Invalid URL - must start with https://' end

    local lower = string.lower(url)

    if string.find(lower, 'spotify%.com') or string.find(lower, 'spoti%.fi') then
        return false, 'Spotify links are not supported'
    end
    if string.find(lower, 'youtube%.com') or string.find(lower, 'youtu%.be') then
        return false, 'YouTube links are not supported - use a direct audio file URL'
    end

    for _, ext in ipairs(Config.allowedExtensions) do
        if string.find(lower, '%.' .. ext .. '$') or string.find(lower, '%.' .. ext .. '%?') then
            return true
        end
    end

    return false, 'Unsupported URL - use a direct audio file (mp3, ogg, wav, m4a)'
end

function isValidUrl(url)
    local ok = validateUrl(url)
    return ok
end

local function raycastFromCamera(maxDist)
    local camCoords = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)

    local radX = math.rad(camRot.x)
    local radZ = math.rad(camRot.z)
    local dir = vector3(
        -math.sin(radZ) * math.abs(math.cos(radX)),
        math.cos(radZ) * math.abs(math.cos(radX)),
        math.sin(radX)
    )

    local endCoords = camCoords + dir * maxDist
    local ray = StartShapeTestRay(camCoords.x, camCoords.y, camCoords.z, endCoords.x, endCoords.y, endCoords.z, 1 + 16, cache.ped, 0)
    local _, hit, hitCoords = GetShapeTestResult(ray)

    return hit == 1, hitCoords
end

local function startCarryAnim(ped, modelHash)
    local animDict = 'anim@heists@box_carry@'
    lib.requestAnimDict(animDict)

    local pedCoords = GetEntityCoords(ped)
    carryObj = CreateObject(modelHash, pedCoords.x, pedCoords.y, pedCoords.z, true, false, false)
    AttachEntityToEntity(carryObj, ped, GetPedBoneIndex(ped, 28422), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
    SetModelAsNoLongerNeeded(modelHash)

    TaskPlayAnim(ped, animDict, 'idle', 8.0, 8.0, -1, 49, 0, false, false, false)
end

local function cleanupPlacement()
    if placementObj and DoesEntityExist(placementObj) then
        DeleteEntity(placementObj)
    end
    placementObj = nil

    if carryObj and DoesEntityExist(carryObj) then
        DeleteEntity(carryObj)
    end
    carryObj = nil

    isPlacing = false
    ClearPedTasks(cache.ped)
    LocalPlayer.state:set('inv_busy', false, true)
    LocalPlayer.state:set('invBusy', false, true)
    exports[Rename.prefix .. 'keybinddisplay']:hide()
end

local function startPlacement(item, model, itemSlot)
    if isPlacing then return end
    if not CanPerformAction() then return end
    isPlacing = true
    placementItem = item
    placementSlot = itemSlot

    -- inv block
    LocalPlayer.state:set('inv_busy', true, true)
    LocalPlayer.state:set('invBusy', true, true)

    local ped = cache.ped
    local modelHash = GetHashKey(model)
    lib.requestModel(modelHash)

    local pedCoords = GetEntityCoords(ped)
    placementObj = CreateObject(modelHash, pedCoords.x, pedCoords.y, pedCoords.z, false, false, false)
    SetEntityCollision(placementObj, false, false)
    FreezeEntityPosition(placementObj, true)
    SetEntityAlpha(placementObj, 200, false)

    local heading = GetEntityHeading(ped)

    startCarryAnim(ped, modelHash)

    exports[Rename.prefix .. 'keybinddisplay']:show({
        { keys = 'LMB', label = locale('keybind_place') },
        { keys = 'RMB', label = locale('keybind_cancel') },
        { keys = {'Scroll Up', 'Scroll Down'}, label = locale('keybind_rotate') },
    })

    CreateThread(function()
        while isPlacing do
            Wait(0)

            DisablePlayerFiring(ped, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 257, true)
            DisableControlAction(0, 263, true)

            local hit, coords = raycastFromCamera(Config.placementDistance + 5.0)
            local pedCoords = GetEntityCoords(ped)

            if hit and coords then
                SetEntityCoords(placementObj, coords.x, coords.y, coords.z)
                PlaceObjectOnGroundProperly(placementObj)
            end

            SetEntityHeading(placementObj, heading)

            local distFromPlayer = #(pedCoords - GetEntityCoords(placementObj))
            local isValid = hit and distFromPlayer <= Config.placementDistance
            SetEntityAlpha(placementObj, isValid and 200 or 120, false)

            if IsControlPressed(0, 241) then heading = heading + 3.0 end
            if IsControlPressed(0, 242) then heading = heading - 3.0 end

            if not CanPerformAction() then
                cleanupPlacement()
                break
            end

            if IsDisabledControlJustPressed(0, 24) then
                if isValid then
                    local finalCoords = GetEntityCoords(placementObj)
                    local finalHeading = GetEntityHeading(placementObj)

                    cleanupPlacement()

                    local uuid = lib.callback.await('meteo-speakers:server:place', false, placementItem, finalCoords, finalHeading, placementSlot)
                    if uuid then
                        QBCore.Functions.Notify(locale('notify_placed'), 'success')
                    else
                        QBCore.Functions.Notify(locale('notify_max_placed', Config.maxPlacedPerPlayer), 'error')
                    end
                else
                    QBCore.Functions.Notify(locale('notify_too_far'), 'error')
                end
                if isValid then break end
            end

            if IsDisabledControlJustPressed(0, 25) then
                cleanupPlacement()
                QBCore.Functions.Notify(locale('notify_placement_cancel'), 'inform')
                break
            end
        end
    end)
end

RegisterNetEvent('meteo-speakers:client:startPlacement', function(item, model, itemSlot)
    startPlacement(item, model, itemSlot)
end)

RegisterNetEvent('QBCore:Client:OnPlayerDeath', function()
    TriggerServerEvent('meteo-speakers:server:playerDied')
end)

CreateThread(function()
    local wasDead = false
    while true do
        Wait(1500)
        if isPlayerLoaded then
            local ped = PlayerPedId()
            local dead = IsEntityDead(ped) or GetEntityHealth(ped) <= 0
            if dead and not wasDead then
                TriggerServerEvent('meteo-speakers:server:playerDied')
            end
            wasDead = dead

            if myVehicleCastNetId then
                local netId = myVehicleCastNetId
                -- Skip silently when the net id isn't in our scope right
                -- now. Calling NetworkGetEntityFromNetworkId on a missing id
                -- spams a warning every tick.
                if NetworkDoesNetworkIdExist(netId) then
                    local veh = NetworkGetEntityFromNetworkId(netId)
                    if veh and veh ~= 0 and DoesEntityExist(veh) then
                        local reason = nil
                        if IsEntityInWater(veh) then
                            reason = 'vehicle_in_water'
                        elseif IsEntityDead(veh) then
                            reason = 'vehicle_destroyed'
                        end
                        if reason then
                            DebugPrint('Vehicle cast auto-disconnect:', reason, 'netId', netId)
                            myVehicleCastNetId = nil
                            TriggerServerEvent('meteo-speakers:server:vehicleCastAutoDisconnect', netId, reason)
                        end
                    end
                end
            end
        end
    end
end)

local function initialize()
    initInProgress = true
    eventQueue = {}
    pendingRemovals = {}

    isAdmin = lib.callback.await('meteo-speakers:server:isAdmin', false)

    local data = lib.callback.await('meteo-speakers:server:getSpeakers', false)

    if data then
        for _, sp in ipairs(data) do
            if not pendingRemovals[sp.uuid] then
                speakerData[sp.uuid] = sp
                if sp.driver then
                    speakerDrivers[sp.uuid] = sp.driver
                end
                if sp.kind == 'vehicle' then
                    if not syncedSpeakers[sp.uuid] then
                        syncedSpeakers[sp.uuid] = true
                        TriggerServerEvent('meteo-speakers:server:requestSpeakerSync', sp.uuid)
                    end
                else
                    createPoint(sp.uuid)
                    maybeSpawnAndSync(sp.uuid)
                end
            end
        end
        DebugPrint('Loaded', #data, 'speakers')
    end

    initInProgress = false
    local pending = eventQueue
    eventQueue = {}
    for _, fn in ipairs(pending) do
        local ok, err = pcall(fn)
        if not ok then DebugPrint('Queued event failed:', err) end
    end
end

local function cleanup()
    DebugPrint('Cleaning up...')

    if isUIOpen then CloseUI() end
    if isPlacing then cleanupPlacement() end

    SendNUIMessage({ action = 'meteoSpeakersAudio:stopAll' })

    LocalPlayer.state:set('inv_busy', false, true)
    LocalPlayer.state:set('invBusy', false, true)

    for uuid in pairs(speakerData) do
        removePoint(uuid)
    end

    speakerData = {}
    speakerPoints = {}
    speakerObjects = {}
    speakerTargets = {}
    speakerDrivers = {}
    syncedSpeakers = {}
    pendingRemovals = {}
    eventQueue = {}
    initInProgress = false
    myVehicleCastNetId = nil
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    isPlayerLoaded = true
    initialize()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    isPlayerLoaded = false
    cleanup()
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if LocalPlayer.state.isLoggedIn then
        isPlayerLoaded = true
        initialize()
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    cleanup()
end)

exports('IsSpeakerKnown', function(uuid)
    return speakerData[uuid] ~= nil
end)

function MeteoSpeakers_IsLoaded()
    return isPlayerLoaded
end

function MeteoSpeakers_GetSpeakers()
    return speakerData
end