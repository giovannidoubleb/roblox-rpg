-- CITY GRIND: global leaderboards (section 98). Server side.
--
-- Boards: level, cash, reputation, fame, rating, wins, points, fastest5k,
-- fastestRace (players) and crewRating (crews). "rating", "wins" and
-- "fastestRace" also have a per-season board while Ranked runs a season.
--
-- Storage: OrderedDataStore "CityGrind_LB_<statId>_v1" (season boards add
-- "_S<season number>"), keyed by UserId (crews: crew id). Writes are queued and
-- flushed at most once per player per board every 60 s, only while the
-- DataStore request budget has room. The top 50 of every board is re-read
-- about every 2 minutes and cached; the values of players in this server are
-- merged in live. Without DataStore access (Studio) every board is built from
-- the players this server has seen.
--
-- This module reads Level / Cash / Reputation / Fame / Wins attributes, the
-- saved basketball points and the Events 5K best itself; Ranked submits
-- "rating" (the Rating attribute is also read), Racing submits "fastestRace"
-- (Racing.raceFinished / Racing.bestTime are also read when Racing exists).
--
-- Archive: Leaderboards.archive(seasonId) snapshots the top 100 of the season
-- boards into DataStore "CityGrind_LB_Archive_v1" ("season_<id>", plus an
-- "index" list the phone reads).
--
-- Remote: LeaderboardsGet (RemoteFunction): ("Meta") | ("Board", statId, scope) | ("Archive", seasonId)
-- Saved section "leaderboards" = { seasonId = "", winsBase = 0 }  (season wins = Wins - winsBase)
-- World: boards at the Neighborhood court and the City Speedway grandstand
-- (folder City.Leaderboards). The Downtown plaza board (Districts) reads Leaderboards.top.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local LC = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("LeaderboardsConfig"))
local Config = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Config"))
local EventsConfig = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("EventsConfig"))

-- [Security] The fastest physically possible City 5K: every leg cut short by the
-- gate radius at both ends, run at the event's speed cap. Anything under it is bogus.
local MIN_5K_SECONDS = (function(): number
	local run = EventsConfig.RUN
	local route = run and run.ROUTE
	if type(route) ~= "table" or #route < 2 then
		return 0
	end
	local total = 0
	for i = 1, #route do
		local a, b = route[i], route[if i == #route then 1 else i + 1]
		total += math.max(0, Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude - 2 * run.GATE_RADIUS)
	end
	return total / run.MAX_SPEED
end)()
local rejectedWarned: { [string]: boolean } = {}

local Leaderboards = {}

local IS_STUDIO = RunService:IsStudio()
local LeaderboardsGet = Net.remote("RemoteFunction", "LeaderboardsGet")

PlayerData.registerSection("leaderboards", function()
	return { seasonId = "", winsBase = 0 }
end)

type Entry = { key: string, name: string, value: number } -- value is decoded (seconds for times)

---------------------------------------------------------------------------
-- Optional modules (required lazily; they may not exist)
---------------------------------------------------------------------------
local function optional(name: string): any
	local m = script.Parent:FindFirstChild(name)
	if not m then
		return nil
	end
	local ok, mod = pcall(require, m)
	return if ok then mod else nil
end

---------------------------------------------------------------------------
-- Season (from Ranked, if it runs)
---------------------------------------------------------------------------
type Season = { id: string, number: number, name: string, startsAt: number, endsAt: number }
local seasonCache: Season? = nil
local seasonCheckedAt = -math.huge
local seasonNumbers: { [string]: number } = {}
local seasonNames: { [string]: string } = {}
local seasonEndHooked = false

local function currentSeason(): Season?
	if os.clock() - seasonCheckedAt < 20 then
		return seasonCache
	end
	seasonCheckedAt = os.clock()
	local Ranked = optional("Ranked")
	local s = nil
	if Ranked and type(Ranked.season) == "function" then
		local ok, result = pcall(Ranked.season)
		if ok and type(result) == "table" and type(result.id) == "string" and type(result.number) == "number" then
			s = result
		end
	end
	if s then
		seasonNumbers[s.id] = s.number
		seasonNames[s.id] = if type(s.name) == "string" then s.name else ("Season " .. s.number)
	end
	if Ranked and not seasonEndHooked and typeof(Ranked.seasonEnded) == "Instance" and Ranked.seasonEnded:IsA("BindableEvent") then
		seasonEndHooked = true
		-- Ranked itself calls Leaderboards.archive on exactly one server (DataStore guard);
		-- archiving here too would make every server snapshot the season at once.
		-- Just drop the cached season so new values stop landing on the ended season's boards.
		Ranked.seasonEnded.Event:Connect(function()
			seasonCheckedAt = -math.huge
		end)
	end
	seasonCache = s
	return s
end
Leaderboards.season = currentSeason

---------------------------------------------------------------------------
-- DataStores
---------------------------------------------------------------------------
local storesOk = true -- false once DataStore access turns out to be unavailable
local ordered: { [string]: OrderedDataStore } = {}
local archiveStore: DataStore? = nil
local crewNameStore: DataStore? = nil

local function boardName(statId: string, seasonNumber: number?): string
	return "CityGrind_LB_" .. statId .. "_v1" .. (if seasonNumber then "_S" .. seasonNumber else "")
end

local function statOfBoard(board: string): string
	return (board:match("^CityGrind_LB_(.-)_v1") or "")
end

local function noteFailure(err: any)
	local msg = tostring(err)
	-- Studio without "Enable Studio Access to API Services", or no published place.
	if IS_STUDIO or msg:find("403") or msg:find("API") or msg:find("Studio") then
		if storesOk then
			warn("[CityGrind] Leaderboards: DataStores unavailable, using this server's players only.", msg)
		end
		storesOk = false
	end
end

local function orderedStore(board: string): OrderedDataStore?
	if not storesOk then
		return nil
	end
	local s = ordered[board]
	if s then
		return s
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(board)
	end)
	if not ok then
		noteFailure(result)
		return nil
	end
	ordered[board] = result
	return result
end

local function budget(kind: Enum.DataStoreRequestType, reserve: number?): boolean
	local ok, n = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(kind)
	end)
	return ok and n > (reserve or LC.BUDGET_RESERVE)
end

do
	local ok, err = pcall(function()
		archiveStore = DataStoreService:GetDataStore("CityGrind_LB_Archive_v1")
		crewNameStore = DataStoreService:GetDataStore("CityGrind_LB_CrewNames_v1")
	end)
	if not ok then
		noteFailure(err)
	end
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------
local userNames: { [number]: string } = {}
local nameTried: { [number]: number } = {}
local crewNames: { [string]: string } = {}
local crewNameTried: { [string]: number } = {}
local crewNameWritten: { [string]: string } = {}

local function displayName(board: string, key: string): string
	if statOfBoard(board) == "crewRating" then
		return crewNames[key] or "Crew"
	end
	local uid = tonumber(key)
	if not uid then
		return "?"
	end
	local p = Players:GetPlayerByUserId(uid)
	if p then
		return p.DisplayName
	end
	return userNames[uid] or "Player"
end

-- Looks up names for entries we don't know yet (cached, at most once per 10 min per id).
local function resolveNames(board: string, entries: { Entry })
	local isCrew = statOfBoard(board) == "crewRating"
	local looked = 0
	for _, e in entries do
		if looked >= 60 then
			break
		end
		if isCrew then
			if not crewNames[e.key] and crewNameStore and storesOk and os.clock() - (crewNameTried[e.key] or -math.huge) > 600 then
				crewNameTried[e.key] = os.clock()
				if budget(Enum.DataStoreRequestType.GetAsync) then
					looked += 1
					local ok, result = pcall(function()
						return (crewNameStore :: DataStore):GetAsync(e.key)
					end)
					if ok and type(result) == "string" then
						crewNames[e.key] = result
					end
				end
			end
			e.name = crewNames[e.key] or e.name
		else
			local uid = tonumber(e.key)
			if uid and uid > 0 and not userNames[uid] and not Players:GetPlayerByUserId(uid) and os.clock() - (nameTried[uid] or -math.huge) > 600 then
				nameTried[uid] = os.clock()
				looked += 1
				local ok, result = pcall(function()
					return Players:GetNameFromUserIdAsync(uid)
				end)
				if ok and type(result) == "string" then
					userNames[uid] = result
				end
			end
			e.name = displayName(board, e.key)
		end
	end
end

---------------------------------------------------------------------------
-- Values: this server's known values, queued writes and the cached global tops
---------------------------------------------------------------------------
local localVals: { [string]: { [string]: Entry } } = {} -- board -> key -> entry (decoded)
local pending: { [string]: { [string]: number } } = {} -- board -> key -> encoded value
local lastWrite: { [string]: number } = {} -- board .. "|" .. key -> os.clock()
local globalTop: { [string]: { Entry } } = {} -- board -> top list (decoded)
local refreshedAt: { [string]: number } = {}

local function ruleFor(statId: string, seasonal: boolean): string
	-- season rating is the player's current season rating; all-time keeps the peak
	if seasonal and statId == "rating" then
		return "latest"
	end
	local s = LC.BY_ID[statId]
	return s and s.rule or "best"
end

-- Records a value for one key on one board (live locally, queued for the DataStore).
local function record(board: string, statId: string, key: string, name: string, value: number, rule: string)
	local s = LC.BY_ID[statId]
	if not s or value ~= value or value == math.huge or value == -math.huge then
		return
	end
	if s.lowerBetter and value <= 0 then
		return -- no time yet
	end
	local vals = localVals[board]
	if not vals then
		vals = {}
		localVals[board] = vals
	end
	local old = vals[key]
	if old and rule == "best" and not LC.better(statId, value, old.value) then
		old.name = name
		return
	end
	if old and old.value == value then
		old.name = name
		return
	end
	vals[key] = { key = key, name = name, value = value }
	local q = pending[board]
	if not q then
		q = {}
		pending[board] = q
	end
	q[key] = LC.encode(statId, value)
end

-- Writes queued values (throttled per key, budget-aware). `force` ignores the per-key cooldown.
local function flush(onlyBoard: string?, force: boolean?)
	if not storesOk then
		return
	end
	local writes = 0
	for board, q in pending do
		if onlyBoard and board ~= onlyBoard then
			continue
		end
		local statId = statOfBoard(board)
		local seasonal = board:find("_S%d+$") ~= nil
		local rule = ruleFor(statId, seasonal)
		local store = orderedStore(board)
		if not store then
			return
		end
		-- iterate a copy: the writes below yield, and record() / another flush may change q meanwhile
		for key, encoded in table.clone(q) do
			if q[key] ~= encoded then
				continue -- written by a concurrent flush, or replaced by a newer value
			end
			if writes >= 12 and not force then
				return
			end
			local wk = board .. "|" .. key
			if not force and os.clock() - (lastWrite[wk] or -math.huge) < LC.WRITE_COOLDOWN then
				continue
			end
			-- Values read from the save only ever improve (level, rep, wins, 5K best...),
			-- so a plain write is enough. A peak rating and a race time from a single
			-- race may be worse than the saved best: those compare first (costs a read).
			local compare = rule == "best" and (statId == "rating" or statId == "fastestRace")
			if not budget(Enum.DataStoreRequestType.SetIncrementSortedAsync) then
				return
			end
			if compare and not budget(Enum.DataStoreRequestType.GetAsync, 20) then
				continue
			end
			q[key] = nil
			lastWrite[wk] = os.clock()
			writes += 1
			local ok, err = pcall(function()
				if not compare then
					(store :: OrderedDataStore):SetAsync(key, encoded)
					return
				end
				(store :: OrderedDataStore):UpdateAsync(key, function(old)
					if type(old) == "number" and not LC.better(statId, encoded, old) then
						return nil -- the saved value is already better
					end
					return encoded
				end)
			end)
			if not ok then
				noteFailure(err)
				if storesOk and q[key] == nil then
					q[key] = encoded -- try again after the cooldown
				end
			end
		end
		if next(q) == nil and pending[board] == q then
			pending[board] = nil
		end
	end
end

-- Re-reads one board's global top list.
local function refreshBoard(board: string, count: number?): { Entry }?
	local statId = statOfBoard(board)
	local s = LC.BY_ID[statId]
	local store = orderedStore(board)
	if not s or not store or not budget(Enum.DataStoreRequestType.GetSortedAsync) then
		return nil
	end
	local ok, page = pcall(function()
		local pages = (store :: OrderedDataStore):GetSortedAsync(s.lowerBetter, count or LC.TOP_N, if s.lowerBetter then 1 else nil)
		return pages:GetCurrentPage()
	end)
	if not ok then
		noteFailure(page)
		return nil
	end
	local list: { Entry } = {}
	for _, item in page do
		if type(item.value) == "number" then
			table.insert(list, { key = tostring(item.key), name = displayName(board, tostring(item.key)), value = LC.decode(statId, item.value) })
		end
	end
	resolveNames(board, list)
	return list
end

---------------------------------------------------------------------------
-- Merged views (global top + live values from this server)
---------------------------------------------------------------------------
local function boardFor(statId: string, scope: string): string?
	local s = LC.BY_ID[statId]
	if not s then
		return nil
	end
	if scope == "season" then
		local season = currentSeason()
		if not s.seasonal or not season then
			return nil
		end
		return boardName(statId, season.number)
	end
	return boardName(statId, nil)
end

-- Full merged list for a board, best first (global entries plus this server's values).
local function merged(board: string): { Entry }
	local statId = statOfBoard(board)
	local seasonal = board:find("_S%d+$") ~= nil
	local rule = ruleFor(statId, seasonal)
	local byKey: { [string]: Entry } = {}
	local top: { Entry } = globalTop[board] or {}
	for _, e in top do
		byKey[e.key] = { key = e.key, name = displayName(board, e.key), value = e.value }
	end
	local vals: { [string]: Entry } = localVals[board] or {}
	for key, e in vals do
		local g = byKey[key]
		local online = statOfBoard(board) ~= "crewRating" and tonumber(key) ~= nil and Players:GetPlayerByUserId(tonumber(key) :: number) ~= nil
		if not g or (rule == "latest" and (online or statId == "crewRating")) or LC.better(statId, e.value, g.value) then
			byKey[key] = { key = key, name = e.name, value = e.value }
		end
	end
	local list = {}
	for _, e in byKey do
		table.insert(list, e)
	end
	table.sort(list, function(a, b)
		if a.value ~= b.value then
			return LC.better(statId, a.value, b.value)
		end
		return a.key < b.key
	end)
	return list
end

-- Public: the top `n` of a board ("all" | "season"), each { rank, key, name, value, text }.
-- Returns nil for an unknown stat or a season board with no season running.
function Leaderboards.top(statId: string, n: number?, scope: string?): { any }?
	local board = boardFor(statId, scope or "all")
	if not board then
		return nil
	end
	local out = {}
	for i, e in merged(board) do
		if i > (n or LC.TOP_N) then
			break
		end
		table.insert(out, { rank = i, key = e.key, name = e.name, value = e.value, text = LC.format(statId, e.value) })
	end
	return out
end

-- True when the global DataStore boards are in use (false = this server only).
function Leaderboards.isGlobal(): boolean
	return storesOk
end

---------------------------------------------------------------------------
-- Public submit API
---------------------------------------------------------------------------
local function sectionOf(player: Player): any
	return PlayerData.section(player, "leaderboards")
end

function Leaderboards.submit(statId: string, player: Player, value: number)
	local s = LC.BY_ID[statId]
	if not s or s.crew or typeof(player) ~= "Instance" or not player:IsA("Player") or type(value) ~= "number" then
		return
	end
	-- [Security] sane bounds: finite, non-negative, levels within the cap, no impossible 5K
	local bad = value ~= value or value < 0 or value >= 2 ^ 53
		or (statId == "level" and value > Config.MAX_LEVEL)
		or (statId == "fastest5k" and value > 0 and value < MIN_5K_SECONDS)
	if bad then
		local warnKey = statId .. ":" .. player.UserId
		if not rejectedWarned[warnKey] then
			rejectedWarned[warnKey] = true
			warn(string.format("[Security] Leaderboards rejected %s=%s for %s", statId, tostring(value), player.Name))
		end
		return
	end
	local key = tostring(player.UserId)
	local name = player.DisplayName
	record(boardName(statId, nil), statId, key, name, value, ruleFor(statId, false))
	if s.seasonal then
		local season = currentSeason()
		-- the cached season may lag the rollover by a few seconds: never write into an ended season
		if season and not (type(season.endsAt) == "number" and os.time() >= season.endsAt) then
			local seasonValue = value
			if statId == "wins" then
				local sec = sectionOf(player)
				if not sec or sec.seasonId ~= season.id then
					return -- the season baseline isn't set yet (next poll sets it)
				end
				seasonValue = math.max(0, value - (sec.winsBase or 0))
			end
			record(boardName(statId, season.number), statId, key, name, seasonValue, ruleFor(statId, true))
		end
	end
end

function Leaderboards.submitCrew(crewId: string, crewName: string, value: number)
	if type(crewId) ~= "string" or crewId == "" or type(value) ~= "number" then
		return
	end
	if type(crewName) == "string" and crewName ~= "" then
		crewNames[crewId] = crewName
		-- remember the (already filtered) crew name for other servers' boards
		if crewNameWritten[crewId] ~= crewName and crewNameStore and storesOk then
			crewNameWritten[crewId] = crewName
			task.spawn(function()
				if budget(Enum.DataStoreRequestType.SetIncrementAsync) then
					local ok, err = pcall(function()
						(crewNameStore :: DataStore):SetAsync(crewId, crewName)
					end)
					if not ok then
						crewNameWritten[crewId] = nil
						noteFailure(err)
					end
				else
					crewNameWritten[crewId] = nil
				end
			end)
		end
	end
	record(boardName("crewRating", nil), "crewRating", crewId, crewNames[crewId] or "Crew", value, "latest")
end

---------------------------------------------------------------------------
-- Reading the stats this module tracks on its own
---------------------------------------------------------------------------
local raceHooked = false

local function hookRacing()
	if raceHooked then
		return
	end
	local Racing = optional("Racing")
	if Racing and typeof(Racing.raceFinished) == "Instance" and Racing.raceFinished:IsA("BindableEvent") then
		raceHooked = true
		Racing.raceFinished.Event:Connect(function(player, _place, timeSeconds, raceKind)
			-- street routes are different distances; circuit / trial are the 3-lap speedway
			if raceKind == "street" then
				return
			end
			if typeof(player) == "Instance" and player:IsA("Player") and type(timeSeconds) == "number" and timeSeconds > 0 then
				Leaderboards.submit("fastestRace", player, timeSeconds)
			end
		end)
	end
end

local function attrNumber(player: Player, name: string): number?
	local v = player:GetAttribute(name)
	return if type(v) == "number" then v else nil
end

local function poll(player: Player)
	if not player.Parent or not PlayerData.isLoaded(player) then
		return
	end
	-- season wins baseline
	local season = currentSeason()
	local sec = sectionOf(player)
	if season and sec and sec.seasonId ~= season.id then
		sec.seasonId = season.id
		sec.winsBase = attrNumber(player, "Wins") or 0
		PlayerData.markChanged(player)
	end
	for attr, statId in { Level = "level", Cash = "cash", Reputation = "reputation", Fame = "fame", Wins = "wins", Rating = "rating" } do
		local v = attrNumber(player, attr)
		if v then
			Leaderboards.submit(statId, player, v)
		end
	end
	local data = PlayerData.get(player)
	if data and type(data.basketball) == "table" and type(data.basketball.points) == "number" then
		Leaderboards.submit("points", player, data.basketball.points)
	end
	local ev = PlayerData.section(player, "events")
	if ev and type(ev.best5k) == "number" and ev.best5k > 0 then
		Leaderboards.submit("fastest5k", player, ev.best5k)
	end
	local Racing = optional("Racing")
	if Racing and type(Racing.bestTime) == "function" then
		local ok, t = pcall(Racing.bestTime, player)
		if ok and type(t) == "number" and t > 0 then
			Leaderboards.submit("fastestRace", player, t)
		end
	end
end

---------------------------------------------------------------------------
-- Achievements for global ranks
---------------------------------------------------------------------------
local function checkRankAchievements()
	if not storesOk then
		return -- a one-server board is no achievement
	end
	local Quests = optional("Quests")
	if not Quests or type(Quests.unlock) ~= "function" then
		return
	end
	for _, s in LC.STATS do
		if s.crew then
			continue
		end
		local list = globalTop[boardName(s.id, nil)]
		if not list then
			continue
		end
		for i, e in list do
			if i > 10 then
				break
			end
			local uid = tonumber(e.key)
			local p = uid and Players:GetPlayerByUserId(uid)
			if p then
				pcall(Quests.unlock, p, "lb_top10")
				if i == 1 then
					pcall(Quests.unlock, p, "lb_number1")
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Archive
---------------------------------------------------------------------------
type ArchiveIndexItem = { id: string, name: string, number: number, at: number }
local archiveIndex: { ArchiveIndexItem } = {}
local archiveMem: { [string]: any } = {} -- seasonId -> record (also caches DataStore reads)
local archiving: { [string]: boolean } = {}
local indexLoadedAt = -math.huge

local function loadIndex()
	if not archiveStore or not storesOk or not budget(Enum.DataStoreRequestType.GetAsync) then
		return
	end
	indexLoadedAt = os.clock()
	local ok, result = pcall(function()
		return (archiveStore :: DataStore):GetAsync("index")
	end)
	if ok and type(result) == "table" then
		archiveIndex = result
	elseif not ok then
		noteFailure(result)
	end
end

local function addToIndex(list: { ArchiveIndexItem }, item: ArchiveIndexItem): { ArchiveIndexItem }
	for _, it in list do
		if it.id == item.id then
			return list
		end
	end
	table.insert(list, 1, item)
	table.sort(list, function(a, b)
		return (a.at or 0) > (b.at or 0)
	end)
	while #list > LC.ARCHIVES_KEPT do
		table.remove(list)
	end
	return list
end

-- Snapshots the top 100 of the season boards ("rating", "wins", "fastestRace") under that season.
function Leaderboards.archive(seasonId: string)
	if type(seasonId) ~= "string" or seasonId == "" or archiving[seasonId] then
		return
	end
	local season = currentSeason()
	local number = seasonNumbers[seasonId]
	if not number and season and season.id == seasonId then
		number = season.number
	end
	if not number then
		number = tonumber(seasonId:match("(%d+)%D*$"))
	end
	if not number then
		warn("[CityGrind] Leaderboards.archive: unknown season", seasonId)
		return
	end
	archiving[seasonId] = true
	local seasonNumber: number = number
	task.spawn(function()
		local snap = {
			id = seasonId,
			name = seasonNames[seasonId] or ("Season " .. seasonNumber),
			number = seasonNumber,
			at = os.time(),
			boards = {},
		}
		for _, s in LC.STATS do
			if not s.seasonal then
				continue
			end
			local board = boardName(s.id, seasonNumber)
			flush(board, true) -- get this server's last values in first
			local list = refreshBoard(board, LC.ARCHIVE_N)
			if not list then
				list = merged(board)
			else
				-- the DataStore may lag behind values this server just wrote
				globalTop[board] = list
				list = merged(board)
			end
			local rows = {}
			for i, e in list do
				if i > LC.ARCHIVE_N then
					break
				end
				table.insert(rows, { k = e.key, n = e.name, v = e.value })
			end
			snap.boards[s.id] = rows
		end
		archiveMem[seasonId] = snap
		archiveIndex = addToIndex(archiveIndex, { id = seasonId, name = snap.name, number = seasonNumber, at = snap.at })
		if archiveStore and storesOk then
			local ok, err = pcall(function()
				local as = archiveStore :: DataStore
				as:UpdateAsync("season_" .. seasonId, function(old)
					-- another server may have archived the same season with more entries
					if type(old) == "table" and type(old.boards) == "table" then
						local oldCount, newCount = 0, 0
						for _, rows in old.boards do
							oldCount += #rows
						end
						for _, rows in snap.boards do
							newCount += #rows
						end
						if oldCount >= newCount then
							return nil
						end
					end
					return snap
				end)
				as:UpdateAsync("index", function(old)
					return addToIndex(if type(old) == "table" then old else {}, { id = seasonId, name = snap.name, number = seasonNumber, at = snap.at })
				end)
			end)
			if not ok then
				noteFailure(err)
			end
		end
	end)
end

local archiveMissAt: { [string]: number } = {}

local function readArchive(seasonId: string): any
	local rec = archiveMem[seasonId]
	if rec then
		return rec
	end
	-- only seasons in the index, and a failed read is not retried for a minute:
	-- a client can't spend the server's GetAsync budget on made-up ids
	local listed = false
	for _, it in archiveIndex do
		if it.id == seasonId then
			listed = true
			break
		end
	end
	if not listed or os.clock() - (archiveMissAt[seasonId] or -math.huge) < 60 then
		return nil
	end
	archiveMissAt[seasonId] = os.clock()
	if archiveStore and storesOk and budget(Enum.DataStoreRequestType.GetAsync) then
		local ok, result = pcall(function()
			return (archiveStore :: DataStore):GetAsync("season_" .. seasonId)
		end)
		if ok and type(result) == "table" then
			archiveMem[seasonId] = result
			return result
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Phone remote
---------------------------------------------------------------------------
local function friendSet(player: Player): { [string]: boolean }
	local set = { [tostring(player.UserId)] = true }
	local Social = optional("Social")
	if Social and type(Social.friendIds) == "function" then
		local ok, ids = pcall(Social.friendIds, player)
		if ok and type(ids) == "table" then
			for _, uid in ids do
				set[tostring(uid)] = true
			end
		end
	end
	return set
end

local function crewIdOf(player: Player): string?
	local id = player:GetAttribute("CrewId")
	return if type(id) == "string" and id ~= "" then id else nil
end

local function boardView(player: Player, statId: string, scope: string): any
	local s = LC.BY_ID[statId]
	if not s then
		return { ok = false, msg = "Unknown board." }
	end
	local board = boardFor(statId, if scope == "season" then "season" else "all")
	if not board then
		return { ok = false, msg = "No ranked season is running right now." }
	end
	local list = merged(board)
	local myKey = if s.crew then crewIdOf(player) else tostring(player.UserId)
	if scope == "friends" then
		if s.crew then
			return { ok = false, msg = "Crew boards have no friends view." }
		end
		local set = friendSet(player)
		local filtered = {}
		for _, e in list do
			if set[e.key] then
				table.insert(filtered, e)
			end
		end
		list = filtered
	end
	local entries = {}
	local mine = nil
	for i, e in list do
		if myKey and e.key == myKey then
			mine = { rank = if i <= LC.TOP_N or scope == "friends" then i else nil, value = e.value, text = LC.format(statId, e.value) }
		end
		if i <= LC.TOP_N then
			table.insert(entries, { rank = i, name = e.name, text = LC.format(statId, e.value), me = myKey ~= nil and e.key == myKey, userId = if s.crew then nil else tonumber(e.key) })
		end
	end
	return {
		ok = true,
		stat = statId,
		scope = scope,
		entries = entries,
		mine = mine,
		global = storesOk,
		updatedAt = refreshedAt[board],
	}
end

LeaderboardsGet.OnServerInvoke = function(player: Player, action: any, a: any, b: any)
	if not Net.allow(player, "LeaderboardsGet", 0.2) then
		return { ok = false, msg = "Slow down." }
	end
	if action == "Meta" then
		if os.clock() - indexLoadedAt > 600 then
			loadIndex()
		end
		local season = currentSeason()
		local archives = {}
		for _, it in archiveIndex do
			table.insert(archives, { id = it.id, name = it.name, at = it.at })
		end
		return {
			ok = true,
			global = storesOk,
			season = season and { id = season.id, name = seasonNames[season.id] or ("Season " .. season.number), number = season.number, endsAt = season.endsAt } or nil,
			archives = archives,
			inCrew = crewIdOf(player) ~= nil,
		}
	elseif action == "Board" then
		if type(a) ~= "string" or (b ~= "all" and b ~= "season" and b ~= "friends") then
			return { ok = false, msg = "Bad request." }
		end
		return boardView(player, a, b)
	elseif action == "Archive" then
		if type(a) ~= "string" or #a > 64 then
			return { ok = false, msg = "Bad request." }
		end
		local rec = readArchive(a)
		if not rec then
			return { ok = false, msg = "That season's archive isn't available." }
		end
		local boards = {}
		local myKey = tostring(player.UserId)
		for statId, rows in rec.boards or {} do
			local list = {}
			for i, r in rows do
				if i > LC.ARCHIVE_N then
					break
				end
				table.insert(list, { rank = i, name = tostring(r.n), text = LC.format(statId, tonumber(r.v) or 0), me = tostring(r.k) == myKey })
			end
			boards[statId] = list
		end
		return { ok = true, id = rec.id, name = rec.name, at = rec.at, boards = boards }
	end
	return { ok = false, msg = "Unknown action." }
end

---------------------------------------------------------------------------
-- World boards (SurfaceGuis updated by the server)
---------------------------------------------------------------------------
type WorldBoard = { title: TextLabel, sub: TextLabel, rows: { TextLabel }, stats: { string }, index: number, name: string }
local worldBoards: { WorldBoard } = {}

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.TextColor3 = Color3.fromRGB(235, 235, 245)
	for k, v in props do
		(t :: any)[k] = v
	end
	t.Parent = parent
	return t
end

-- A free-standing board at `base` (ground point) whose screen faces `dir`.
local function buildWorldBoard(folder: Instance, key: string, base: Vector3, dir: Vector3, lift: number)
	local def = LC.WORLD_BOARDS[key]
	local m = Instance.new("Model")
	m.Name = key .. "Board"
	m.Parent = folder
	dir = Vector3.new(dir.X, 0, dir.Z).Unit
	local right = Vector3.new(-dir.Z, 0, dir.X)
	local w, h = 26, 16
	local legH = lift + 1
	for _, s in { -1, 1 } do
		local legPos = base + right * s * (w / 2 - 1) - dir * 0.8 + Vector3.new(0, legH / 2, 0)
		part({ Name = "Leg", Size = Vector3.new(1, legH, 1), CFrame = CFrame.new(legPos), Color = Color3.fromRGB(40, 40, 46), Material = Enum.Material.Metal, Parent = m })
	end
	local center = base + Vector3.new(0, lift + h / 2, 0)
	local board = part({ Name = "Screen", Size = Vector3.new(w, h, 1), CFrame = CFrame.lookAt(center, center + dir), Color = Color3.fromRGB(14, 14, 20), Material = Enum.Material.SmoothPlastic, Parent = m })
	part({ Name = "Trim", Size = Vector3.new(w + 1, 0.6, 1.4), CFrame = CFrame.lookAt(center + Vector3.new(0, h / 2 + 0.3, 0), center + Vector3.new(0, h / 2 + 0.3, 0) + dir), Color = Color3.fromRGB(255, 200, 60), Material = Enum.Material.Neon, Parent = m })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.MaxDistance = 300
	gui.Parent = board
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(14, 14, 22)
	bg.BorderSizePixel = 0
	bg.Parent = gui
	local title = text(bg, { Font = Enum.Font.GothamBlack, Position = UDim2.fromScale(0.03, 0.03), Size = UDim2.fromScale(0.94, 0.12), Text = def.title, TextColor3 = Color3.fromRGB(255, 200, 60) })
	local sub = text(bg, { Font = Enum.Font.GothamMedium, Position = UDim2.fromScale(0.03, 0.15), Size = UDim2.fromScale(0.94, 0.07), Text = "", TextColor3 = Color3.fromRGB(160, 160, 175) })
	local rows = {}
	local rowH = 0.74 / LC.WORLD_ROWS
	for r = 1, LC.WORLD_ROWS do
		local row = text(bg, {
			Position = UDim2.fromScale(0.05, 0.24 + (r - 1) * rowH),
			Size = UDim2.fromScale(0.9, rowH * 0.86),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
		})
		table.insert(rows, row)
	end
	table.insert(worldBoards, { title = title, sub = sub, rows = rows, stats = def.stats, index = 0, name = def.title })
end

local function updateWorldBoards()
	for _, wb in worldBoards do
		wb.index = wb.index % #wb.stats + 1
		local statId = wb.stats[wb.index]
		local s = LC.BY_ID[statId]
		local list = Leaderboards.top(statId, LC.WORLD_ROWS, "all") or {}
		wb.title.Text = s.icon .. "  " .. string.upper(s.label)
		wb.title.TextColor3 = s.color
		wb.sub.Text = wb.name .. "  ·  " .. (if storesOk then "ALL SERVERS" else "THIS SERVER") .. "  ·  PHONE › LEADERBOARDS"
		for r, row in wb.rows do
			local e = list[r]
			row.Text = if e then string.format("%d.  %s   —   %s", r, e.name, e.text) elseif r == 1 then "No entries yet — be the first!" else ""
			row.TextColor3 = if r == 1 then Color3.fromRGB(255, 215, 90) elseif r <= 3 then Color3.fromRGB(220, 225, 240) else Color3.fromRGB(190, 190, 205)
		end
	end
end

local function buildWorld(city: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Leaderboards"
	folder.Parent = city
	-- behind the north hoop of the Neighborhood court (court centre 100,0,-110; 76 long)
	-- (lifted above the court's own scoreboard, which tops out at y 16 on the north fence at z -152)
	buildWorldBoard(folder, "Court", Vector3.new(100, 0, -162), Vector3.new(0, 0, 1), 17)
	-- City Speedway: in the infield, facing the grandstand on the south straight
	local districts = city:FindFirstChild("Districts")
	local industrial = districts and districts:FindFirstChild("Industrial")
	local track = industrial and industrial:FindFirstChild("RaceTrack")
	local center = track and track:GetAttribute("Center")
	if typeof(center) == "Vector3" then
		buildWorldBoard(folder, "Grandstand", Vector3.new(center.X - 60, 0, center.Z + 58), Vector3.new(0, 0, 1), 4)
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Leaderboards.start(city: Instance?)
	if city then
		local ok, err = pcall(buildWorld, city)
		if not ok then
			warn("[CityGrind] Leaderboards world boards failed:", err)
		end
	end

	PlayerData.onLoaded(function(player)
		task.wait(2)
		poll(player)
	end)

	-- attribute / save polling
	task.spawn(function()
		while true do
			task.wait(LC.POLL_SECONDS)
			hookRacing()
			for _, p in Players:GetPlayers() do
				pcall(poll, p)
			end
		end
	end)

	-- queued writes
	task.spawn(function()
		while true do
			task.wait(5)
			pcall(flush, nil, false)
		end
	end)

	-- global top lists
	task.spawn(function()
		task.wait(8)
		loadIndex()
		local cycle = 0
		while true do
			hookRacing()
			local boards = {}
			for _, s in LC.STATS do
				table.insert(boards, boardName(s.id, nil))
				local season = currentSeason()
				if s.seasonal and season then
					table.insert(boards, boardName(s.id, season.number))
				end
			end
			-- start at a different board each cycle so that, when the GetSortedAsync budget is
			-- tight (small servers), the boards at the end of the list don't starve
			cycle += 1
			local offset = cycle % #boards
			for i = 1, #boards do
				local board = boards[(i + offset - 1) % #boards + 1]
				if not storesOk then
					break
				end
				local list = refreshBoard(board, nil)
				if list then
					globalTop[board] = list
					refreshedAt[board] = os.time()
				end
				task.wait(0.5)
			end
			pcall(checkRankAchievements)
			task.wait(LC.REFRESH_SECONDS)
		end
	end)

	-- world boards rotate
	task.spawn(function()
		task.wait(3)
		while true do
			pcall(updateWorldBoards)
			task.wait(LC.WORLD_ROTATE_SECONDS)
		end
	end)

	-- last chance to write before the server closes
	game:BindToClose(function()
		if storesOk and not IS_STUDIO then
			pcall(flush, nil, true)
		end
	end)
end

return Leaderboards
