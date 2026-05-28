fx_version 'cerulean'
game 'gta5'
nui_callback_strict_mode 'true'

name 'meteo-speakers'
description 'Placeable speakers and vehicle casting from the meteo phone Music app'
author 'Meteo Studios'
version '1.1.0'

ox_lib 'locale'

shared_scripts {
    'shared/rename.lua',
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/utils.lua',
}

client_scripts {
    'client/cl_main.lua',
    'client/environment.lua',
    'client/spatial.lua',
}

server_scripts {
    'server/sv_main.lua',
}

lua54 'yes'

escrow_ignore {
    'shared/rename.lua',
}

-- [PRODUCTION START]
ui_page 'web/build/index.html'

files {
    'locales/*.json',
    'web/build/index.html',
    'web/build/**/*',
}
-- [PRODUCTION END]

-- [DEV START]
-- ui_page 'web/index.html'
--
-- files {
--     'locales/*.json',
--     'web/index.html',
--     'web/js/*.js',
--     'web/css/*.css',
-- }
-- [DEV END]
