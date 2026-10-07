-- CITY GRIND: crew battles (section 62). Server side.
--
-- A crew Leader / Officer challenges another crew to a format (Basketball,
-- Racing, Running, Treasure Hunt, City Challenge + metric). A Leader / Officer
-- of the other crew accepts within 2 minutes (on any server: challenges, accepts,
-- scores and results travel over MessagingService, best effort; without it
-- battles work between crews on this server). After a 30 s countdown the
-- battle window runs; every server scores its own online members of both
-- crews from real activity (see CrewBattlesConfig descriptions) and shares its
-- totals every 10 s. The challenger's server ("host") finalizes: Elo-like
-- crew rating change (start 1000, K 32) in DataStore "CityGrind_CrewRating_v1"
-- (each battle id applied once per crew), Leaderboards.submitCrew, weekly
-- City Crew Cup points (OrderedDataStore "CityGrind_CrewCup_v1_W<week>"), and
-- rewards for members who took part. Last week's top 3 cup crews' members who
-- battled for them that week collect a cup reward on their next visit.
--
-- Remotes: CrewBattleRequest (RemoteFunction): (action, args) -> { ok, msg }
--            actions "Challenge" {target, format, metric?}, "Accept" id, "Decline" id, "Cancel" id
--          CrewBattleGet (RemoteFunction): () -> snapshot for the phone app
--          CrewBattleEvent (RemoteEvent, server -> client): ("changed") ("live", chip | nil) ("result", card)
-- Player attribute: CrewBattle (battle id while their crew is in a countdown / live battle, else nil)
-- Saved section "crewBattles" = { played, wins, mvps, cupWeeks = { ["<week>"] = crewId }, cupClaimed, rewardDay, rewardCount }

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local CB = require(shared:WaitForChild("CrewBattlesConfig"))

local CrewBattles = {}

local SERVER_ID = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
local TOPIC = "CityGrindCrewBattles"
local IS_STUDIO = RunService:IsStudio()

local CrewBattleRequest = Net.remote("RemoteFunction", "CrewBattleRequest")
local CrewBattleGet = Net.remote("RemoteFunction", "CrewBattleGet")
local CrewBattleEvent = Net.remote("RemoteEvent", "CrewBattleEvent")

PlayerData.registerSection("crewBattles", function()
	return { played = 0, wins = 0, mvps = 0, cupWeeks = {}, cupClaimed = -1, rewardDay = 0, rewardCount = 0 }
end)

local function now(): number
	return os.time()
end

local function optional(name: string): any
	local m = script.Parent:FindFirstChild(name)
	if not m then
		return nil
	end
	local ok, mod = pcall(require, m)
	return if ok then mod else nil
end

---------------------------------------------------------------------------
-- Crew helpers
---------------------------------------------------------------------------
type Side = { id: string, name: string, tag: string, color: Color3 }

local function crewOf(player: Player): any
	local Crews = optional("Crews")
	if not Crews or type(Crews.crewOf) ~= "function" then
		return nil
	end
	local ok, c = pcall(Crews.crewOf, player)
	return if ok and type(c) == "table" then c else nil
end

local function isOfficer(c: any): boolean
	return c ~= nil and (c.role == "Leader" or c.role == "Officer")
end

local function membersHere(crewId: string): { Player }
	local list = {}
	for _, p in Players:GetPlayers() do
		if p:GetAttribute("CrewId") == crewId then
			table.insert(list, p)
		end
	end
	return list
end

local crewNames: { [string]: string } = {}

---------------------------------------------------------------------------
-- DataStores (ratings, weekly cup)
---------------------------------------------------------------------------
local storesOk = true
local ratingStore: DataStore? = nil
local cupStores: { [number]: OrderedDataStore } = {}

local function noteFailure(err: any)
	local msg = tostring(err)
	if IS_STUDIO or msg:find("403") or msg:find("API") or msg:find("Studio") then
		if storesOk then
			warn("[CityGrind] CrewBattles: DataStores unavailable, ratings and the cup are kept for this server only.", msg)
		end
		storesOk = false
	end
end

do
	local ok, err = pcall(function()
		ratingStore = DataStoreService:GetDataStore("CityGrind_CrewRating_v1")
	end)
	if not ok then
		noteFailure(err)
	end
end

local function budget(kind: Enum.DataStoreRequestType): boolean
	local ok, n = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(kind)
	end)
	return ok and n > 4
end

local function cupStore(week: number): OrderedDataStore?
	if not storesOk then
		return nil
	end
	if cupStores[week] then
		return cupStores[week]
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore("CityGrind_CrewCup_v1_W" .. week)
	end)
	if not ok then
		noteFailure(result)
		return nil
	end
	cupStores[week] = result
	return result
end

type RatingRec = { rating: number, wins: number, losses: number, draws: number, name: string?, vs: { any }? }
local ratings: { [string]: RatingRec } = {}
local ratingLoading: { [string]: boolean } = {}
local cupMem: { [number]: { [string]: number } } = {} -- week -> crewId -> points (this server's view / fallback)

local function blankRating(): RatingRec
	return { rating = CB.START_RATING, wins = 0, losses = 0, draws = 0 }
end

local function submitCrew(crewId: string, rec: RatingRec)
	local LB = optional("Leaderboards")
	if LB and type(LB.submitCrew) == "function" then
		pcall(LB.submitCrew, crewId, crewNames[crewId] or rec.name or "Crew", rec.rating)
	end
end

local function loadRating(crewId: string, fresh: boolean?): RatingRec
	if ratings[crewId] and not fresh then
		return ratings[crewId]
	end
	if ratingStore and storesOk and budget(Enum.DataStoreRequestType.GetAsync) then
		local ok, result = pcall(function()
			return (ratingStore :: DataStore):GetAsync("crew_" .. crewId)
		end)
		if ok then
			local rec = blankRating()
			if type(result) == "table" then
				rec.rating = tonumber(result.rating) or CB.START_RATING
				rec.wins = tonumber(result.wins) or 0
				rec.losses = tonumber(result.losses) or 0
				rec.draws = tonumber(result.draws) or 0
				rec.name = if type(result.name) == "string" then result.name else nil
				rec.vs = if type(result.vs) == "table" then result.vs else nil
				if rec.name and not crewNames[crewId] then
					crewNames[crewId] = rec.name
				end
			end
			ratings[crewId] = rec
			return rec
		end
		noteFailure(result)
	end
	ratings[crewId] = ratings[crewId] or blankRating()
	return ratings[crewId]
end

-- Public: a crew's rating (cached; loads in the background the first time).
function CrewBattles.ratingOf(crewId: string): number
	if type(crewId) ~= "string" or crewId == "" then
		return CB.START_RATING
	end
	local rec = ratings[crewId]
	if rec then
		return rec.rating
	end
	if not ratingLoading[crewId] then
		ratingLoading[crewId] = true
		task.spawn(function()
			local r = loadRating(crewId)
			ratingLoading[crewId] = nil
			submitCrew(crewId, r)
		end)
	end
	return CB.START_RATING
end

-- Applies one battle's result to a crew record once (battle id remembered). Returns the new record.
local function applyResult(crewId: string, battleId: string, delta: number, outcome: string, opponentId: string): (RatingRec, boolean)
	local applied = false
	local function bump(rec: any)
		rec.rating = math.max(100, math.floor((tonumber(rec.rating) or CB.START_RATING) + delta + 0.5))
		if outcome == "win" then
			rec.wins = (tonumber(rec.wins) or 0) + 1
		elseif outcome == "loss" then
			rec.losses = (tonumber(rec.losses) or 0) + 1
		else
			rec.draws = (tonumber(rec.draws) or 0) + 1
		end
	end
	if ratingStore and storesOk then
		local ok, result = pcall(function()
			return (ratingStore :: DataStore):UpdateAsync("crew_" .. crewId, function(old)
				local rec = if type(old) == "table" then old else { rating = CB.START_RATING, wins = 0, losses = 0, draws = 0 }
				rec.applied = if type(rec.applied) == "table" then rec.applied else {}
				if table.find(rec.applied, battleId) then
					applied = false
					return nil -- another server already applied this battle
				end
				applied = true
				bump(rec)
				rec.name = crewNames[crewId] or rec.name
				table.insert(rec.applied, battleId)
				while #rec.applied > 30 do
					table.remove(rec.applied, 1)
				end
				-- rated battles of the last 24 h by opponent (anti-farming pair limit)
				local vs = {}
				if type(rec.vs) == "table" then
					for _, e in rec.vs do
						if type(e) == "table" and type(e.t) == "number" and os.time() - e.t < 86400 then
							table.insert(vs, e)
						end
					end
				end
				table.insert(vs, { o = opponentId, t = os.time() })
				while #vs > 40 do
					table.remove(vs, 1)
				end
				rec.vs = vs
				return rec
			end)
		end)
		if ok then
			if type(result) == "table" then
				local rec = blankRating()
				rec.rating = tonumber(result.rating) or CB.START_RATING
				rec.wins = tonumber(result.wins) or 0
				rec.losses = tonumber(result.losses) or 0
				rec.draws = tonumber(result.draws) or 0
				rec.name = result.name
				rec.vs = if type(result.vs) == "table" then result.vs else nil
				ratings[crewId] = rec
			end
			return ratings[crewId] or blankRating(), applied
		end
		noteFailure(result)
	end
	-- in memory (Studio / DataStore down)
	local rec = ratings[crewId] or blankRating()
	ratings[crewId] = rec
	bump(rec)
	return rec, true
end

local function addCupPoints(crewId: string, points: number)
	if points <= 0 then
		return
	end
	local week = CB.week(now())
	cupMem[week] = cupMem[week] or {}
	cupMem[week][crewId] = (cupMem[week][crewId] or 0) + points
	local store = cupStore(week)
	if store then
		local ok, err = pcall(function()
			(store :: OrderedDataStore):IncrementAsync(crewId, points)
		end)
		if not ok then
			noteFailure(err)
		end
	end
end

-- Cup standings cache: week -> { {id, points} } (best first)
local cupTop: { [number]: { { id: string, points: number } } } = {}
local cupReadAt: { [number]: number } = {}
local cupFromStore: { [number]: boolean } = {}

-- Returns the standings and whether they came from the DataStore (false = this server's view only).
local function readCup(week: number, count: number): ({ { id: string, points: number } }, boolean)
	if os.clock() - (cupReadAt[week] or -math.huge) < 120 and cupTop[week] then
		return cupTop[week], cupFromStore[week] == true
	end
	local list = nil
	local fromStore = false
	local store = cupStore(week)
	if store and budget(Enum.DataStoreRequestType.GetSortedAsync) then
		local ok, page = pcall(function()
			return (store :: OrderedDataStore):GetSortedAsync(false, count, 1):GetCurrentPage()
		end)
		if ok then
			list = {}
			fromStore = true
			for _, item in page do
				table.insert(list, { id = tostring(item.key), points = tonumber(item.value) or 0 })
			end
		else
			noteFailure(page)
		end
	end
	if not list then
		list = {}
		local mem: { [string]: number } = cupMem[week] or {}
		for id, pts in mem do
			table.insert(list, { id = id, points = pts })
		end
		table.sort(list, function(a, b)
			return a.points > b.points
		end)
	end
	-- merge this server's freshest view (the store may lag)
	local byId = {}
	for _, e in list do
		byId[e.id] = e
	end
	local memNow: { [string]: number } = cupMem[week] or {}
	for id, pts in memNow do
		if not byId[id] then
			byId[id] = { id = id, points = pts }
			table.insert(list, byId[id])
		elseif byId[id].points < pts then
			byId[id].points = pts
		end
	end
	table.sort(list, function(a, b)
		return a.points > b.points
	end)
	cupTop[week] = list
	cupFromStore[week] = fromStore
	-- a failed read is retried sooner than a good one
	cupReadAt[week] = if fromStore or not storesOk then os.clock() else os.clock() - 90
	-- names for crews we haven't seen
	for i, e in list do
		if i > count then
			break
		end
		if not crewNames[e.id] then
			loadRating(e.id)
		end
	end
	return list, fromStore
end

---------------------------------------------------------------------------
-- Battles
---------------------------------------------------------------------------
type Top = { u: number, n: string, c: string, v: number }
type Battle = {
	id: string,
	format: string,
	metric: string?,
	a: Side,
	b: Side,
	by: string,
	host: string,
	state: string, -- pending | countdown | live | ending | done
	createdAt: number,
	acceptBy: number,
	startsAt: number?,
	endsAt: number?,
	scores: { [string]: { [string]: number } }, -- crewId -> serverId -> score
	tops: { [string]: Top }, -- serverId -> best local contributor
	contrib: { [number]: { name: string, crewId: string, score: number } }, -- this server's players
	lastSent: string,
	sentFinal: boolean,
	result: any?,
	rewarded: { [number]: boolean },
	doneAt: number?,
	finalizing: boolean?,
}

local battles: { [string]: Battle } = {}
local history: { any } = {} -- recent results (newest first)
local raceLog: { [string]: { { crewId: string, place: number, userId: number, at: number } } } = {}

local function isActive(b: Battle): boolean
	return b.state == "pending" or b.state == "countdown" or b.state == "live" or b.state == "ending"
end

local function activeBattleOf(crewId: string): Battle?
	for _, b in battles do
		if isActive(b) and (b.a.id == crewId or b.b.id == crewId) then
			return b
		end
	end
	return nil
end

local function liveBattleOf(crewId: string): Battle?
	local b = activeBattleOf(crewId)
	if b and b.state == "live" then
		return b
	end
	return nil
end

local function total(b: Battle, crewId: string): number
	local sum = 0
	local per: { [string]: number } = b.scores[crewId] or {}
	for _, v in per do
		sum += v
	end
	return sum
end

local function otherSide(b: Battle, crewId: string): Side
	return if b.a.id == crewId then b.b else b.a
end

local function audience(b: Battle): { Player }
	local list = membersHere(b.a.id)
	for _, p in membersHere(b.b.id) do
		table.insert(list, p)
	end
	return list
end

local function notifyCrew(crewId: string, title: string, body: string)
	for _, p in membersHere(crewId) do
		Net.notify(p, title, body)
	end
end

local function changed(b: Battle?)
	local list = if b then audience(b) else Players:GetPlayers()
	for _, p in list do
		CrewBattleEvent:FireClient(p, "changed")
	end
end

local function publish(msg: any)
	msg.s = SERVER_ID
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(TOPIC, msg)
		end)
		if not ok and not IS_STUDIO then
			warn("[CityGrind] CrewBattles publish failed:", err)
		end
	end)
end

local function sideMsg(s: Side): any
	return { id = s.id, n = s.name, t = s.tag, c = s.color:ToHex() }
end

local function sideFrom(m: any): Side?
	if type(m) ~= "table" or type(m.id) ~= "string" or type(m.n) ~= "string" then
		return nil
	end
	local ok, color = pcall(Color3.fromHex, tostring(m.c))
	return { id = m.id, name = m.n, tag = if type(m.t) == "string" then m.t else "", color = if ok then color else Color3.fromRGB(200, 100, 255) }
end

local function newBattle(id: string, format: string, metric: string?, a: Side, b: Side, by: string, host: string, acceptBy: number): Battle
	local battle: Battle = {
		id = id,
		format = format,
		metric = metric,
		a = a,
		b = b,
		by = by,
		host = host,
		state = "pending",
		createdAt = now(),
		acceptBy = acceptBy,
		startsAt = nil,
		endsAt = nil,
		scores = { [a.id] = {}, [b.id] = {} },
		tops = {},
		contrib = {},
		lastSent = "",
		sentFinal = false,
		result = nil,
		rewarded = {},
		doneAt = nil,
		finalizing = false,
	}
	crewNames[a.id] = a.name
	crewNames[b.id] = b.name
	battles[id] = battle
	return battle
end

local function setBattleAttr(b: Battle)
	local active = b.state == "countdown" or b.state == "live" or b.state == "ending"
	for _, p in audience(b) do
		p:SetAttribute("CrewBattle", if active then b.id else nil)
	end
end

local function accepted(b: Battle, startsAt: number)
	if b.state == "pending" then
		b.state = "countdown"
		b.startsAt = startsAt
		b.endsAt = startsAt + CB.BY_ID[b.format].minutes * 60
	elseif b.state == "countdown" and b.startsAt and startsAt < b.startsAt then
		-- two officers accepted on different servers: the earliest start wins everywhere
		b.startsAt = startsAt
		b.endsAt = startsAt + CB.BY_ID[b.format].minutes * 60
	else
		return
	end
	local fmt = CB.formatName(b.format, b.metric)
	notifyCrew(b.a.id, "BATTLE ACCEPTED", string.format("%s accepted your %s battle. Starts in %d s!", b.b.name, fmt, math.max(0, startsAt - now())))
	notifyCrew(b.b.id, "CREW BATTLE ON", string.format("%s vs %s · %s starts in %d s!", b.a.name, b.b.name, fmt, math.max(0, startsAt - now())))
	setBattleAttr(b)
	changed(b)
end

---------------------------------------------------------------------------
-- Per-player tracking while their crew is live
---------------------------------------------------------------------------
type Tracker = {
	battleId: string,
	crewId: string,
	carried: number, -- score from before a rejoin
	wins: number,
	shifts: number,
	runs: number,
	best5k: number,
	caches: number,
	distance: number,
	lastPos: Vector3?,
	h2h: number, -- basketball points vs the rival crew
	buckets: number, -- basketball points anywhere
	race: number, -- racing points
	fiveK: number, -- City 5K finishes
}
local trackers: { [Player]: Tracker } = {}
local runHooked = false

local function attrNum(p: Player, name: string): number
	local v = p:GetAttribute(name)
	return if type(v) == "number" then v else 0
end

local function shiftsOf(p: Player): number
	local sum = 0
	for name, v in p:GetAttributes() do
		if type(v) == "number" and name:sub(1, 10) == "JobShifts_" then
			sum += v
		end
	end
	return sum
end

local function eventsSec(p: Player): any
	return PlayerData.section(p, "events")
end

local function runsOf(p: Player): number
	local d = PlayerData.get(p)
	return if d and type(d.runsCompleted) == "number" then d.runsCompleted else 0
end

local function newTracker(p: Player, b: Battle, crewId: string): Tracker
	local ev = eventsSec(p)
	local prev = b.contrib[p.UserId]
	return {
		battleId = b.id,
		crewId = crewId,
		carried = if prev and prev.crewId == crewId then prev.score else 0,
		wins = attrNum(p, "Wins"),
		shifts = shiftsOf(p),
		runs = runsOf(p),
		best5k = if ev and type(ev.best5k) == "number" then ev.best5k else 0,
		caches = if ev and type(ev.caches) == "number" then ev.caches else 0,
		distance = 0,
		lastPos = nil,
		h2h = 0,
		buckets = 0,
		race = 0,
		fiveK = 0,
	}
end

local function trackerFor(p: Player): (Tracker?, Battle?)
	local t = trackers[p]
	if not t then
		return nil, nil
	end
	local b = battles[t.battleId]
	if not b or b.state ~= "live" then
		return nil, nil
	end
	return t, b
end

-- The player's score in their battle from the tracker.
local function scoreOf(p: Player, t: Tracker, b: Battle): number
	local s = 0
	if b.format == "Basketball" then
		s = t.h2h + 5 * math.max(0, attrNum(p, "Wins") - t.wins)
	elseif b.format == "Racing" then
		s = t.race
	elseif b.format == "Running" then
		local five = t.fiveK
		if not runHooked then
			-- without the Events hook a new City 5K personal best is the proof of a finish
			local ev = eventsSec(p)
			local best = if ev and type(ev.best5k) == "number" then ev.best5k else 0
			if best > 0 and (t.best5k == 0 or best < t.best5k) then
				five = math.max(five, 1)
			end
		end
		s = math.floor(t.distance / 10) + 100 * math.max(0, runsOf(p) - t.runs) + 300 * five
	elseif b.format == "TreasureHunt" then
		local ev = eventsSec(p)
		local caches = if ev and type(ev.caches) == "number" then ev.caches else 0
		s = 100 * math.max(0, caches - t.caches)
	elseif b.format == "CityChallenge" then
		if b.metric == "jobs" then
			s = math.max(0, shiftsOf(p) - t.shifts)
		elseif b.metric == "distance" then
			s = math.floor(t.distance)
		elseif b.metric == "buckets" then
			s = t.buckets
		end
	end
	return t.carried + s
end

local function onFoot(p: Player): boolean
	local character = p.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 or hum.SeatPart ~= nil then
		return false
	end
	local driving = p:GetAttribute("Driving")
	if type(driving) == "string" and driving ~= "" then
		return false
	end
	return hum.FloorMaterial ~= Enum.Material.Air
end

local function trackTick(dt: number)
	for _, p in Players:GetPlayers() do
		local crewId = p:GetAttribute("CrewId")
		local b = if type(crewId) == "string" and crewId ~= "" then liveBattleOf(crewId) else nil
		local t = trackers[p]
		if not b then
			if t then
				trackers[p] = nil
			end
			continue
		end
		local battle: Battle = b
		if not t or t.battleId ~= battle.id or t.crewId ~= crewId then
			t = newTracker(p, battle, crewId :: string)
			trackers[p] = t
		end
		local tr: Tracker = t :: Tracker
		-- distance on foot (server-side positions; teleports / vehicles don't count)
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local pos = root.Position
			if tr.lastPos then
				local d = Vector3.new(pos.X - tr.lastPos.X, 0, pos.Z - tr.lastPos.Z).Magnitude
				if onFoot(p) and d < 40 * math.max(dt, 0.1) then
					tr.distance += d
				end
			end
			tr.lastPos = pos
		end
		local score = scoreOf(p, tr, battle)
		battle.contrib[p.UserId] = { name = p.DisplayName, crewId = crewId :: string, score = score }
	end
	-- local totals per battle
	for _, b in battles do
		if b.state ~= "live" and b.state ~= "ending" then
			continue
		end
		local sa, sb = 0, 0
		local best: Top? = nil
		for uid, c in b.contrib do
			if c.crewId == b.a.id then
				sa += c.score
			elseif c.crewId == b.b.id then
				sb += c.score
			end
			if c.score > 0 and (not best or c.score > best.v) then
				best = { u = uid, n = c.name, c = c.crewId, v = c.score }
			end
		end
		b.scores[b.a.id][SERVER_ID] = sa
		b.scores[b.b.id][SERVER_ID] = sb
		b.tops[SERVER_ID] = best :: any
	end
end

-- Basketball: points vs the rival crew on the same court, and buckets anywhere.
local function onScored(_ball: any, _hoop: any, shot: any)
	if type(shot) ~= "table" or typeof(shot.shooter) ~= "Instance" or not shot.shooter:IsA("Player") then
		return
	end
	local p: Player = shot.shooter
	local pts = tonumber(shot.points) or 0
	if pts <= 0 then
		return
	end
	local t, b = trackerFor(p)
	if not t or not b then
		return
	end
	t.buckets += pts
	if b.format == "Basketball" then
		local CourtGames = optional("CourtGames")
		if not CourtGames or type(CourtGames.gameOf) ~= "function" then
			return
		end
		local ok, court = pcall(CourtGames.gameOf, p)
		if not ok or not court then
			return
		end
		local rival = otherSide(b, t.crewId)
		for _, q in membersHere(rival.id) do
			local ok2, c2 = pcall(CourtGames.gameOf, q)
			if ok2 and c2 == court then
				t.h2h += pts
				return
			end
		end
	end
end

local function onRaceFinished(p: any, place: any, _time: any, kind: any, raceId: any)
	-- solo time trials always report place 1: they don't count
	if kind == "trial" or typeof(p) ~= "Instance" or not p:IsA("Player") or type(place) ~= "number" then
		return
	end
	local t, b = trackerFor(p)
	if not t or not b or b.format ~= "Racing" then
		return
	end
	t.race += if place == 1 then 10 elseif place == 2 then 7 elseif place == 3 then 5 else 3
	local key = tostring(raceId)
	local log = raceLog[key]
	if not log then
		log = {}
		raceLog[key] = log
	end
	local rival = otherSide(b, t.crewId).id
	for _, e in log do
		if e.crewId == rival then
			if place < e.place then
				t.race += 2
			else
				local q = Players:GetPlayerByUserId(e.userId)
				local qt = q and trackers[q]
				if qt and qt.battleId == b.id then
					qt.race += 2
				end
			end
		end
	end
	table.insert(log, { crewId = t.crewId, place = place, userId = p.UserId, at = os.clock() })
end

local function onRunFinished(p: any)
	if typeof(p) ~= "Instance" or not p:IsA("Player") then
		return
	end
	local t, b = trackerFor(p)
	if t and b and b.format == "Running" then
		t.fiveK += 1
	end
end

local hooked = { basketball = false, racing = false }
local function hookSignals()
	if not hooked.basketball then
		local Basketball = optional("Basketball")
		if Basketball and type(Basketball.scored) == "table" and type(Basketball.scored.connect) == "function" then
			hooked.basketball = true
			Basketball.scored.connect(onScored)
		end
	end
	if not hooked.racing then
		local Racing = optional("Racing")
		if Racing and typeof(Racing.raceFinished) == "Instance" and Racing.raceFinished:IsA("BindableEvent") then
			hooked.racing = true
			Racing.raceFinished.Event:Connect(onRaceFinished)
		end
	end
	if not runHooked then
		local Events = optional("Events")
		if Events and typeof(Events.runFinished) == "Instance" and Events.runFinished:IsA("BindableEvent") then
			runHooked = true
			Events.runFinished.Event:Connect(onRunFinished)
		end
	end
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------
local function sectionOf(p: Player): any
	return PlayerData.section(p, "crewBattles")
end

local function unlock(p: Player, id: string)
	local Quests = optional("Quests")
	if Quests and type(Quests.unlock) == "function" then
		pcall(Quests.unlock, p, id)
	end
end

local function give(p: Player, reward: any, label: string)
	if reward.cash and reward.cash > 0 then
		PlayerData.addCash(p, reward.cash, label)
	end
	if reward.xp and reward.xp > 0 then
		PlayerData.addXP(p, reward.xp)
	end
	if reward.rep and reward.rep > 0 then
		PlayerData.addReputation(p, reward.rep)
	end
end

local function rewardText(reward: any): string
	local parts = {}
	if reward.cash and reward.cash > 0 then
		table.insert(parts, "$" .. reward.cash)
	end
	if reward.xp and reward.xp > 0 then
		table.insert(parts, reward.xp .. " XP")
	end
	if reward.rep and reward.rep > 0 then
		table.insert(parts, reward.rep .. " rep")
	end
	return table.concat(parts, " · ")
end

-- Every server runs this once per battle when the result is known.
local function handleResult(b: Battle, r: any)
	if b.state == "done" then
		return
	end
	b.state = "done"
	b.result = r
	b.doneAt = now()
	setBattleAttr(b)
	for p, t in trackers do
		if t.battleId == b.id then
			trackers[p] = nil
		end
	end
	table.insert(history, 1, r)
	while #history > 15 do
		table.remove(history)
	end
	local Crews = optional("Crews")
	local week = CB.week(r.at or now())
	for _, p in audience(b) do
		local crewId = p:GetAttribute("CrewId") :: string
		local mine = b.contrib[p.UserId]
		-- only members who actually scored for this crew take part (no AFK rewards, no carried
		-- score from the rival crew after switching sides)
		local took = mine ~= nil and mine.crewId == crewId and mine.score > 0
		local outcome = if r.winner == nil then (if r.noContest then "none" else "draw") elseif r.winner == crewId then "win" else "loss"
		local rated = outcome ~= "none" and r.unrated == nil
		local reward = nil
		local note: string? = nil
		if r.unrated == "uncontested" then
			note = "Uncontested (one crew scored nothing): unrated, no rewards."
		elseif r.unrated == "repeat" then
			note = "These crews already battled today: unrated, no rewards."
		end
		if took and not b.rewarded[p.UserId] then
			b.rewarded[p.UserId] = true
			local sec = sectionOf(p)
			if rated and sec then
				if outcome == "win" then
					reward = CB.WIN_REWARD
				elseif outcome == "draw" then
					reward = CB.DRAW_REWARD
				elseif outcome == "loss" then
					reward = CB.LOSS_REWARD
				end
				-- daily cap on paid battles per player
				local day = math.floor(now() / 86400)
				if sec.rewardDay ~= day then
					sec.rewardDay = day
					sec.rewardCount = 0
				end
				if reward and (tonumber(sec.rewardCount) or 0) >= CB.DAILY_REWARDED_BATTLES then
					reward = nil
					note = "Daily crew battle reward limit reached."
				elseif reward then
					sec.rewardCount = (tonumber(sec.rewardCount) or 0) + 1
				end
				sec.played += 1
				if outcome == "win" then
					sec.wins += 1
				end
				if r.mvp and r.mvp.u == p.UserId then
					sec.mvps += 1
				end
				-- cup eligibility: battled for this crew this week
				sec.cupWeeks[tostring(week)] = crewId
				local keys = {}
				for k in sec.cupWeeks do
					table.insert(keys, tonumber(k) or 0)
				end
				table.sort(keys)
				while #keys > 3 do
					sec.cupWeeks[tostring(table.remove(keys, 1))] = nil
				end
				PlayerData.markChanged(p)
			end
			if reward then
				give(p, reward, "Crew battle vs " .. otherSide(b, crewId).name)
				if Crews and type(Crews.addCrewRep) == "function" and reward.crewRep > 0 then
					pcall(Crews.addCrewRep, p, reward.crewRep)
				end
			end
			if rated then
				if outcome == "win" then
					unlock(p, "crew_battle_win")
					if sec and sec.wins >= 10 then
						unlock(p, "crew_battle_10")
					end
				end
				if r.mvp and r.mvp.u == p.UserId then
					unlock(p, "crew_battle_mvp")
				end
			end
		end
		local mySide = if r.a.id == crewId then r.a else r.b
		local theirSide = if r.a.id == crewId then r.b else r.a
		CrewBattleEvent:FireClient(p, "result", {
			id = r.id,
			formatName = r.formatName,
			icon = r.icon,
			unit = r.unit,
			outcome = outcome,
			mine = { name = mySide.name, tag = mySide.tag, score = mySide.score, delta = mySide.delta, rating = mySide.rating },
			theirs = { name = theirSide.name, tag = theirSide.tag, score = theirSide.score, delta = theirSide.delta, rating = theirSide.rating },
			mvp = r.mvp and { name = r.mvp.n, score = r.mvp.v } or nil,
			myScore = if mine then mine.score else 0,
			reward = if reward then rewardText(reward) else nil,
			note = note,
		})
		local headline = if outcome == "win" then "CREW BATTLE WON!" elseif outcome == "loss" then "CREW BATTLE LOST" elseif outcome == "draw" then "CREW BATTLE DRAW" else "CREW BATTLE OVER"
		Net.notify(p, headline, string.format("%s %d – %d %s · %s", mySide.name, mySide.score, theirSide.score, theirSide.name, r.formatName))
		CrewBattleEvent:FireClient(p, "live", nil)
	end
	changed(nil)
end

-- Rated battles between two crews in the last 24 h (saved records + this server's memory).
local pairMem: { [string]: { number } } = {}

local function pairKey(x: string, y: string): string
	return if x < y then x .. "|" .. y else y .. "|" .. x
end

local function recentVs(rec: RatingRec?, opponentId: string): number
	local n = 0
	if rec and type(rec.vs) == "table" then
		for _, e in rec.vs do
			if type(e) == "table" and e.o == opponentId and type(e.t) == "number" and os.time() - e.t < 86400 then
				n += 1
			end
		end
	end
	return n
end

local function pairCount(aId: string, bId: string, recA: RatingRec?, recB: RatingRec?): number
	local mem = 0
	local times: { number } = pairMem[pairKey(aId, bId)] or {}
	for _, t in times do
		if os.time() - t < 86400 then
			mem += 1
		end
	end
	return math.max(mem, recentVs(recA, bId), recentVs(recB, aId))
end

-- Host (or fallback) decides the result and applies ratings / cup once.
local function finalize(b: Battle)
	if b.state == "done" or b.finalizing then
		return
	end
	b.finalizing = true
	task.spawn(function()
		local ok, err = pcall(function()
			local sa, sb = total(b, b.a.id), total(b, b.b.id)
			local winner: string? = if sa > sb then b.a.id elseif sb > sa then b.b.id else nil
			local noContest = sa == 0 and sb == 0
			local loadedA = loadRating(b.a.id, true)
			local loadedB = loadRating(b.b.id, true)
			local ra, rb = loadedA.rating, loadedB.rating
			local da, db = 0, 0
			local recA, recB = ratings[b.a.id] or blankRating(), ratings[b.b.id] or blankRating()
			-- anti-farming: a battle one side never played, or one pair of crews battling over
			-- and over (alt crews), changes no rating, gives no cup points and pays no rewards
			local unrated: string? = nil
			if not noContest and (sa == 0 or sb == 0) then
				unrated = "uncontested"
			elseif not noContest and pairCount(b.a.id, b.b.id, loadedA, loadedB) >= CB.PAIR_RATED_PER_DAY then
				unrated = "repeat"
			end
			if not noContest and not unrated then
				local pk = pairKey(b.a.id, b.b.id)
				pairMem[pk] = pairMem[pk] or {}
				table.insert(pairMem[pk], os.time())
				local scoreA = if winner == b.a.id then 1 elseif winner == nil then 0.5 else 0
				local ea = CB.expected(ra, rb)
				da = math.floor(CB.K * (scoreA - ea) + 0.5)
				db = -da
				local okA
				recA, okA = applyResult(b.a.id, b.id, da, if scoreA == 1 then "win" elseif scoreA == 0 then "loss" else "draw", b.b.id)
				local okB
				recB, okB = applyResult(b.b.id, b.id, db, if scoreA == 0 then "win" elseif scoreA == 1 then "loss" else "draw", b.a.id)
				if okA then
					addCupPoints(b.a.id, if scoreA == 1 then CB.CUP_POINTS.win elseif scoreA == 0.5 then CB.CUP_POINTS.draw else 0)
				end
				if okB then
					addCupPoints(b.b.id, if scoreA == 0 then CB.CUP_POINTS.win elseif scoreA == 0.5 then CB.CUP_POINTS.draw else 0)
				end
				submitCrew(b.a.id, recA)
				submitCrew(b.b.id, recB)
			end
			local mvp: Top? = nil
			for _, t in b.tops do
				if t and (not mvp or t.v > mvp.v) then
					mvp = t
				end
			end
			local f = CB.BY_ID[b.format]
			local r = {
				id = b.id,
				format = b.format,
				formatName = CB.formatName(b.format, b.metric),
				icon = f.icon,
				unit = CB.unit(b.format, b.metric),
				at = now(),
				winner = winner,
				noContest = noContest,
				unrated = unrated,
				a = { id = b.a.id, name = b.a.name, tag = b.a.tag, score = sa, delta = da, rating = recA.rating },
				b = { id = b.b.id, name = b.b.name, tag = b.b.tag, score = sb, delta = db, rating = recB.rating },
				mvp = mvp,
			}
			publish({ t = "rs", id = b.id, r = r })
			b.finalizing = false
			handleResult(b, r)
		end)
		if not ok then
			-- never leave the crews stuck in an "ending" battle
			warn("[CityGrind] CrewBattles finalize failed:", err)
			b.finalizing = false
			if b.state ~= "done" then
				b.state = "done"
				b.doneAt = now()
				setBattleAttr(b)
				changed(nil)
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Cross-server messages
---------------------------------------------------------------------------
local function onMessage(packet: any)
	local msg = type(packet) == "table" and packet.Data
	if type(msg) ~= "table" or msg.s == SERVER_ID or type(msg.t) ~= "string" then
		return
	end
	local t = msg.t
	if t == "ch" then
		if type(msg.id) ~= "string" or battles[msg.id] or not CB.BY_ID[msg.f] then
			return
		end
		local a, b = sideFrom(msg.a), sideFrom(msg.b)
		if not a or not b then
			return
		end
		local battle = newBattle(msg.id, msg.f, if type(msg.m) == "string" then msg.m else nil, a, b, tostring(msg.by), msg.s, tonumber(msg.acceptBy) or now() + CB.ACCEPT_SECONDS)
		local fmt = CB.formatName(battle.format, battle.metric)
		for _, p in membersHere(b.id) do
			local c = crewOf(p)
			if isOfficer(c) then
				Net.notify(p, "CREW CHALLENGE!", string.format("%s challenges your crew to %s. Accept in the Battles app (2 min).", a.name, fmt))
			end
		end
		changed(battle)
	else
		local b = type(msg.id) == "string" and battles[msg.id]
		if not b then
			return
		end
		if t == "ac" then
			accepted(b, tonumber(msg.startsAt) or now() + CB.COUNTDOWN_SECONDS)
		elseif t == "dc" then
			if b.state == "pending" then
				b.state = "done"
				b.doneAt = now()
				changed(b)
			end
		elseif t == "sc" then
			if type(msg.a) == "number" and type(msg.b) == "number" then
				b.scores[b.a.id][msg.s] = msg.a
				b.scores[b.b.id][msg.s] = msg.b
				if type(msg.top) == "table" and type(msg.top.v) == "number" then
					b.tops[msg.s] = { u = tonumber(msg.top.u) or 0, n = tostring(msg.top.n), c = tostring(msg.top.c), v = msg.top.v }
				end
			end
		elseif t == "rs" then
			if type(msg.r) == "table" and type(msg.r.a) == "table" and type(msg.r.b) == "table" then
				handleResult(b, msg.r)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------
local function targetsFor(myId: string?): { any }
	local list, seen = {}, {}
	for _, p in Players:GetPlayers() do
		local c = crewOf(p)
		if c and c.id ~= myId and not seen[c.id] then
			seen[c.id] = true
			crewNames[c.id] = c.name
			table.insert(list, { id = c.id, name = c.name, tag = c.tag, rating = CrewBattles.ratingOf(c.id), here = true, busy = activeBattleOf(c.id) ~= nil })
		end
	end
	local LB = optional("Leaderboards")
	if LB and type(LB.top) == "function" then
		local ok, top = pcall(LB.top, "crewRating", 30, "all")
		if ok and type(top) == "table" then
			for _, e in top do
				if e.key ~= myId and not seen[e.key] then
					seen[e.key] = true
					table.insert(list, { id = e.key, name = e.name, tag = "", rating = e.value, here = false, busy = activeBattleOf(e.key) ~= nil })
				end
			end
		end
	end
	return list
end

local function challenge(player: Player, args: any): (boolean, string)
	if type(args) ~= "table" or type(args.target) ~= "string" or type(args.format) ~= "string" then
		return false, "Bad request."
	end
	local f = CB.BY_ID[args.format]
	if not f then
		return false, "Pick a format."
	end
	local metric = nil
	if f.id == "CityChallenge" then
		if type(args.metric) ~= "string" or not CB.METRIC_BY_ID[args.metric] then
			return false, "Pick a city challenge metric."
		end
		metric = args.metric
	end
	local mine = crewOf(player)
	if not mine then
		return false, "You're not in a crew."
	end
	if not isOfficer(mine) then
		return false, "Only crew leaders and officers can issue challenges."
	end
	if args.target == mine.id then
		return false, "You can't battle your own crew."
	end
	if activeBattleOf(mine.id) then
		return false, "Your crew is already in a battle or has a challenge out."
	end
	if activeBattleOf(args.target) then
		return false, "That crew is busy with another battle."
	end
	-- find the target crew (this server, else the crew board)
	local target: Side? = nil
	for _, t in targetsFor(mine.id) do
		if t.id == args.target then
			local color = Color3.fromRGB(200, 100, 255)
			for _, p in membersHere(t.id) do
				local c = crewOf(p)
				if c then
					color = c.color
					break
				end
			end
			target = { id = t.id, name = t.name, tag = t.tag or "", color = color }
			break
		end
	end
	if not target then
		return false, "That crew can't be found."
	end
	if not Net.allow(player, "CrewBattleChallenge", CB.CHALLENGE_COOLDOWN) then
		return false, "Wait a minute before issuing another challenge."
	end
	local a: Side = { id = mine.id, name = mine.name, tag = mine.tag, color = mine.color }
	local id = HttpService:GenerateGUID(false):sub(1, 12)
	local b = newBattle(id, f.id, metric, a, target, player.DisplayName, SERVER_ID, now() + CB.ACCEPT_SECONDS)
	publish({ t = "ch", id = id, f = f.id, m = metric, a = sideMsg(a), b = sideMsg(target), by = player.DisplayName, acceptBy = b.acceptBy })
	local fmt = CB.formatName(f.id, metric)
	local hereOfficers = 0
	for _, p in membersHere(target.id) do
		local c = crewOf(p)
		if isOfficer(c) then
			hereOfficers += 1
			Net.notify(p, "CREW CHALLENGE!", string.format("%s challenges your crew to %s. Accept in the Battles app (2 min).", a.name, fmt))
			local Messages = optional("Messages")
			if Messages and type(Messages.sendSystem) == "function" then
				pcall(Messages.sendSystem, p, "Crew Battles", string.format("%s (%s) challenged your crew to %s. Open the Battles app on your phone to accept or decline within 2 minutes.", a.name, player.DisplayName, fmt))
			end
		end
	end
	notifyCrew(mine.id, "CHALLENGE SENT", string.format("%s challenged %s to %s.", player.DisplayName, target.name, fmt))
	changed(b)
	if hereOfficers == 0 then
		return true, "Challenge sent. Their leader or officers have 2 minutes to accept (from any server)."
	end
	return true, "Challenge sent to " .. target.name .. "."
end

local function respond(player: Player, id: any, action: string): (boolean, string)
	local b = type(id) == "string" and battles[id]
	if not b or b.state ~= "pending" then
		return false, "That challenge is no longer open."
	end
	local c = crewOf(player)
	if not isOfficer(c) then
		return false, "Only leaders and officers can do that."
	end
	if action == "Cancel" then
		if c.id ~= b.a.id then
			return false, "Only the challenging crew can cancel."
		end
		b.state = "done"
		b.doneAt = now()
		publish({ t = "dc", id = b.id })
		notifyCrew(b.a.id, "CHALLENGE CANCELLED", player.DisplayName .. " cancelled the challenge to " .. b.b.name .. ".")
		changed(b)
		return true, "Challenge cancelled."
	end
	if c.id ~= b.b.id then
		return false, "This challenge isn't for your crew."
	end
	if action == "Decline" then
		b.state = "done"
		b.doneAt = now()
		publish({ t = "dc", id = b.id })
		notifyCrew(b.a.id, "CHALLENGE DECLINED", b.b.name .. " declined your crew battle.")
		changed(b)
		return true, "Challenge declined."
	end
	-- Accept
	if now() > b.acceptBy then
		return false, "The challenge expired."
	end
	for _, other in battles do
		if other ~= b and isActive(other) and (other.a.id == c.id or other.b.id == c.id) then
			return false, "Your crew is already in another battle."
		end
	end
	local startsAt = now() + CB.COUNTDOWN_SECONDS
	publish({ t = "ac", id = b.id, startsAt = startsAt })
	accepted(b, startsAt)
	return true, "Battle accepted! Starts in " .. CB.COUNTDOWN_SECONDS .. " seconds."
end

CrewBattleRequest.OnServerInvoke = function(player: Player, action: any, args: any)
	if not Net.allow(player, "CrewBattleRequest", 0.5) then
		return { ok = false, msg = "Slow down." }
	end
	local ok, success, msg = pcall(function()
		if action == "Challenge" then
			return challenge(player, args)
		elseif action == "Accept" or action == "Decline" or action == "Cancel" then
			return respond(player, args, action)
		end
		return false, "Unknown action."
	end)
	if not ok then
		warn("[CityGrind] CrewBattleRequest failed:", success)
		return { ok = false, msg = "Something went wrong." }
	end
	return { ok = success == true, msg = msg }
end

local function battleView(b: Battle, viewer: Player, myId: string): any
	local f = CB.BY_ID[b.format]
	local c = crewOf(viewer)
	local top = {}
	for _, ct in b.contrib do
		if ct.score > 0 then
			table.insert(top, { name = ct.name, score = ct.score, mine = ct.crewId == myId })
		end
	end
	table.sort(top, function(x, y)
		return x.score > y.score
	end)
	while #top > 6 do
		table.remove(top)
	end
	local me = b.contrib[viewer.UserId]
	return {
		id = b.id,
		format = b.format,
		formatName = CB.formatName(b.format, b.metric),
		desc = if b.format == "CityChallenge" and b.metric then CB.METRIC_BY_ID[b.metric].desc else f.desc,
		icon = f.icon,
		unit = CB.unit(b.format, b.metric),
		state = b.state,
		by = b.by,
		a = { id = b.a.id, name = b.a.name, tag = b.a.tag, color = b.a.color, score = total(b, b.a.id) },
		b = { id = b.b.id, name = b.b.name, tag = b.b.tag, color = b.b.color, score = total(b, b.b.id) },
		mineIsA = b.a.id == myId,
		acceptBy = b.acceptBy,
		startsAt = b.startsAt,
		endsAt = b.endsAt,
		canAccept = b.state == "pending" and b.b.id == myId and isOfficer(c),
		canCancel = b.state == "pending" and b.a.id == myId and isOfficer(c),
		top = top,
		myScore = if me then me.score else 0,
	}
end

CrewBattleGet.OnServerInvoke = function(player: Player)
	if not Net.allow(player, "CrewBattleGet", 0.3) then
		return nil
	end
	local c = crewOf(player)
	local week = CB.week(now())
	local snapshot: any = {
		serverNow = now(),
		global = storesOk,
		formats = nil,
	}
	if c then
		local rec = ratings[c.id] or loadRating(c.id)
		snapshot.crew = {
			id = c.id,
			name = c.name,
			tag = c.tag,
			role = c.role,
			canChallenge = isOfficer(c),
			rating = rec.rating,
			wins = rec.wins,
			losses = rec.losses,
			draws = rec.draws,
		}
		local b = activeBattleOf(c.id)
		if b then
			snapshot.battle = battleView(b, player, c.id)
		end
		snapshot.targets = targetsFor(c.id)
	end
	-- weekly cup
	local standings = {}
	local myPoints = 0
	for i, e in (readCup(week, 10)) do
		if c and e.id == c.id then
			myPoints = e.points
		end
		if i <= 10 then
			table.insert(standings, { name = crewNames[e.id] or "Crew", points = e.points, mine = c ~= nil and e.id == c.id })
		end
	end
	local last = {}
	for i, e in (readCup(week - 1, 3)) do
		if i > 3 then
			break
		end
		table.insert(last, { name = crewNames[e.id] or "Crew", points = e.points })
	end
	snapshot.cup = { week = week, endsAt = CB.weekEnds(week), standings = standings, myPoints = myPoints, lastWeek = last }
	local hist = {}
	for i, r in history do
		if i > 10 then
			break
		end
		table.insert(hist, {
			formatName = r.formatName,
			icon = r.icon,
			a = { name = r.a.name, score = r.a.score },
			b = { name = r.b.name, score = r.b.score },
			winner = if r.winner == r.a.id then r.a.name elseif r.winner == r.b.id then r.b.name else nil,
			noContest = r.noContest,
			at = r.at,
		})
	end
	snapshot.history = hist
	local sec = sectionOf(player)
	snapshot.me = sec and { played = sec.played, wins = sec.wins, mvps = sec.mvps } or nil
	return snapshot
end

---------------------------------------------------------------------------
-- Weekly City Crew Cup rewards (collected on the next visit after the week ends)
---------------------------------------------------------------------------
local function claimCup(p: Player)
	local sec = sectionOf(p)
	if not sec then
		return
	end
	local lastWeek = CB.week(now()) - 1
	if sec.cupClaimed >= lastWeek then
		return
	end
	local crewId = sec.cupWeeks[tostring(lastWeek)]
	if type(crewId) ~= "string" then
		return
	end
	local top, fromStore = readCup(lastWeek, 3)
	if #top == 0 or (storesOk and not fromStore) then
		return -- global standings not readable right now (this server's view isn't enough); try again later
	end
	for place, e in top do
		if place > 3 then
			break
		end
		if e.id == crewId and e.points > 0 then
			sec.cupClaimed = lastWeek
			PlayerData.markChanged(p)
			local reward = CB.CUP_REWARDS[place]
			give(p, reward, "City Crew Cup #" .. place)
			Net.notify(p, if place == 1 then "CITY CREW CUP CHAMPIONS!" else "CITY CREW CUP PODIUM", string.format("%s finished #%d in last week's City Crew Cup. %s", crewNames[crewId] or "Your crew", place, rewardText(reward)))
			if place == 1 then
				unlock(p, "crew_cup_champion")
			end
			return
		end
	end
	-- not on the podium: nothing to claim for that week
	sec.cupClaimed = lastWeek
	PlayerData.markChanged(p)
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
local function chipFor(b: Battle, p: Player): any
	local myId = p:GetAttribute("CrewId")
	local mine = if b.a.id == myId then b.a else b.b
	local theirs = if b.a.id == myId then b.b else b.a
	local me = b.contrib[p.UserId]
	return {
		id = b.id,
		state = b.state,
		icon = CB.BY_ID[b.format].icon,
		formatName = CB.formatName(b.format, b.metric),
		unit = CB.unit(b.format, b.metric),
		mine = { tag = mine.tag, name = mine.name, color = mine.color, score = total(b, mine.id) },
		theirs = { tag = theirs.tag, name = theirs.name, color = theirs.color, score = total(b, theirs.id) },
		startsAt = b.startsAt,
		endsAt = b.endsAt,
		myScore = if me then me.score else 0,
		serverNow = now(),
	}
end

local function step(dt: number)
	local t = now()
	for id, b in battles do
		if b.state == "pending" and t > b.acceptBy then
			b.state = "done"
			b.doneAt = t
			if b.host == SERVER_ID then
				notifyCrew(b.a.id, "CHALLENGE EXPIRED", b.b.name .. " didn't answer your crew battle challenge.")
			end
			changed(b)
		elseif b.state == "countdown" and b.startsAt and t >= b.startsAt then
			b.state = "live"
			notifyCrew(b.a.id, "BATTLE STARTED!", CB.formatName(b.format, b.metric) .. " vs " .. b.b.name .. ". Go!")
			notifyCrew(b.b.id, "BATTLE STARTED!", CB.formatName(b.format, b.metric) .. " vs " .. b.a.name .. ". Go!")
			setBattleAttr(b)
			changed(b)
		elseif b.state == "live" and b.endsAt and t >= b.endsAt then
			b.state = "ending"
			changed(b)
		elseif b.state == "done" and b.doneAt and t - b.doneAt > 600 then
			battles[id] = nil
		end
	end
	trackTick(dt)
	for _, b in battles do
		if b.state == "ending" and b.endsAt then
			-- the host finalizes; another server only does if the host went quiet
			-- (a battle id is applied to a crew's rating once either way)
			local grace = if b.host == SERVER_ID then CB.FINALIZE_GRACE else 90
			if t >= b.endsAt + grace then
				if b.host ~= SERVER_ID and next(b.contrib) == nil and #audience(b) == 0 then
					-- an uninvolved server that missed the host's result: just forget the battle
					-- (finalizing here too would only spend DataStore budget on every server)
					b.state = "done"
					b.doneAt = t
				else
					finalize(b)
				end
			end
		end
	end
end

local function broadcastScores()
	for _, b in battles do
		if (b.state == "live" or b.state == "ending") and b.host ~= nil then
			if b.state == "ending" and b.sentFinal then
				continue
			end
			local sa = b.scores[b.a.id][SERVER_ID] or 0
			local sb = b.scores[b.b.id][SERVER_ID] or 0
			local key = sa .. "|" .. sb
			if key ~= b.lastSent or b.state == "ending" then
				b.lastSent = key
				if b.state == "ending" then
					b.sentFinal = true
				end
				-- only servers with something to report (every server knows every battle; a
				-- message from each would flood the topic's per-minute receive limit)
				if #membersHere(b.a.id) + #membersHere(b.b.id) > 0 or next(b.contrib) ~= nil then
					local top = b.tops[SERVER_ID]
					publish({ t = "sc", id = b.id, a = sa, b = sb, top = top })
				end
			end
		end
	end
end

function CrewBattles.start(_city: Instance?)
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(TOPIC, onMessage)
		end)
		if not ok and not IS_STUDIO then
			warn("[CityGrind] CrewBattles: cross-server battles unavailable:", err)
		end
	end)

	PlayerData.onLoaded(function(p)
		task.wait(5)
		if p.Parent then
			claimCup(p)
			local id = p:GetAttribute("CrewId")
			if type(id) == "string" and id ~= "" then
				CrewBattles.ratingOf(id)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(p)
		trackers[p] = nil
	end)

	-- main loop: state changes, tracking, chips
	task.spawn(function()
		local last = os.clock()
		local ticks = 0
		while true do
			task.wait(1)
			local dt = os.clock() - last
			last = os.clock()
			ticks += 1
			hookSignals()
			local ok, err = pcall(step, dt)
			if not ok then
				warn("[CityGrind] CrewBattles step failed:", err)
			end
			if ticks % 2 == 0 then
				-- clear stale battle attributes (left the crew, battle over)
				for _, p in Players:GetPlayers() do
					local bid = p:GetAttribute("CrewBattle")
					if bid ~= nil then
						local b = battles[bid]
						local crewId = p:GetAttribute("CrewId")
						if not b or b.state == "done" or b.state == "pending" or (b.a.id ~= crewId and b.b.id ~= crewId) then
							p:SetAttribute("CrewBattle", nil)
							CrewBattleEvent:FireClient(p, "live", nil)
						end
					end
				end
				for _, b in battles do
					if b.state == "countdown" or b.state == "live" or b.state == "ending" then
						for _, p in audience(b) do
							if p:GetAttribute("CrewBattle") ~= b.id then
								p:SetAttribute("CrewBattle", b.id)
							end
							CrewBattleEvent:FireClient(p, "live", chipFor(b, p))
						end
					end
				end
			end
			if ticks % CB.SCORE_BROADCAST_SECONDS == 0 then
				pcall(broadcastScores)
			end
			if ticks % 60 == 0 then
				-- crews online here show up on the crew board; drop stale race logs
				for _, p in Players:GetPlayers() do
					local id = p:GetAttribute("CrewId")
					if type(id) == "string" and id ~= "" and ratings[id] then
						local c = crewOf(p)
						if c then
							crewNames[id] = c.name
						end
						submitCrew(id, ratings[id])
					elseif type(id) == "string" and id ~= "" then
						CrewBattles.ratingOf(id)
					end
				end
				for key, log in raceLog do
					if #log == 0 or os.clock() - log[#log].at > 900 then
						raceLog[key] = nil
					end
				end
			end
			if ticks % 300 == 0 then
				for _, p in Players:GetPlayers() do
					task.spawn(claimCup, p)
				end
			end
		end
	end)
end

return CrewBattles
