-- CITY GRIND: crew tuning (sections 60, 61, 62), shared by server and client.

local CrewsConfig = {}

CrewsConfig.FEE = 2500
CrewsConfig.MIN_LEVEL = 5
CrewsConfig.MAX_MEMBERS = 30
CrewsConfig.NAME_MIN, CrewsConfig.NAME_MAX = 3, 20
CrewsConfig.TAG_MIN, CrewsConfig.TAG_MAX = 2, 4
CrewsConfig.ANNOUNCE_MAX = 200
CrewsConfig.INVITE_DAYS = 3

CrewsConfig.ROLES = { "Leader", "Officer", "Member" }
CrewsConfig.ROLE_RANK = { Leader = 3, Officer = 2, Member = 1 }

CrewsConfig.COLORS = {
	{ name = "Fire", color = Color3.fromRGB(255, 90, 60) },
	{ name = "Sunset", color = Color3.fromRGB(255, 150, 50) },
	{ name = "Gold", color = Color3.fromRGB(255, 205, 60) },
	{ name = "Lime", color = Color3.fromRGB(140, 230, 80) },
	{ name = "Mint", color = Color3.fromRGB(70, 220, 170) },
	{ name = "Sky", color = Color3.fromRGB(80, 180, 255) },
	{ name = "Royal", color = Color3.fromRGB(90, 110, 255) },
	{ name = "Violet", color = Color3.fromRGB(170, 100, 255) },
	{ name = "Pink", color = Color3.fromRGB(255, 100, 190) },
	{ name = "Snow", color = Color3.fromRGB(235, 235, 245) },
}

CrewsConfig.LOGOS = { "👑", "🔥", "⚡", "💎", "🏀", "🦁", "🐍", "💀", "⭐", "🌙", "🎯", "🦅" }

-- Crew rep needed to reach each crew level (index = level).
CrewsConfig.LEVELS = { 0, 500, 1500, 3500, 7000, 12000, 20000, 32000, 50000, 75000 }

function CrewsConfig.levelFor(rep: number): (number, number, number?)
	local level = 1
	for i, need in CrewsConfig.LEVELS do
		if rep >= need then
			level = i
		end
	end
	return level, CrewsConfig.LEVELS[level], CrewsConfig.LEVELS[level + 1]
end

-- Weekly crew goals, tracked from members' attribute increases on the server.
CrewsConfig.MISSIONS = {
	{ id = "wins25", stat = "Wins", goal = 25, reward = 1500, title = "Win 25 basketball games" },
	{ id = "rep5k", stat = "Reputation", goal = 5000, reward = 1200, title = "Earn 5,000 reputation" },
	{ id = "levels12", stat = "Level", goal = 12, reward = 1200, title = "Level up 12 times" },
	{ id = "wins50", stat = "Wins", goal = 50, reward = 3000, title = "Win 50 basketball games" },
}
CrewsConfig.MISSION_STATS = { "Wins", "Reputation", "Level" }

local WEEK = 7 * 86400
local WEEK_OFFSET = 3 * 86400 -- weeks roll over Monday 00:00 UTC

function CrewsConfig.weekIndex(now: number): number
	return math.floor((now + WEEK_OFFSET) / WEEK)
end

function CrewsConfig.weekEnds(now: number): number
	return (CrewsConfig.weekIndex(now) + 1) * WEEK - WEEK_OFFSET
end

function CrewsConfig.missionFor(crewId: string, week: number)
	local hash = 0
	for i = 1, #crewId do
		hash = (hash * 31 + string.byte(crewId, i)) % 1000003
	end
	return CrewsConfig.MISSIONS[(hash + week) % #CrewsConfig.MISSIONS + 1]
end

return CrewsConfig
