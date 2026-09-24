--[[
	Client-side current-language singleton. SettingsController changes it;
	any controller that draws translated chrome calls Locale.T(key) when
	building its labels and Locale.OnChanged(callback) to re-render them
	the moment the player switches language, without a rejoin.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Localization = require(ReplicatedStorage.Shared.Modules.Localization)

local Locale = {}

local current = "en"
local listeners: { (string) -> () } = {}

function Locale.Get(): string
	return current
end

function Locale.T(key: string): string
	return Localization.Get(current, key)
end

function Locale.Set(languageCode: string)
	if current == languageCode or not table.find(Localization.Languages, languageCode) then
		return
	end
	current = languageCode
	for _, listener in listeners do
		task.spawn(listener, current)
	end
end

function Locale.OnChanged(callback: (string) -> ())
	table.insert(listeners, callback)
end

return Locale
