-- CITY GRIND: ranked basketball and seasons (spec 54, 55). Server side.
--
-- Ranked queue: 1v1 (solo) and 2v2 (a party of exactly 2 queues together, or
-- solos get paired). Requirements: Level >= RankedConfig.MIN_LEVEL and a
-- "hooper rating" (average basketball stat) >= MIN_HOOPER_RATING. Matchmaking
-- runs inside this server: the allowed rating gap widens the longer you wait.
-- A match takes a free public court (no event, no pickup game), summons both
-- teams there and is played through CourtGames.startMatch; the result comes back
-- through its onEnded callback.
--
-- Rating: Elo with a games-played K factor ("Glicko-lite"), start 1000, 5
-- placement games per season (bigger K), margin-of-victory and win-streak
-- bonuses, tiers Bronze..Legend with divisions III/II/I (RankedConfig.tierOf).
-- Leavers lose rating (+ an extra penalty) and the remaining team wins.
-- Anti-boosting: games shorter than MIN_SECONDS or under MIN_POINTS total are
-- "no contest"; after MAX_SAME_OPPONENT_PER_DAY rated games against the same
-- player in a UTC day, further games against them are unrated.
--
-- Seasons follow a fixed schedule from RankedConfig.SEASON_EPOCH, so every
-- server agrees without talking. On the first tick after a season ends (and when
-- a player joins with an older saved season) the player's final tier pays out
-- cash, XP, the title "S<n> <Tier>" and, for Platinum and up, an exclusive season
-- badge (a coloured tag over the head + profile badge colour) and, when the shop
-- catalog defines it, a wardrobe item. Ratings then soft-reset toward 1000.
-- Ranked.seasonEnded fires and one server (guarded by a DataStore key) calls
-- Leaderboards.archive(seasonId).
--
-- Remotes: RankedRequest (RemoteFunction, client -> server: action, arg) -> (ok, message, state)
--            actions: "Get" | "Queue" (mode "1v1"/"2v2") | "Leave" | "Badge" (season id or "" to hide)
--          RankedEvent (RemoteEvent, server -> client):
--            ("State", state) | ("Found", info) | ("Result", info) | ("Open")
-- Player attributes: Rating, RankedWins, RankedLosses (this season), WinStreak,
--   SeasonRank (tier name, or "Unranked" during placements), RankedTier ("Gold II"),
--   RankedPlacements (placement games left), RankedPeak, RankedQueue ("" | "1v1" | "2v2"),
--   RankedBadge ("S1 Diamond" or ""), RankedBadgeColor (Color3)
-- Saved section "ranked": see the registerSection default below.
--
-- Public API:
--   Ranked.season() -> {id, number, name, startsAt, endsAt}
--   Ranked.seasonEnded: BindableEvent (seasonId)
--   Ranked.ratingOf(player) -> number?        Ranked.isQueued(player) -> boolean
--   Ranked.inMatch(player) -> boolean         Ranked.titles(player) -> {string}

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local RC = require(shared:WaitForChild("RankedConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Places = require(script.Parent:WaitForChild("Places"))
local CourtGames = require(script.Parent:WaitForChild("CourtGames"))

local Ranked = {}
Ranked.seasonEnded = Instance.new("BindableEvent")

local SECTION = "ranked"
local LEAGUE = "City Hoops League"

local function now(): number
	return os.time()
end

local currentSeason: RC.Season = RC.seasonAt(now())

PlayerData.registerSection(SECTION, function()
	return {
		season = RC.seasonAt(os.time()).id, -- season these numbers belong to
		rating = RC.START_RATING,
		peak = RC.START_RATING,
		wins = 0,
		losses = 0,
		streak = 0, -- current win streak
		bestStreak = 0,
		placementsLeft = RC.PLACEMENTS,
		games = 0, -- rated games this season
		life = { wins = 0, losses = 0, games = 0, bestStreak = 0, peak = RC.START_RATING },
		history = {}, -- last matches: { t, mode, result, score, delta, rating, opp }
		seasons = {}, -- past seasons: { id, rating, peak, tier, wins, losses, placed, reward }
		badges = {}, -- exclusive season badges: { id, tier }
		badge = "", -- season id of the badge on show ("" = hidden)
		titles = {}, -- season titles earned ("S1 Diamond")
		daily = { day = 0, vs = {} }, -- rated games per opponent UserId today
		quits = 0,
	}
end)

local function sec(player: Player): any
	return PlayerData.section(player, SECTION)
end

---------------------------------------------------------------------------
-- Lazy links to optional modules
---------------------------------------------------------------------------
local function optional(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

local function unlock(player: Player, id: string)
	local Quests = optional("Quests")
	if Quests and Quests.unlock then
		pcall(Quests.unlock, player, id)
	end
end

local function submitRating(player: Player, r: any)
	if r.placementsLeft > 0 then
		return
	end
	local Leaderboards = optional("Leaderboards")
	if Leaderboards and Leaderboards.submit then
		pcall(Leaderboards.submit, "rating", player, r.rating)
	end
end

local function systemMessage(player: Player, text: string)
	local Messages = optional("Messages")
	if Messages and Messages.sendSystem then
		pcall(Messages.sendSystem, player, LEAGUE, text)
	end
end

local function inEvent(player: Player): boolean
	local ev = player:GetAttribute("Event")
	return ev ~= nil and ev ~= ""
end

-- In a race, a race lobby or a street race (Racing's "Race" attribute).
local function inRace(player: Player): boolean
	local race = player:GetAttribute("Race")
	return race ~= nil and race ~= ""
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function hooperRating(player: Player): number
	local total = 0
	for _, stat in RC.HOOPER_STATS do
		total += tonumber(player:GetAttribute(stat)) or 1
	end
	return math.floor(total / #RC.HOOPER_STATS * 10 + 0.5) / 10
end

local function label(r: any): string
	if r.placementsLeft > 0 then
		return string.format("Placement %d/%d", RC.PLACEMENTS - r.placementsLeft + 1, RC.PLACEMENTS)
	end
	return RC.tierOf(r.rating).label
end

local function seasonRankName(r: any): string
	return if r.placementsLeft > 0 then "Unranked" else RC.tierOf(r.rating).tier
end

local function badgeTierOf(r: any, id: string): string?
	for _, b in r.badges do
		if b.id == id then
			return b.tier
		end
	end
	return nil
end

local function today(): number
	return math.floor(now() / 86400)
end

local function dailyVs(r: any): { [string]: number }
	if type(r.daily) ~= "table" or r.daily.day ~= today() then
		r.daily = { day = today(), vs = {} }
	end
	return r.daily.vs
end

local function addTitle(player: Player, r: any, title: string)
	if not table.find(r.titles, title) then
		table.insert(r.titles, title)
	end
	-- Social's title picker lists Quests titles, so the season title goes there too.
	local q = PlayerData.section(player, "quests")
	if q and type(q.titles) == "table" and not table.find(q.titles, title) then
		table.insert(q.titles, title)
	end
end

---------------------------------------------------------------------------
-- Attributes and the season badge over the head
---------------------------------------------------------------------------
local function refreshBadgeTag(player: Player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return
	end
	local text = player:GetAttribute("RankedBadge")
	local color = player:GetAttribute("RankedBadgeColor")
	local gui = head:FindFirstChild("RankedBadgeTag") :: BillboardGui?
	if type(text) ~= "string" or text == "" or typeof(color) ~= "Color3" then
		if gui then
			gui:Destroy()
		end
		return
	end
	if not gui then
		local g = Instance.new("BillboardGui")
		g.Name = "RankedBadgeTag"
		g.Size = UDim2.fromOffset(150, 22)
		g.StudsOffset = Vector3.new(0, 4.9, 0) -- just above the name tag
		g.MaxDistance = 80
		g.LightInfluence = 0
		g.ResetOnSpawn = false
		g.Adornee = head
		local pill = Instance.new("TextLabel")
		pill.Name = "Pill"
		pill.AnchorPoint = Vector2.new(0.5, 0.5)
		pill.Position = UDim2.fromScale(0.5, 0.5)
		pill.Size = UDim2.fromScale(1, 1)
		pill.AutomaticSize = Enum.AutomaticSize.None
		pill.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
		pill.BackgroundTransparency = 0.15
		pill.Font = Enum.Font.GothamBlack
		pill.TextSize = 12
		pill.TextColor3 = Color3.new(1, 1, 1)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = pill
		local stroke = Instance.new("UIStroke")
		stroke.Name = "Ring"
		stroke.Thickness = 2
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = pill
		pill.Parent = g
		g.Parent = head
		gui = g
	end
	local pill = (gui :: BillboardGui):FindFirstChild("Pill") :: TextLabel?
	if pill then
		pill.Text = "◆ " .. string.upper(text) .. " ◆"
		pill.TextColor3 = color
		local ring = pill:FindFirstChild("Ring") :: UIStroke?
		if ring then
			ring.Color = color
		end
	end
end

local function publishRanked(player: Player, r: any)
	player:SetAttribute("Rating", r.rating)
	player:SetAttribute("RankedWins", r.wins)
	player:SetAttribute("RankedLosses", r.losses)
	player:SetAttribute("WinStreak", math.max(0, r.streak))
	player:SetAttribute("SeasonRank", seasonRankName(r))
	player:SetAttribute("RankedTier", label(r))
	player:SetAttribute("RankedPlacements", r.placementsLeft)
	player:SetAttribute("RankedPeak", r.peak)
	local tier = if r.badge ~= "" then badgeTierOf(r, r.badge) else nil
	local badgeText = if tier then RC.seasonTitle(r.badge, tier) else ""
	if player:GetAttribute("RankedBadge") ~= badgeText then
		player:SetAttribute("RankedBadge", badgeText)
		player:SetAttribute("RankedBadgeColor", if tier then RC.tierColor(tier) else nil)
		refreshBadgeTag(player)
	end
end

PlayerData.onPublish(function(player, data)
	local r = data.sections and data.sections[SECTION]
	if r then
		publishRanked(player, r)
	end
end)

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local RankedRequest = Net.remote("RemoteFunction", "RankedRequest")
local RankedEvent = Net.remote("RemoteEvent", "RankedEvent")

---------------------------------------------------------------------------
-- Seasons
---------------------------------------------------------------------------
function Ranked.season(): RC.Season
	return table.clone(currentSeason)
end

-- Settles a player's finished season (rewards + soft reset) when their saved
-- season is older than the live one. Safe to call any time.
local function settleSeason(player: Player): boolean
	local r = sec(player)
	if not r or r.season == currentSeason.id then
		return false
	end
	local oldId = tostring(r.season)
	local placed = r.placementsLeft <= 0 and r.games > 0
	local entry = { id = oldId, rating = r.rating, peak = r.peak, wins = r.wins, losses = r.losses, placed = placed, tier = "Unranked", reward = "" }
	if placed then
		local tier = RC.tierOf(r.rating).tier
		local reward = RC.REWARDS[tier] or { cash = 0, xp = 0 }
		entry.tier = tier
		local parts = {}
		if reward.cash and reward.cash > 0 then
			PlayerData.addCash(player, reward.cash, oldId .. " ranked reward: " .. tier)
			table.insert(parts, "$" .. reward.cash)
		end
		if reward.xp and reward.xp > 0 then
			PlayerData.addXP(player, reward.xp)
			table.insert(parts, reward.xp .. " XP")
		end
		local title = RC.seasonTitle(oldId, tier)
		addTitle(player, r, title)
		table.insert(parts, 'the "' .. title .. '" title')
		if reward.badge then
			if not badgeTierOf(r, oldId) then
				table.insert(r.badges, { id = oldId, tier = tier })
			end
			r.badge = oldId -- show the newest one; the app can switch or hide it
			table.insert(parts, "the exclusive " .. title .. " badge")
		end
		if reward.item then
			local ok, SC = pcall(require, shared:FindFirstChild("ShopsConfig") :: ModuleScript)
			local item = ok and SC and SC.ITEMS and SC.ITEMS[reward.item]
			local w = PlayerData.section(player, "wardrobe")
			if item and w and type(w.owned) == "table" then
				if not table.find(w.owned, reward.item) then
					table.insert(w.owned, reward.item)
				end
				table.insert(parts, "the " .. tostring(item.name) .. " (in your Closet)")
			end
		end
		entry.reward = table.concat(parts, ", ")
		unlock(player, "ranked_season_reward")
		local text = string.format("%s is over! You finished %s (%d rating). Rewards: %s. %s has started: play %d placement games to get ranked again.", oldId, tier, r.rating, entry.reward, currentSeason.name, RC.PLACEMENTS)
		systemMessage(player, text)
		Net.notify(player, "SEASON REWARDS", oldId .. " finished " .. tier .. ": " .. entry.reward)
	elseif r.games > 0 or r.placementsLeft < RC.PLACEMENTS then
		Net.notify(player, "NEW SEASON", currentSeason.name .. " has started. Finish your placements to earn season rewards.")
	end
	table.insert(r.seasons, 1, entry)
	while #r.seasons > RC.SEASON_HISTORY_LIMIT do
		table.remove(r.seasons)
	end
	-- soft reset toward the start rating
	r.rating = math.max(RC.MIN_RATING, math.floor(RC.START_RATING + (r.rating - RC.START_RATING) * RC.SOFT_RESET + 0.5))
	r.peak = r.rating
	r.wins, r.losses, r.streak, r.games = 0, 0, 0, 0
	r.placementsLeft = RC.PLACEMENTS
	r.season = currentSeason.id
	PlayerData.markChanged(player)
	return true
end

-- One server archives each finished season's leaderboards: the first to
-- write the DataStore key wins.
local archiveStore: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore("CityGrind_Ranked_v1")
	end)
	if ok then
		archiveStore = result
	end
end
local archivedHere: { [string]: boolean } = {}

local function tryArchive(seasonId: string, witnessed: boolean)
	if archivedHere[seasonId] then
		return
	end
	local Leaderboards = optional("Leaderboards")
	if not Leaderboards or not Leaderboards.archive then
		return
	end
	local claimed = false
	local reached = false
	if archiveStore then
		for attempt = 1, 3 do
			local ok, err = pcall(function()
				(archiveStore :: DataStore):UpdateAsync("archive_" .. seasonId, function(old)
					claimed = false
					if old ~= nil then
						return nil -- someone already archived it
					end
					claimed = true
					return { by = game.JobId, t = os.time() }
				end)
			end)
			if ok then
				reached = true
				break
			end
			warn("[CityGrind] Ranked archive guard failed (attempt " .. attempt .. "):", err)
			task.wait(2 * attempt)
		end
	end
	if not reached then
		-- No DataStore (Studio without API access): only the server that saw the
		-- season end live archives, so nothing is archived twice by late starters.
		claimed = witnessed and RunService:IsStudio()
	end
	archivedHere[seasonId] = true
	if claimed then
		local ok, err = pcall(Leaderboards.archive, seasonId)
		if not ok then
			warn("[CityGrind] Leaderboards.archive failed for", seasonId, err)
		end
	end
end

---------------------------------------------------------------------------
-- State for the phone
---------------------------------------------------------------------------
type Entry = {
	id: number,
	mode: string,
	players: { Player },
	rating: number,
	joinedAt: number, -- os.clock()
	joinedTime: number, -- os.time()
	status: string,
}
type Match = {
	id: number,
	mode: string,
	court: Model,
	courtName: string,
	home: { Player },
	away: { Player },
	before: { [Player]: number },
	names: { [Player]: string },
	userIds: { [Player]: number },
	penalized: { [Player]: boolean },
	state: string, -- "Live" | "Done"
}

local queue: { Entry } = {}
local entryOf: { [Player]: Entry } = {}
local matchOf: { [Player]: Match } = {}
local nextId = 0

local function window(entry: Entry): number
	local waited = os.clock() - entry.joinedAt
	return math.min(RC.WINDOW_MAX, RC.WINDOW_START + math.floor(waited / RC.WINDOW_STEP) * RC.WINDOW_GROWTH)
end

local function eligibility(player: Player): (boolean, string?)
	if not PlayerData.isLoaded(player) or not sec(player) then
		return false, "Your save is still loading."
	end
	local level = tonumber(player:GetAttribute("Level")) or 1
	if level < RC.MIN_LEVEL then
		return false, "Ranked unlocks at level " .. RC.MIN_LEVEL .. " (you're level " .. level .. ")."
	end
	local hooper = hooperRating(player)
	if hooper < RC.MIN_HOOPER_RATING then
		return false, string.format("Your hooper rating is %.1f; ranked needs %d. Train at the gym or play pickup games.", hooper, RC.MIN_HOOPER_RATING)
	end
	return true, nil
end

local function availability(player: Player): (boolean, string?)
	if entryOf[player] then
		return false, "Already in the ranked queue."
	end
	if matchOf[player] then
		return false, "Already in a ranked match."
	end
	if player:GetAttribute("InGame") then
		return false, "Finish your current game first."
	end
	if inEvent(player) then
		return false, "Leave your city event first."
	end
	if inRace(player) then
		return false, "Finish your race first."
	end
	return true, nil
end

local function queueCounts(): { [string]: number }
	local counts = { ["1v1"] = 0, ["2v2"] = 0 }
	for _, e in queue do
		counts[e.mode] += #e.players
	end
	return counts
end

local function stateFor(player: Player): any
	local r = sec(player)
	if not r then
		return nil
	end
	local ok, reason = eligibility(player)
	local entry = entryOf[player]
	local match = matchOf[player]
	local Party = optional("Party")
	local party = Party and Party.partyOf and Party.partyOf(player)
	local tier = RC.tierOf(r.rating)
	return {
		season = Ranked.season(),
		serverNow = now(),
		rating = r.rating,
		peak = r.peak,
		wins = r.wins,
		losses = r.losses,
		streak = r.streak,
		bestStreak = r.bestStreak,
		placementsLeft = r.placementsLeft,
		games = r.games,
		label = label(r),
		tier = tier.tier,
		progress = tier.progress,
		nextAt = tier.nextAt,
		life = table.clone(r.life),
		history = table.clone(r.history),
		seasons = table.clone(r.seasons),
		badges = table.clone(r.badges),
		badge = r.badge,
		titles = table.clone(r.titles),
		eligible = ok,
		reason = reason,
		level = tonumber(player:GetAttribute("Level")) or 1,
		hooper = hooperRating(player),
		partySize = if party then #party.members else 0,
		queue = if entry
			then {
				mode = entry.mode,
				waited = os.clock() - entry.joinedAt,
				window = window(entry),
				status = entry.status,
				group = #entry.players,
			}
			else nil,
		match = if match then { mode = match.mode, court = match.courtName } else nil,
		counts = queueCounts(),
	}
end

local function push(player: Player)
	if player.Parent then
		local state = stateFor(player)
		if state then
			RankedEvent:FireClient(player, "State", state)
		end
	end
end

local function setQueueAttr(player: Player, mode: string)
	if player.Parent then
		player:SetAttribute("RankedQueue", mode)
	end
end

---------------------------------------------------------------------------
-- Queue
---------------------------------------------------------------------------
local function removeEntry(entry: Entry, notice: string?)
	local i = table.find(queue, entry)
	if i then
		table.remove(queue, i)
	end
	for _, p in entry.players do
		if entryOf[p] == entry then
			entryOf[p] = nil
			setQueueAttr(p, "")
			if notice and p.Parent then
				Net.notify(p, "RANKED QUEUE", notice)
			end
			push(p)
		end
	end
end

local function joinQueue(player: Player, mode: any): (boolean, string)
	if mode ~= "1v1" and mode ~= "2v2" then
		return false, "Pick 1v1 or 2v2."
	end
	local group = { player }
	if mode == "2v2" then
		local Party = optional("Party")
		local party = Party and Party.partyOf and Party.partyOf(player)
		if party and #party.members > 2 then
			return false, "Ranked 2v2 takes a party of exactly 2. Leave the party to queue solo."
		elseif party and #party.members == 2 then
			group = table.clone(party.members)
		end
	end
	for _, p in group do
		local who = if p == player then "You" else p.DisplayName
		local ok, reason = eligibility(p)
		if not ok then
			return false, if p == player then (reason or "You can't queue yet.") else (who .. " can't play ranked yet: " .. (reason or ""))
		end
		local free, why = availability(p)
		if not free then
			return false, if p == player then (why or "You're busy.") else (who .. " is busy: " .. (why or ""))
		end
	end
	nextId += 1
	local total = 0
	for _, p in group do
		total += sec(p).rating
	end
	local entry: Entry = {
		id = nextId,
		mode = mode,
		players = group,
		rating = total / #group,
		joinedAt = os.clock(),
		joinedTime = now(),
		status = "Searching",
	}
	table.insert(queue, entry)
	for _, p in group do
		entryOf[p] = entry
		setQueueAttr(p, mode)
		if p ~= player then
			Net.notify(p, "RANKED QUEUE", player.DisplayName .. " queued your party for ranked 2v2.")
		end
		push(p)
	end
	return true, if #group == 2 then "Queued for ranked 2v2 with your partner." else "Queued for ranked " .. mode .. "."
end

---------------------------------------------------------------------------
-- Courts
---------------------------------------------------------------------------
local function publicCourt(m: Instance): boolean
	if not m:IsA("Model") or not m.Parent or m.Name:find("Private") then
		return false
	end
	local center = m:GetAttribute("CourtCenter")
	return typeof(center) == "Vector3" and center.Y < 20 and typeof(m:GetAttribute("CourtSize")) == "Vector3"
end

local function pickCourt(): Model?
	local courts = {}
	for _, m in CollectionService:GetTagged("Court") do
		if publicCourt(m) and CourtGames.isFree(m) then
			table.insert(courts, m)
		end
	end
	table.sort(courts, function(a, b)
		local ia = table.find(RC.PREFERRED_COURTS, a.Name) or 99
		local ib = table.find(RC.PREFERRED_COURTS, b.Name) or 99
		if ia ~= ib then
			return ia < ib
		end
		return a.Name < b.Name
	end)
	return courts[1]
end

---------------------------------------------------------------------------
-- Rating math
---------------------------------------------------------------------------
local function kFactor(r: any): number
	if r.placementsLeft > 0 then
		return RC.K_PLACEMENT
	elseif r.games < RC.K_NEW_GAMES then
		return RC.K_NEW
	end
	return RC.K
end

local function expected(mine: number, theirs: number): number
	return 1 / (1 + 10 ^ ((theirs - mine) / 400))
end

local function teamAverage(match: Match, list: { Player }): number
	local total, n = 0, 0
	for _, p in list do
		total += match.before[p] or RC.START_RATING
		n += 1
	end
	return if n > 0 then total / n else RC.START_RATING
end

local function sideOf(match: Match, player: Player): ({ Player }, { Player })
	if table.find(match.home, player) then
		return match.home, match.away
	end
	return match.away, match.home
end

local function oppNames(match: Match, opponents: { Player }): string
	local names = {}
	for _, p in opponents do
		table.insert(names, match.names[p] or "?")
	end
	return table.concat(names, " & ")
end

local function addHistory(r: any, item: any)
	table.insert(r.history, 1, item)
	while #r.history > RC.HISTORY_LIMIT do
		table.remove(r.history)
	end
end

-- Applies one rated result to a player's save. Returns (delta, streakBonus).
local function applyRated(player: Player, r: any, won: boolean, mine: number, theirs: number, margin: number, extraLoss: number): (number, number)
	local k = kFactor(r)
	local e = expected(mine, theirs)
	local mov = 1 + RC.MARGIN_BONUS * math.clamp(margin / Config.Game.TARGET_SCORE, 0, 1)
	local delta = math.floor(k * ((if won then 1 else 0) - e) * mov + 0.5)
	local bonus = 0
	local wasPlacement = r.placementsLeft > 0
	if won then
		delta = math.max(RC.MIN_CHANGE, delta)
		r.wins += 1
		r.life.wins += 1
		r.streak = math.max(0, r.streak) + 1
		r.bestStreak = math.max(r.bestStreak, r.streak)
		r.life.bestStreak = math.max(r.life.bestStreak, r.streak)
		if not wasPlacement and r.streak >= RC.STREAK_FROM then
			bonus = math.min(RC.STREAK_BONUS_MAX, (r.streak - RC.STREAK_FROM + 1) * RC.STREAK_BONUS)
		end
	else
		delta = math.min(-RC.MIN_CHANGE, delta) - extraLoss
		r.losses += 1
		r.life.losses += 1
		r.streak = 0
	end
	delta += bonus
	r.rating = math.max(RC.MIN_RATING, r.rating + delta)
	r.peak = math.max(r.peak, r.rating)
	r.life.peak = math.max(r.life.peak, r.rating)
	r.games += 1
	r.life.games += 1
	if r.placementsLeft > 0 then
		r.placementsLeft -= 1
	end
	-- achievements (the lead adds these ids to QuestsConfig)
	if won and r.life.wins == 1 then
		unlock(player, "ranked_first_win")
	end
	if r.streak >= 5 then
		unlock(player, "ranked_streak_5")
	end
	if r.placementsLeft == 0 then
		if wasPlacement then
			unlock(player, "ranked_placed")
		end
		local idx = RC.tierOf(r.rating).index
		if idx >= (RC.TIER_INDEX.Gold or 3) then
			unlock(player, "ranked_gold")
		end
		if idx >= (RC.TIER_INDEX.Diamond or 5) then
			unlock(player, "ranked_diamond")
		end
		if idx >= (RC.TIER_INDEX.Legend or 7) then
			unlock(player, "ranked_legend")
		end
	end
	return delta, bonus
end

local function sendResult(player: Player, info: any)
	if player.Parent then
		pcall(function()
			RankedEvent:FireClient(player, "Result", info)
		end)
		push(player)
	end
end

local function scoreText(match: Match, player: Player, score: { Home: number, Away: number }): string
	if table.find(match.home, player) then
		return score.Home .. "-" .. score.Away
	end
	return score.Away .. "-" .. score.Home
end

-- A player who quits a live ranked match: a loss plus the leaver penalty.
-- Runs at most once per player per match, and synchronously on PlayerRemoving
-- so the change lands before PlayerData's final save.
local function penalizeLeaver(match: Match, player: Player, score: { Home: number, Away: number }?)
	if match.penalized[player] then
		return
	end
	match.penalized[player] = true
	local r = sec(player)
	if not r then
		return
	end
	local mine, theirs = sideOf(match, player)
	local oldLabel = label(r)
	local delta = applyRated(player, r, false, teamAverage(match, mine), teamAverage(match, theirs), 0, RC.LEAVER_EXTRA)
	r.quits = (r.quits or 0) + 1
	addHistory(r, {
		t = now(),
		mode = match.mode,
		result = "QUIT",
		score = if score then scoreText(match, player, score) else "-",
		delta = delta,
		rating = r.rating,
		opp = oppNames(match, theirs),
	})
	PlayerData.markChanged(player)
	submitRating(player, r)
	sendResult(player, {
		result = "QUIT",
		delta = delta,
		bonus = 0,
		rating = r.rating,
		label = label(r),
		oldLabel = oldLabel,
		placementsLeft = r.placementsLeft,
		streak = r.streak,
		score = if score then scoreText(match, player, score) else "-",
		reason = "You left a ranked match: counted as a loss with a " .. RC.LEAVER_EXTRA .. " point penalty.",
	})
end

local function resolveMatch(match: Match, result: any)
	if match.state == "Done" then
		return
	end
	match.state = "Done"
	local everyone = table.clone(match.home)
	for _, p in match.away do
		table.insert(everyone, p)
	end
	for _, p in everyone do
		if matchOf[p] == match then
			matchOf[p] = nil
		end
	end

	local score = result.score
	local total = score.Home + score.Away
	local margin = math.abs(score.Home - score.Away)
	local counts = result.duration >= RC.MIN_SECONDS and (result.forfeit or total >= RC.MIN_POINTS)
	local leavers = {}
	for _, p in result.leavers do
		leavers[p] = true
	end

	for _, p in everyone do
		if match.penalized[p] then
			continue
		end
		if leavers[p] then
			penalizeLeaver(match, p, score)
			continue
		end
		local r = p.Parent and sec(p)
		if not r then
			continue
		end
		local mine, theirs = sideOf(match, p)
		local side = if mine == match.home then "Home" else "Away"
		local won = result.winner == side
		local oldLabel = label(r)
		local info: any = {
			delta = 0,
			bonus = 0,
			score = scoreText(match, p, score),
			oldLabel = oldLabel,
		}
		-- same-opponent cap for the day
		local vs = dailyVs(r)
		local capped = false
		for _, o in theirs do
			if (vs[tostring(match.userIds[o])] or 0) >= RC.MAX_SAME_OPPONENT_PER_DAY then
				capped = true
			end
		end
		if not counts or result.winner == nil then
			info.result = "NC"
			info.reason = string.format("No contest: ranked games need %d+ seconds and %d+ points to count.", RC.MIN_SECONDS, RC.MIN_POINTS)
		elseif capped then
			info.result = "UNRATED"
			info.reason = string.format("Unrated: you've already played %s %d times today.", oppNames(match, theirs), RC.MAX_SAME_OPPONENT_PER_DAY)
		else
			for _, o in theirs do
				local key = tostring(match.userIds[o])
				vs[key] = (vs[key] or 0) + 1
			end
			local delta, bonus = applyRated(p, r, won, teamAverage(match, mine), teamAverage(match, theirs), margin, 0)
			info.result = if won then "W" else "L"
			info.delta = delta
			info.bonus = bonus
			if won then
				PlayerData.addCash(p, RC.WIN_CASH, "Ranked " .. match.mode .. " win")
				PlayerData.addXP(p, RC.WIN_XP)
				PlayerData.addReputation(p, RC.WIN_REP)
				info.cash, info.xp = RC.WIN_CASH, RC.WIN_XP
			else
				PlayerData.addCash(p, RC.LOSS_CASH, "Ranked " .. match.mode .. " game")
				PlayerData.addXP(p, RC.LOSS_XP)
				PlayerData.addReputation(p, RC.LOSS_REP)
				info.cash, info.xp = RC.LOSS_CASH, RC.LOSS_XP
			end
			if result.forfeit then
				info.reason = "Your opponent left: the win is yours."
			end
		end
		addHistory(r, {
			t = now(),
			mode = match.mode,
			result = info.result,
			score = info.score,
			delta = info.delta,
			rating = r.rating,
			opp = oppNames(match, theirs),
		})
		PlayerData.markChanged(p)
		submitRating(p, r)
		info.rating = r.rating
		info.label = label(r)
		info.placementsLeft = r.placementsLeft
		info.streak = r.streak
		sendResult(p, info)
	end
end

---------------------------------------------------------------------------
-- Matchmaking
---------------------------------------------------------------------------
type Unit = { entries: { Entry }, players: { Player }, rating: number, joinedAt: number, window: number }

local function unitOf(entries: { Entry }): Unit
	local players, total, joined, win = {}, 0, math.huge, 0
	for _, e in entries do
		for _, p in e.players do
			table.insert(players, p)
			total += sec(p) and sec(p).rating or e.rating
		end
		joined = math.min(joined, e.joinedAt)
		win = math.max(win, window(e))
	end
	return { entries = entries, players = players, rating = total / math.max(1, #players), joinedAt = joined, window = win }
end

-- Pairs units (oldest first) whose ratings fall inside the wider window.
local function pairUnits(units: { Unit }): { { Unit } }
	table.sort(units, function(a, b)
		return a.joinedAt < b.joinedAt
	end)
	local used: { [Unit]: boolean } = {}
	local pairs_ = {}
	for _, a in units do
		if not used[a] then
			local best, bestGap = nil, math.huge
			for _, b in units do
				if b ~= a and not used[b] then
					local gap = math.abs(a.rating - b.rating)
					if gap <= math.max(a.window, b.window) and gap < bestGap then
						best, bestGap = b, gap
					end
				end
			end
			if best then
				used[a], used[best] = true, true
				table.insert(pairs_, { a, best })
			end
		end
	end
	return pairs_
end

local function candidates(mode: string): { { Unit } }
	local solos, units = {}, {}
	for _, e in queue do
		if e.mode == mode then
			if #e.players == RC.TEAM_SIZE[mode] then
				table.insert(units, unitOf({ e }))
			else
				table.insert(solos, unitOf({ e }))
			end
		end
	end
	if mode == "2v2" then
		-- two solos make a team when their ratings are close enough
		for _, duo in pairUnits(solos) do
			table.insert(units, unitOf({ duo[1].entries[1], duo[2].entries[1] }))
		end
	end
	return pairUnits(units)
end

local function summon(player: Player, court: Model, team: string, index: number, count: number)
	local center = court:GetAttribute("CourtCenter") :: Vector3
	local zSide = if team == "Home" then 6 else -6
	local facing = if team == "Home" then Vector3.new(0, 0, -1) else Vector3.new(0, 0, 1)
	local pos = center + Vector3.new((index - (count + 1) / 2) * 7, 0.5, zSide)
	-- Out of any seat first: with the SeatWeld still there, moving the character
	-- would drag (and fling) the car it sits in.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if humanoid and seat then
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		humanoid.Sit = false
	end
	Places.leave(player, CFrame.lookAt(pos, pos + facing))
end

local function startMatch(mode: string, a: Unit, b: Unit, court: Model): boolean
	nextId += 1
	local match: Match = {
		id = nextId,
		mode = mode,
		court = court,
		courtName = tostring(court:GetAttribute("DisplayName") or court.Name),
		home = a.players,
		away = b.players,
		before = {},
		names = {},
		userIds = {},
		penalized = {},
		state = "Live",
	}
	for _, list in { a.players, b.players } do
		for _, p in list do
			local r = sec(p)
			match.before[p] = if r then r.rating else RC.START_RATING
			match.names[p] = p.DisplayName
			match.userIds[p] = p.UserId
		end
	end
	local ok, err = CourtGames.startMatch(court, a.players, b.players, {
		label = "RANKED " .. mode,
		ranked = true,
		countdown = RC.MATCH_COUNTDOWN,
		onEnded = function(result)
			resolveMatch(match, result)
		end,
	})
	if not ok then
		warn("[CityGrind] Ranked match couldn't start:", err)
		return false
	end
	for _, unit in { a, b } do
		for _, e in unit.entries do
			local i = table.find(queue, e)
			if i then
				table.remove(queue, i)
			end
		end
	end
	for team, list in { Home = a.players, Away = b.players } do
		local opponents = if team == "Home" then b.players else a.players
		for i, p in list do
			entryOf[p] = nil
			matchOf[p] = match
			setQueueAttr(p, "")
			local vs = sec(p) and dailyVs(sec(p)) or {}
			local capped = false
			local opp = {}
			for _, o in opponents do
				if (vs[tostring(o.UserId)] or 0) >= RC.MAX_SAME_OPPONENT_PER_DAY then
					capped = true
				end
				local orr = sec(o)
				table.insert(opp, { name = o.DisplayName, userId = o.UserId, label = if orr then label(orr) else "?", rating = match.before[o] })
			end
			local mates = {}
			for _, m in list do
				if m ~= p then
					table.insert(mates, { name = m.DisplayName, userId = m.UserId })
				end
			end
			RankedEvent:FireClient(p, "Found", {
				mode = mode,
				court = match.courtName,
				team = team,
				opponents = opp,
				teammates = mates,
				countdown = RC.MATCH_COUNTDOWN,
				unrated = capped,
			})
			task.spawn(summon, p, court, team, i, #list)
			push(p)
		end
	end
	return true
end

local function matchmake()
	-- drop entries whose players can't play any more
	for _, e in table.clone(queue) do
		for _, p in e.players do
			if not p.Parent then
				removeEntry(e, p.DisplayName .. " left the server.")
				break
			elseif inEvent(p) or inRace(p) or p:GetAttribute("InGame") then
				removeEntry(e, p.DisplayName .. " joined something else, so the ranked queue was cancelled.")
				break
			end
		end
	end
	-- a match whose court vanished can never report back: call it no contest
	for _, match in matchOf do
		if match.state == "Live" and not match.court.Parent then
			resolveMatch(match, { winner = nil, score = { Home = 0, Away = 0 }, forfeit = false, duration = 0, leavers = {} })
		end
	end
	for _, e in queue do
		e.status = "Searching"
	end
	for _, mode in RC.MODES do
		for _, pair in candidates(mode) do
			local court = pickCourt()
			if not court then
				for _, unit in pair do
					for _, e in unit.entries do
						e.status = "Waiting for a free court"
					end
				end
				break
			end
			startMatch(mode, pair[1], pair[2], court)
		end
	end
end

---------------------------------------------------------------------------
-- Court kiosks: a "Ranked Queue" prompt beside each public court
---------------------------------------------------------------------------
local kioskFolder: Folder? = nil
local kiosked: { [Model]: boolean } = {}

local function buildKiosk(court: Model)
	if kiosked[court] or not kioskFolder or not publicCourt(court) then
		return
	end
	kiosked[court] = true
	local center = court:GetAttribute("CourtCenter") :: Vector3
	local size = court:GetAttribute("CourtSize") :: Vector3
	-- outside the south fence, east of the gate
	local base = center + Vector3.new(size.X / 2 - 2, 0, size.Z / 2 + 7)
	local model = Instance.new("Model")
	model.Name = "RankedKiosk_" .. court.Name
	local function part(name: string, s: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = s
		p.CFrame = cf
		p.Color = color
		p.Material = material
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end
	local post = part("Post", Vector3.new(0.8, 5, 0.8), CFrame.new(base + Vector3.new(0, 2.5, 0)), Color3.fromRGB(35, 35, 42), Enum.Material.Metal)
	local panel = part("Panel", Vector3.new(4.2, 2.6, 0.4), CFrame.new(base + Vector3.new(0, 5.6, 0)), Color3.fromRGB(18, 18, 24), Enum.Material.SmoothPlastic)
	part("Glow", Vector3.new(4.4, 0.2, 0.5), CFrame.new(base + Vector3.new(0, 4.25, 0)), RC.TIERS[5].color, Enum.Material.Neon)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = Vector2.new(210, 130)
		gui.LightInfluence = 0
		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, 0, 0.55, 0)
		title.Font = Enum.Font.GothamBlack
		title.TextScaled = true
		title.TextColor3 = RC.TIERS[3].color
		title.Text = "RANKED"
		title.Parent = gui
		local sub = Instance.new("TextLabel")
		sub.BackgroundTransparency = 1
		sub.Position = UDim2.fromScale(0, 0.58)
		sub.Size = UDim2.new(1, 0, 0.32, 0)
		sub.Font = Enum.Font.GothamBold
		sub.TextScaled = true
		sub.TextColor3 = Color3.new(1, 1, 1)
		sub.Text = "1v1  ·  2v2  ·  LV " .. RC.MIN_LEVEL .. "+"
		sub.Parent = gui
		gui.Parent = panel
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RankedQueue"
	prompt.ActionText = "Ranked Queue"
	prompt.ObjectText = "City Hoops League"
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = post
	prompt.Triggered:Connect(function(player)
		if Net.allow(player, "RankedKiosk", 1) then
			push(player)
			RankedEvent:FireClient(player, "Open")
		end
	end)
	model.Parent = kioskFolder
	court.AncestryChanged:Connect(function()
		if not court.Parent then
			model:Destroy()
			kiosked[court] = nil
		end
	end)
end

---------------------------------------------------------------------------
-- Remote handler
---------------------------------------------------------------------------
local function handle(player: Player, action: any, arg: any): (boolean, string?)
	if action == "Get" then
		return true, nil
	elseif action == "Queue" then
		return joinQueue(player, arg)
	elseif action == "Leave" then
		local entry = entryOf[player]
		if not entry then
			return false, "You're not in the queue."
		end
		removeEntry(entry, nil)
		for _, p in entry.players do
			if p ~= player and p.Parent then
				Net.notify(p, "RANKED QUEUE", player.DisplayName .. " left the ranked queue.")
			end
		end
		return true, "Left the ranked queue."
	elseif action == "Badge" then
		local r = sec(player)
		if not r or type(arg) ~= "string" then
			return false, "Try again."
		end
		if arg ~= "" and not badgeTierOf(r, arg) then
			return false, "You don't own that badge."
		end
		r.badge = arg
		PlayerData.markChanged(player)
		return true, if arg == "" then "Season badge hidden." else "Showing your " .. arg .. " badge."
	end
	return false, "Unknown action."
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Ranked.ratingOf(player: Player): number?
	local r = sec(player)
	return r and r.rating
end

function Ranked.isQueued(player: Player): boolean
	return entryOf[player] ~= nil
end

function Ranked.inMatch(player: Player): boolean
	return matchOf[player] ~= nil
end

function Ranked.titles(player: Player): { string }
	local r = sec(player)
	return if r then table.clone(r.titles) else {}
end

function Ranked.start(city: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Ranked"
	folder.Parent = city
	kioskFolder = folder
	for _, m in CollectionService:GetTagged("Court") do
		if m:IsA("Model") then
			buildKiosk(m)
		end
	end
	CollectionService:GetInstanceAddedSignal("Court"):Connect(function(m)
		if m:IsA("Model") then
			task.delay(1, buildKiosk, m) -- the tag lands before the court is finished
		end
	end)

	RankedRequest.OnServerInvoke = function(player: Player, action: any, arg: any)
		if not Net.allow(player, "RankedRequest", 0.25) then
			return false, "Slow down.", nil
		end
		local ok, msg = handle(player, action, arg)
		return ok, msg, stateFor(player)
	end

	PlayerData.onLoaded(function(player)
		settleSeason(player)
		local r = sec(player)
		if r then
			publishRanked(player, r)
			submitRating(player, r)
		end
	end)

	local function onCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			task.wait(0.5)
			refreshBadgeTag(player)
		end)
		if player.Character then
			task.defer(refreshBadgeTag, player)
		end
	end
	Players.PlayerAdded:Connect(onCharacter)
	for _, p in Players:GetPlayers() do
		onCharacter(p)
	end

	Players.PlayerRemoving:Connect(function(player)
		local entry = entryOf[player]
		if entry then
			removeEntry(entry, player.DisplayName .. " left the server. You're out of the ranked queue.")
		end
		local match = matchOf[player]
		if match and match.state == "Live" then
			-- before PlayerData's final save completes (its UpdateAsync yields first)
			local court = match.court
			penalizeLeaver(match, player, { Home = tonumber(court:GetAttribute("HomeScore")) or 0, Away = tonumber(court:GetAttribute("AwayScore")) or 0 })
		end
		matchOf[player] = nil
	end)

	-- A finished season that nobody archived yet (this server started after it ended).
	if currentSeason.number > 1 then
		task.spawn(tryArchive, "S" .. (currentSeason.number - 1), false)
	end

	-- Matchmaking + queue status + the season clock.
	task.spawn(function()
		local lastPush = 0
		while true do
			task.wait(1)
			local ok, err = pcall(matchmake)
			if not ok then
				warn("[CityGrind] Ranked matchmaking error:", err)
			end
			if os.clock() - lastPush >= 5 then
				lastPush = os.clock()
				for p in entryOf do
					push(p)
				end
			end
			local season = RC.seasonAt(now())
			if season.id ~= currentSeason.id then
				local ended = currentSeason.id
				currentSeason = season
				for _, p in Players:GetPlayers() do
					local settled, settleErr = pcall(settleSeason, p)
					if not settled then
						warn("[CityGrind] Season settle failed for", p.Name, settleErr)
					end
					push(p)
				end
				Ranked.seasonEnded:Fire(ended)
				task.spawn(tryArchive, ended, true)
			end
		end
	end)
end

return Ranked
