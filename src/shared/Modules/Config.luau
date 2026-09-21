--[[
	Central place for tunable RPG constants shared by server and client.
]]

local Config = {
	StartingStats = {
		Level = 1,
		Experience = 0,
		Health = 100,
		MaxHealth = 100,
	},

	ExperienceCurve = {
		BaseXp = 50,
		Growth = 1.15,
	},
}

function Config.GetXpToNextLevel(level: number): number
	return math.floor(Config.ExperienceCurve.BaseXp * (Config.ExperienceCurve.Growth ^ (level - 1)))
end

return Config
