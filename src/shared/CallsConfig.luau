-- CITY GRIND: phone calls tuning (sections 19, 20, 101). Shared by server and client.

local CallsConfig = {}

CallsConfig.RING_SECONDS = 25 -- unanswered calls become missed calls after this
CallsConfig.START_COOLDOWN = 5 -- one outgoing call every 5 seconds
CallsConfig.MAX_RECENTS = 30 -- saved Recents entries per player
CallsConfig.TEXT_MAX = 200 -- characters per text-call line
CallsConfig.TEXT_COOLDOWN = 0.6 -- seconds between text-call lines
CallsConfig.TEXT_HISTORY = 40 -- lines kept on screen during a text call (never saved)

-- Local voice volume through the call route (AudioFader.Volume).
CallsConfig.EARPIECE_VOLUME = 1
CallsConfig.SPEAKER_VOLUME = 2.2

return CallsConfig
