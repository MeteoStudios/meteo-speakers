Config = {}

Config.debug = false

Config.target = 'auto'
Config.inventory = 'auto'

Config.renderDistance = 50.0
Config.interactDistance = 2.5
Config.placementDistance = 2.0
Config.defaultVolume = 0.2
Config.maxPlacedPerPlayer = 3

-- Direct audio URLs only. Just use fivemanage
Config.allowedExtensions = { 'mp3', 'ogg', 'wav', 'm4a', 'aac', 'flac', 'opus' }

Config.items = {
    meteo_boombox = {
        label = 'Boombox',
        model = 'prop_boombox_01',
        distance = 10.0,
    },
    meteo_speaker = {
        label = 'Speaker',
        model = 'prop_speaker_03',
        distance = 20.0,
    },
}

-- Vehicle speakers (cast from the phone to your current vehicle).
Config.vehicleSpeakerDistance = 3.0

-- GTA vehicle class IDs to block. 13 = cycles, 14 = boats, 15 = helis,
-- 16 = planes, 21 = trains
Config.vehicleSpeakerBlacklistClasses = {
    [13] = true, [14] = true, [15] = true, [16] = true, [21] = true,
}

-- Require the casting player to have keys to the vehicle.
Config.requireVehicleKeys = true