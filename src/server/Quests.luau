-- CITY GRIND: daily/weekly quests, achievements and the daily login reward
-- (spec sections 78, 79, 80, 113). Server side.
--
-- Everything is measured on the server from real gameplay:
--   * saved data other systems already keep (basketball career, job shifts,
--     gym reps, photos taken, CityGram posts, events joined / podiums, owned
--     vehicles / homes / clothes, level, reputation, fame)
--   * bank transactions as PlayerData logs them (cash earned, Corner Mart and
--     Threads purchases), read through PlayerData.onPublish
--   * Player attributes (PhoneOut, Interior, District, SubwayRides, CrewId)
--   * Basketball.scored (every made shot on any court)
--   * distance on foot / driving, sampled once a second with a speed cap so a
--     teleport never counts
-- These become "metrics" (lifetime numbers, see metric()). Daily and weekly
-- quests count a metric's growth since the quest was handed out; achievements
-- and Story missions compare the lifetime value. The client never reports progress.
--
-- Remotes: QuestsRequest (RemoteFunction, client -> server: action, a, b) -> (ok, message, state)
--            actions: "Get" | "Claim" (list "daily"/"weekly", index) | "Reroll" (index) | "ClaimLogin"
--          QuestsEvent (RemoteEvent, server -> client): ("State", state) | ("Achievement", id)
-- Player attribute: Achievements (number unlocked).
-- Saved section "quests":
--   { day, daily = {Quest}, rerollDay, week, weekly = {Quest}, life = {counters}, districts = {[id]=true},
--     ach = {[id]=unix time}, titles = {string}, login = { lastDay, streak } }
--   Quest = { id, goal, base, claimed, cash, xp, rep }
--
-- Public API:
--   Quests.unlock(player, achievementId) -> boolean   (grants rewards once)
--   Quests.hasAchievement(player, achievementId) -> boolean
--   Quests.titles(player) -> {string}                   (titles earned here, for Social)
--   Quests.metric(player, name) -> number               (lifetime metric, used by Story)
--   Quests.onProgress(fn(player))                       (runs after metrics may have changed)
--   Quests.districtsAvailable() -> boolean

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local QC = require(shared:WaitForChild("QuestsConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local Quests = {}

local SECTION = "quests"

PlayerData.registerSection(SECTION, function()
	return {
		day = 0,
		daily = {},
		rerollDay = 0,
		week = 0,
		weekly = {},
		life = {
			shots = 0, -- made shots on any court
			earned = 0, -- cash earned (no transfers, refunds or quest rewards)
			runM = 0, -- metres on foot
			driveM = 0, -- metres driven
			drinks = 0, -- Corner Mart purchases (incl. the vending machine)
			threads = 0, -- Threads Clothing purchases
			phone = 0, -- times the phone was taken out
			apartment = 0, -- times entering an apartment
			subway = 0, -- subway rides
			subwayDowntown = 0, -- subway rides that ended Downtown
			crew = 0, -- 1 once in a crew
			viral = 0, -- CityTok videos that went viral
			tokPosts = 0, -- CityTok posts made
			friends = 0, -- most friends at once
			questsDone = 0,
			loginCycles = 0, -- full 7-day login streaks
		},
		districts = {},
		ach = {},
		titles = {},
		login = { lastDay = 0, streak = 0 },
	}
end)

local function sec(player: Player): any
	return PlayerData.section(player, SECTION)
end

---------------------------------------------------------------------------
-- Optional sibling modules / configs (required lazily, never fatal)
---------------------------------------------------------------------------
local lazy: { [string]: any } = {}
local function sibling(name: string): any
	if lazy[name] == nil then
		lazy[name] = false
		local module = script.Parent:FindFirstChild(name)
		if module and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				lazy[name] = result
			end
		end
	end
	return lazy[name] or nil
end

local function sharedModule(name: string): any
	local key = "shared:" .. name
	if lazy[key] == nil then
		lazy[key] = false
		local module = shared:FindFirstChild(name)
		if module and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				lazy[key] = result
			end
		end
	end
	return lazy[key] or nil
end

local cityModel: Instance? = nil

function Quests.districtsAvailable(): boolean
	local city = cityModel or workspace:FindFirstChild("City")
	local folder = city and city:FindFirstChild("Districts")
	return folder ~= nil and #folder:GetChildren() > 0
end

---------------------------------------------------------------------------
-- Time
---------------------------------------------------------------------------
local function utcDay(): number
	return os.time() // 86400
end

-- ISO weeks start on Monday; 1 Jan 1970 was a Thursday.
local function isoWeek(): number
	return (utcDay() + 3) // 7
end

---------------------------------------------------------------------------
-- Metrics
---------------------------------------------------------------------------
local function count(t: any): number
	local n = 0
	if type(t) == "table" then
		for _ in t do
			n += 1
		end
	end
	return n
end

local function rankIndex(rep: number): number
	local index = 1
	for i, rank in Config.REPUTATION_RANKS do
		if rep >= rank.min then
			index = i
		end
	end
	return index
end

local function homeTierIndex(data: any): number
	local apartments = data.sections.apartments
	local AC = sharedModule("ApartmentsConfig")
	if type(apartments) ~= "table" or type(apartments.ownedTiers) ~= "table" or not AC then
		return 1
	end
	local best = 1
	for i, tier in AC.TIERS do
		if apartments.ownedTiers[tier.id] then
			best = math.max(best, i)
		end
	end
	return best
end

local BASKETBALL = { points = true, threes = true, dunks = true, blocks = true, steals = true, games = true, wins = true }

-- The lifetime value of a metric for this player (0 when unknown).
function Quests.metric(player: Player, name: string): number
	local data = PlayerData.get(player)
	if not data then
		return 0
	end
	local s = data.sections
	if BASKETBALL[name] then
		return data.basketball[name] or 0
	elseif name == "jobs" or name == "jobLevel" then
		local total, best = 0, 0
		if type(s.jobs) == "table" then
			for _, j in s.jobs do
				if type(j) == "table" then
					total += j.shifts or 0
					best = math.max(best, j.level or 0)
				end
			end
		end
		return if name == "jobs" then total else best
	elseif name == "reps" then
		return type(s.gym) == "table" and s.gym.totalReps or 0
	elseif name == "level" then
		return data.level
	elseif name == "rep" then
		return data.reputation
	elseif name == "rankIndex" then
		return rankIndex(data.reputation)
	elseif name == "fame" then
		return data.fame or 0
	elseif name == "vehicles" then
		return type(s.vehicles) == "table" and count(s.vehicles.owned) or 0
	elseif name == "homeTier" then
		return homeTierIndex(data)
	elseif name == "items" then
		return type(s.wardrobe) == "table" and type(s.wardrobe.owned) == "table" and #s.wardrobe.owned or 0
	elseif name == "photos" then
		return type(s.media) == "table" and s.media.taken or 0
	elseif name == "posts" then
		return type(s.citygram) == "table" and s.citygram.posts or 0
	elseif name == "events" then
		return type(s.events) == "table" and s.events.joined or 0
	elseif name == "podiums" then
		return type(s.events) == "table" and s.events.podiums or 0
	elseif name == "eventWins" then
		return type(s.events) == "table" and s.events.wins or 0
	elseif name == "followers" then
		local n = player:GetAttribute("Followers")
		return if type(n) == "number" then n else 0
	end
	local q = s[SECTION]
	if not q then
		return 0
	end
	if name == "districts" then
		return count(q.districts)
	end
	local v = q.life[name]
	return if type(v) == "number" then math.floor(v) else 0
end
local metric = Quests.metric

---------------------------------------------------------------------------
-- Session tracking
---------------------------------------------------------------------------
type Session = {
	conns: { RBXScriptConnection },
	lastTx: any, -- newest transaction table already looked at (false = none)
	lastFame: number?,
	tokSeen: { [any]: boolean },
	lastPos: Vector3?,
	lastAt: number,
	runStuds: number,
	driveStuds: number,
	signature: string?,
}
local sessions: { [Player]: Session } = {}
local dirty: { [Player]: boolean } = {}
local needsSave: { [Player]: boolean } = {}
local progressListeners: { (Player) -> () } = {}

local QuestsEvent: RemoteEvent

function Quests.onProgress(fn: (Player) -> ())
	table.insert(progressListeners, fn)
end

function Quests.markDirty(player: Player)
	dirty[player] = true
end

local function bump(player: Player, key: string, amount: number)
	local q = sec(player)
	if not q or amount <= 0 then
		return
	end
	q.life[key] = (q.life[key] or 0) + amount
	needsSave[player] = true
	dirty[player] = true
end

-- Labels of incoming cash that isn't "earned": transfers, refunds, and the
-- rewards this module and the Story pay out (so quests can't feed themselves).
local NOT_EARNED = { "From ", "Refund", "Crew fee refund", "Welcome", "Quest", "Achievement", "Daily", "Story" }

local function startsWith(s: string, prefix: string): boolean
	return s:sub(1, #prefix) == prefix
end

local function classify(player: Player, t: any)
	if type(t) ~= "table" or type(t.amount) ~= "number" or type(t.label) ~= "string" then
		return
	end
	if t.amount > 0 then
		for _, prefix in NOT_EARNED do
			if startsWith(t.label, prefix) then
				return
			end
		end
		bump(player, "earned", t.amount)
	elseif t.amount < 0 then
		if startsWith(t.label, "Corner Mart") then
			bump(player, "drinks", 1)
		elseif startsWith(t.label, "Threads:") then
			bump(player, "threads", 1)
		end
	end
end

-- Runs on every attribute republish; must not call markChanged itself.
PlayerData.onPublish(function(player: Player, data: any)
	local q = data.sections and data.sections[SECTION]
	if not q then
		return
	end
	player:SetAttribute("Achievements", count(q.ach))
	local s = sessions[player]
	if not s then
		return
	end

	-- New bank transactions since last time (newest first).
	local list = data.transactions
	local top = list[1]
	if s.lastTx == nil then
		s.lastTx = top or false
	elseif top ~= nil and top ~= s.lastTx then
		for _, t in list do
			if t == s.lastTx then
				break
			end
			classify(player, t)
		end
		s.lastTx = top
	end

	-- A viral CityTok award is the only single fame jump of exactly this size.
	local fame = data.fame or 0
	local CT = sharedModule("CityTokConfig")
	if s.lastFame and CT and CT.VIRAL_REWARD and fame - s.lastFame == CT.VIRAL_REWARD.fame then
		bump(player, "viral", 1)
	end
	s.lastFame = fame

	-- CityTok posts made: count post ids not seen before (the saved list is
	-- capped and shrinks on delete, so its length alone can't be trusted).
	local tok = data.sections.citytok
	if type(tok) == "table" and type(tok.posts) == "table" then
		local seen = s.tokSeen
		for _, id in tok.posts do
			if not seen[id] then
				seen[id] = true
				bump(player, "tokPosts", 1)
			end
		end
	end

	dirty[player] = true
end)

---------------------------------------------------------------------------
-- Quest generation
---------------------------------------------------------------------------
local ELIGIBLE = {
	vehicle = function(player: Player)
		return metric(player, "vehicles") > 0
	end,
	notLegend = function(player: Player)
		return metric(player, "rankIndex") < #Config.REPUTATION_RANKS
	end,
}

local DEFS: { [string]: QC.QuestDef } = {}
for _, def in QC.DAILY_POOL do
	DEFS[def.id] = def
end
for _, def in QC.WEEKLY_POOL do
	DEFS[def.id] = def
end

local rng = Random.new()

local function goalFor(def: QC.QuestDef, level: number): number
	local g = def.goal
	if type(g) == "function" then
		return g(level)
	end
	return g :: number
end

local function makeQuest(player: Player, def: QC.QuestDef, weekly: boolean)
	local level = metric(player, "level")
	local reward = if weekly then QC.weeklyReward(level) else QC.dailyReward(level)
	return {
		id = def.id,
		goal = goalFor(def, level),
		base = metric(player, def.metric),
		claimed = false,
		cash = reward.cash,
		xp = reward.xp,
		rep = reward.rep,
	}
end

-- Pool entries this player can get that aren't already in `current`.
local function candidates(player: Player, pool: { QC.QuestDef }, current: { any }): { QC.QuestDef }
	local taken = {}
	for _, quest in current do
		taken[quest.id] = true
	end
	local list = {}
	for _, def in pool do
		local check = def.needs and ELIGIBLE[def.needs]
		if not taken[def.id] and (not check or check(player)) then
			table.insert(list, def)
		end
	end
	return list
end

local function generate(player: Player, pool: { QC.QuestDef }, n: number, weekly: boolean): { any }
	local out = {}
	for _ = 1, n do
		local options = candidates(player, pool, out)
		if #options == 0 then
			break
		end
		table.insert(out, makeQuest(player, options[rng:NextInteger(1, #options)], weekly))
	end
	return out
end

-- Hands out new dailies on a new UTC day and new weeklies on a new ISO week.
local function refreshPeriods(player: Player, q: any): boolean
	local changed = false
	local today = utcDay()
	if q.day ~= today then
		q.day = today
		q.daily = generate(player, QC.DAILY_POOL, QC.DAILY_COUNT, false)
		changed = true
	end
	local week = isoWeek()
	if q.week ~= week then
		q.week = week
		q.weekly = generate(player, QC.WEEKLY_POOL, QC.WEEKLY_COUNT, true)
		changed = true
	end
	return changed
end

local function questText(def: QC.QuestDef, goal: number): string
	if def.text:find("%s", 1, true) then
		return string.format(def.text, QC.formatValue(def.metric, goal))
	end
	return def.text
end

local function progressOf(player: Player, quest: any): number
	local def = DEFS[quest.id]
	if not def then
		return 0
	end
	return math.clamp(metric(player, def.metric) - (quest.base or 0), 0, quest.goal)
end

---------------------------------------------------------------------------
-- Achievements
---------------------------------------------------------------------------
local function achievementListed(a: QC.Achievement): boolean
	return a.needs ~= "districts" or Quests.districtsAvailable()
end

local function addTitle(q: any, title: string?)
	if title and not table.find(q.titles, title) then
		table.insert(q.titles, title)
	end
end

function Quests.hasAchievement(player: Player, id: string): boolean
	local q = sec(player)
	return q ~= nil and q.ach[id] ~= nil
end

function Quests.unlock(player: Player, id: string): boolean
	local q = sec(player)
	local def = QC.ACHIEVEMENT_BY_ID[id]
	if not q or not def or q.ach[id] then
		return false
	end
	q.ach[id] = os.time()
	addTitle(q, def.title)
	PlayerData.markChanged(player)
	if def.cash > 0 then
		PlayerData.addCash(player, def.cash, "Achievement: " .. def.name)
	end
	if def.xp > 0 then
		PlayerData.addXP(player, def.xp)
	end
	if QuestsEvent and player.Parent then
		QuestsEvent:FireClient(player, "Achievement", id)
	end
	dirty[player] = true
	return true
end

function Quests.titles(player: Player): { string }
	local q = sec(player)
	return if q then table.clone(q.titles) else {}
end

local function checkAchievements(player: Player)
	local q = sec(player)
	if not q then
		return
	end
	for _, a in QC.ACHIEVEMENTS do
		if a.metric and a.goal and not q.ach[a.id] and achievementListed(a) and metric(player, a.metric) >= a.goal then
			Quests.unlock(player, a.id)
		end
	end
end

---------------------------------------------------------------------------
-- Daily login (113)
---------------------------------------------------------------------------
-- Which cycle day comes next, whether today is already claimed, and how many
-- days of the current cycle are done.
local function loginStatus(q: any): (number, boolean, number)
	local L = q.login
	local today = utcDay()
	if L.lastDay == today then
		return L.streak, true, L.streak
	end
	if L.lastDay == today - 1 and L.streak < 7 then
		return L.streak + 1, false, L.streak
	end
	return 1, false, 0 -- missed a day, or a cycle just finished
end

local function loginPreview(player: Player): { any }
	local level = metric(player, "level")
	local out = {}
	for _, d in QC.LOGIN_DAYS do
		local text
		if d.kind == "cash" then
			text = "$" .. QC.commas(QC.loginCash(d.cash, level))
		elseif d.kind == "xp" then
			text = QC.commas(d.xp) .. " XP"
		elseif d.kind == "cosmetic" then
			text = "Free clothes"
		elseif d.kind == "voucher" then
			text = "Paint & Mods voucher"
		else
			text = "$" .. QC.commas(QC.loginCash(d.cash, level)) .. " + " .. QC.commas(d.xp) .. " XP + title"
		end
		table.insert(out, { day = d.day, icon = d.icon, label = d.label, text = text })
	end
	return out
end

local function grantLoginItem(player: Player): string?
	local w = PlayerData.section(player, "wardrobe")
	local SC = sharedModule("ShopsConfig")
	if type(w) ~= "table" or type(w.owned) ~= "table" or not SC then
		return nil
	end
	for _, id in QC.LOGIN_ITEMS do
		local item = SC.ITEMS[id]
		if item and not table.find(w.owned, id) then
			table.insert(w.owned, id)
			PlayerData.markChanged(player)
			return item.name
		end
	end
	return nil
end

local function claimLogin(player: Player): (boolean, string)
	local q = sec(player)
	if not q then
		return false, "Your save is still loading."
	end
	local day, claimed = loginStatus(q)
	if claimed then
		return false, "Come back tomorrow for Day " .. (day % 7 + 1) .. "."
	end
	local d = QC.LOGIN_DAYS[day]
	local level = metric(player, "level")
	local label = "Daily login: Day " .. day
	local message

	q.login.lastDay = utcDay()
	q.login.streak = day
	PlayerData.markChanged(player)

	if d.kind == "cash" then
		local cash = QC.loginCash(d.cash, level)
		PlayerData.addCash(player, cash, label)
		message = "+$" .. QC.commas(cash)
	elseif d.kind == "xp" then
		PlayerData.addXP(player, d.xp)
		message = "+" .. QC.commas(d.xp) .. " XP"
	elseif d.kind == "cosmetic" then
		local name = grantLoginItem(player)
		if name then
			message = name .. " added to your Closet"
		else
			-- already owns every reward item: pay its value instead
			local cash = QC.loginCash(d.cash, level)
			PlayerData.addCash(player, cash, label .. " (clothing voucher)")
			message = "You own every reward item, so +$" .. QC.commas(cash)
		end
	elseif d.kind == "voucher" then
		-- Vehicles has no unlock list, so the voucher pays the underglow mod's price in cash.
		local VC = sharedModule("VehiclesConfig")
		local cash = (VC and VC.MOD_PRICES and VC.MOD_PRICES.glow) or 400
		PlayerData.addCash(player, cash, "Daily: car mod voucher")
		message = "+$" .. QC.commas(cash) .. " to spend at Paint & Mods"
	else
		local cash = QC.loginCash(d.cash, level)
		PlayerData.addCash(player, cash, label)
		PlayerData.addXP(player, d.xp)
		PlayerData.addReputation(player, d.rep)
		addTitle(q, d.title)
		q.life.loginCycles += 1
		message = string.format("+$%s, +%s XP, +%d rep and the \"%s\" title", QC.commas(cash), QC.commas(d.xp), d.rep, d.title)
	end
	Net.notify(player, "DAY " .. day .. " REWARD", message)
	dirty[player] = true
	return true, message
end

---------------------------------------------------------------------------
-- State sent to the client
---------------------------------------------------------------------------
local function questView(player: Player, quest: any): any
	local def = DEFS[quest.id]
	if not def then
		return nil
	end
	return {
		id = quest.id,
		icon = def.icon,
		text = questText(def, quest.goal),
		metric = def.metric,
		goal = quest.goal,
		progress = progressOf(player, quest),
		claimed = quest.claimed,
		cash = quest.cash,
		xp = quest.xp,
		rep = quest.rep,
	}
end

local function stateFor(player: Player): any
	local q = sec(player)
	if not q then
		return nil
	end
	local daily, weekly = {}, {}
	for _, quest in q.daily do
		table.insert(daily, questView(player, quest))
	end
	for _, quest in q.weekly do
		table.insert(weekly, questView(player, quest))
	end
	local ach, achProgress = {}, {}
	for _, a in QC.ACHIEVEMENTS do
		if achievementListed(a) then
			if q.ach[a.id] then
				ach[a.id] = q.ach[a.id]
			elseif a.metric then
				achProgress[a.id] = metric(player, a.metric)
			end
		end
	end
	local day, claimed, done = loginStatus(q)
	return {
		daily = daily,
		weekly = weekly,
		rerollAvailable = q.rerollDay ~= utcDay(),
		ach = ach,
		achProgress = achProgress,
		districts = Quests.districtsAvailable(),
		titles = table.clone(q.titles),
		login = { day = day, claimed = claimed, done = done, days = loginPreview(player) },
	}
end

local function withTimers(state: any): any
	local now = os.time()
	state.dailyResetAt = (utcDay() + 1) * 86400
	state.weeklyResetAt = ((isoWeek() + 1) * 7 - 3) * 86400
	state.serverNow = now
	return state
end

local function pushState(player: Player, force: boolean?)
	local s = sessions[player]
	local state = stateFor(player)
	if not s or not state or not QuestsEvent then
		return
	end
	local ok, signature = pcall(HttpService.JSONEncode, HttpService, state)
	if not force and ok and signature == s.signature then
		return
	end
	s.signature = if ok then signature else nil
	QuestsEvent:FireClient(player, "State", withTimers(state))
end

---------------------------------------------------------------------------
-- Processing loop
---------------------------------------------------------------------------
local function process(player: Player)
	local q = sec(player)
	if not q or not sessions[player] then
		return
	end
	if refreshPeriods(player, q) then
		needsSave[player] = true
	end
	local friends = 0
	local social = PlayerData.section(player, "Social")
	if type(social) == "table" then
		friends = count(social.friends)
	end
	if friends > (q.life.friends or 0) then
		q.life.friends = friends
		needsSave[player] = true
	end
	checkAchievements(player)
	for _, fn in progressListeners do
		local ok, err = pcall(fn, player)
		if not ok then
			warn("[CityGrind] Quests progress listener failed:", err)
		end
	end
	if needsSave[player] then
		needsSave[player] = nil
		PlayerData.markChanged(player)
	end
	pushState(player)
end

-- Distance sampling: horizontal movement once a second, on foot or driving.
local STUDS = QC.STUDS_PER_METRE
local MAX_FOOT_SPEED = Config.SLIDE_SPEED * 1.3
local MAX_DRIVE_SPEED = 260

local function sample(player: Player, s: Session, now: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		s.lastPos = nil
		return
	end
	local pos = root.Position
	local prev, dt = s.lastPos, now - s.lastAt
	s.lastPos, s.lastAt = pos, now
	if not prev or dt <= 0 or dt > 3 or (player:GetAttribute("Interior") or "") ~= "" then
		return
	end
	local d = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(prev.X, 0, prev.Z)).Magnitude
	if d < 1 then
		return
	end
	local speed = d / dt
	if (player:GetAttribute("Driving") or "") ~= "" then
		if speed <= MAX_DRIVE_SPEED then
			s.driveStuds += d
		end
	elseif humanoid.SeatPart == nil and speed <= MAX_FOOT_SPEED then
		s.runStuds += d
	end
end

local function flushDistance(player: Player, s: Session)
	if s.runStuds >= STUDS then
		bump(player, "runM", s.runStuds / STUDS)
		s.runStuds = 0
	end
	if s.driveStuds >= STUDS then
		bump(player, "driveM", s.driveStuds / STUDS)
		s.driveStuds = 0
	end
end

---------------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------------
local function onLoaded(player: Player)
	if sessions[player] or not player.Parent then
		return
	end
	local data = PlayerData.get(player)
	local tok = data and data.sections.citytok
	local s: Session = {
		conns = {},
		lastTx = if data then (data.transactions[1] or false) else nil,
		lastFame = data and data.fame,
		tokSeen = {},
		lastPos = nil,
		lastAt = os.clock(),
		runStuds = 0,
		driveStuds = 0,
		signature = nil,
	}
	if type(tok) == "table" and type(tok.posts) == "table" then
		for _, id in tok.posts do
			s.tokSeen[id] = true
		end
	end
	sessions[player] = s

	local function watch(attr: string, fn: (any) -> ())
		table.insert(s.conns, player:GetAttributeChangedSignal(attr):Connect(function()
			fn(player:GetAttribute(attr))
		end))
	end
	watch("PhoneOut", function(v)
		if v == true then
			bump(player, "phone", 1)
		end
	end)
	watch("Interior", function(v)
		if v == "Apartment" then
			bump(player, "apartment", 1)
		end
	end)
	local function visit(v: any)
		local q = sec(player)
		if q and type(v) == "string" and v ~= "" and v ~= "Outskirts" and not q.districts[v] then
			q.districts[v] = true
			needsSave[player] = true
			dirty[player] = true
		end
	end
	watch("District", visit)
	visit(player:GetAttribute("District"))
	local rides = player:GetAttribute("SubwayRides") or 0
	watch("SubwayRides", function(v)
		if type(v) == "number" and v > rides then
			bump(player, "subway", v - rides)
			-- the destination attribute may be written right after the counter
			task.defer(function()
				if player:GetAttribute("LastSubwayStation") == "Downtown" then
					bump(player, "subwayDowntown", 1)
				end
			end)
		end
		rides = if type(v) == "number" then v else rides
	end)
	local function crew(v: any)
		local q = sec(player)
		if q and type(v) == "string" and v ~= "" and q.life.crew < 1 then
			q.life.crew = 1
			needsSave[player] = true
			dirty[player] = true
		end
	end
	watch("CrewId", crew)
	crew(player:GetAttribute("CrewId"))
	watch("Followers", function()
		dirty[player] = true
	end)

	dirty[player] = true
	process(player)
	dirty[player] = nil
	pushState(player, true)
end

local function onRemoving(player: Player)
	local s = sessions[player]
	if s then
		flushDistance(player, s)
		for _, c in s.conns do
			c:Disconnect()
		end
	end
	sessions[player] = nil
	dirty[player] = nil
	needsSave[player] = nil
end

---------------------------------------------------------------------------
-- Remote handling
---------------------------------------------------------------------------
local function handle(player: Player, action: any, a: any, b: any): (boolean, string?)
	local q = sec(player)
	if not q or not sessions[player] then
		return false, "Your save is still loading."
	end
	if refreshPeriods(player, q) then
		PlayerData.markChanged(player)
	end
	if action == "Get" then
		return true, nil
	elseif action == "Claim" then
		local list = if a == "daily" then q.daily elseif a == "weekly" then q.weekly else nil
		if not list or type(b) ~= "number" or b % 1 ~= 0 then
			return false, "Unknown quest."
		end
		local quest = list[b]
		if not quest then
			return false, "Unknown quest."
		end
		if quest.claimed then
			return false, "Already claimed."
		end
		if progressOf(player, quest) < quest.goal then
			return false, "Not finished yet."
		end
		local def = DEFS[quest.id]
		quest.claimed = true
		q.life.questsDone += 1
		PlayerData.markChanged(player)
		local label = (if a == "weekly" then "Quest (weekly): " else "Quest: ") .. questText(def, quest.goal)
		PlayerData.addCash(player, quest.cash, label)
		PlayerData.addXP(player, quest.xp)
		PlayerData.addReputation(player, quest.rep)
		dirty[player] = true
		return true, string.format("+$%s  +%s XP  +%d rep", QC.commas(quest.cash), QC.commas(quest.xp), quest.rep)
	elseif action == "Reroll" then
		if q.rerollDay == utcDay() then
			return false, "You already used today's free reroll."
		end
		local quest = type(a) == "number" and a % 1 == 0 and q.daily[a]
		if not quest then
			return false, "Unknown quest."
		end
		if quest.claimed then
			return false, "That quest is already claimed."
		end
		local options = candidates(player, QC.DAILY_POOL, q.daily)
		if #options == 0 then
			return false, "No other quests available right now."
		end
		q.daily[a] = makeQuest(player, options[rng:NextInteger(1, #options)], false)
		q.rerollDay = utcDay()
		PlayerData.markChanged(player)
		dirty[player] = true
		return true, "New quest: " .. questText(DEFS[q.daily[a].id], q.daily[a].goal)
	elseif action == "ClaimLogin" then
		return claimLogin(player)
	end
	return false, "Unknown action."
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Quests.start(city: Instance)
	cityModel = city
	QuestsEvent = Net.remote("RemoteEvent", "QuestsEvent")
	local Request = Net.remote("RemoteFunction", "QuestsRequest")

	Request.OnServerInvoke = function(player: Player, action: any, a: any, b: any)
		if type(action) ~= "string" or not Net.allow(player, "QuestsRequest", 0.25) then
			return false, "Slow down.", nil
		end
		-- [Security] errors come back as a failure instead of being thrown into the client
		local pok, ok, msg, state = pcall(function()
			local ok, msg = handle(player, action, a, b)
			if ok and action ~= "Get" then
				process(player) -- reflect the claim immediately
			end
			local state = stateFor(player)
			return ok, msg, state and withTimers(state)
		end)
		if not pok then
			warn("[Security] QuestsRequest failed:", ok)
			return false, "Something went wrong.", nil
		end
		return ok, msg, state
	end

	-- Every made shot on any court (pickup games or just shooting around).
	local Basketball = sibling("Basketball")
	if Basketball and Basketball.scored then
		Basketball.scored.connect(function(_ball, _hoop, shot)
			local shooter = type(shot) == "table" and shot.shooter
			if typeof(shooter) == "Instance" and shooter:IsA("Player") then
				bump(shooter, "shots", 1)
			end
		end)
	end

	PlayerData.onLoaded(onLoaded)
	Players.PlayerRemoving:Connect(onRemoving)

	-- Debounced processing of changed players.
	task.spawn(function()
		while true do
			task.wait(0.5)
			for player in table.clone(dirty) do
				dirty[player] = nil
				if player.Parent then
					local ok, err = pcall(process, player)
					if not ok then
						warn("[CityGrind] Quests process failed:", err)
					end
				end
			end
		end
	end)

	-- Distance sampling + periodic refresh (day rollover, followers, districts).
	task.spawn(function()
		local tick = 0
		while true do
			task.wait(1)
			tick += 1
			local now = os.clock()
			for player, s in sessions do
				if player.Parent then
					sample(player, s, now)
					if tick % 10 == 0 then
						flushDistance(player, s)
					end
					if tick % 30 == 0 then
						dirty[player] = true
					end
				end
			end
		end
	end)
end

return Quests
