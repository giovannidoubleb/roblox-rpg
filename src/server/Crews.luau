-- CITY GRIND: crews (sections 60, 61, 62). Server side.
-- A crew is a persistent group with a name, tag, colour and logo. It lives in
-- its own DataStore record (so it exists while members are offline or on other
-- servers); every write re-reads the record with UpdateAsync. MessagingService
-- tells other servers to reload a crew after a change. Without DataStore access
-- (Studio) crews work in memory for the current server.
--
-- Crew rep grows from members' activity: every point of Reputation a member
-- earns is added to crew rep. Crew level comes from crew rep. Each week the crew
-- has a mission tracked from members' Wins / Reputation / Level increases.
--
-- Remotes:  CrewRequest (RemoteFunction): (action, args) -> { ok, message }
--           CrewGet     (RemoteFunction): () -> snapshot for the Crew phone app
--           CrewEvent   (RemoteEvent, server -> client): ("changed") ("invite", {crewId, name, tag, by})
-- Player attributes: CrewId, CrewName, CrewTag, CrewColor (Color3), CrewRole, CrewLogo, CrewLevel ("" / nil when crewless)
-- Saved section "crew" = { crewId = "", invites = { {crewId, name, tag, by, at} } }
-- DataStores: CityGrind_Crews_v1 (key "crew_<id>"), CityGrind_CrewNames_v1 (lower name -> id),
--             OrderedDataStore CityGrind_CrewRep_v1 (crew id -> rep)

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local CrewsConfig = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("CrewsConfig"))

local Crews = {}

local SERVER_ID = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
local TOPIC = "CityGrindCrews"
local FLUSH_SECONDS = 45
local LEADERBOARD_SECONDS = 90
local ONLINE_STALE = 6 * 3600

local CrewRequest = Net.remote("RemoteFunction", "CrewRequest")
local CrewGet = Net.remote("RemoteFunction", "CrewGet")
local CrewEvent = Net.remote("RemoteEvent", "CrewEvent")

PlayerData.registerSection("crew", function()
	return { crewId = "", invites = {} }
end)

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local store: DataStore? = nil
local nameStore: DataStore? = nil
local rankStore: OrderedDataStore? = nil
pcall(function()
	store = DataStoreService:GetDataStore("CityGrind_Crews_v1")
	nameStore = DataStoreService:GetDataStore("CityGrind_CrewNames_v1")
	rankStore = DataStoreService:GetOrderedDataStore("CityGrind_CrewRep_v1")
end)

local storeOk = false -- set by the probe in start(); false = in-memory crews for this server
local probeDone = false

local cache: { [string]: any } = {} -- crew id -> latest record we've seen (authoritative in memory mode)
local memoryNames: { [string]: string } = {}
local crewIdOf: { [Player]: string } = {} -- online members in this server
local pending: { [string]: { rep: number, stats: { [string]: number } } } = {}
local lastStats: { [Player]: { [string]: number } } = {}
local busy: { [Player]: boolean } = {}
local leaderboardCache: { at: number, list: { any } }? = nil

local function retry<T>(attempts: number, fn: () -> T): (boolean, any)
	local ok, result
	for attempt = 1, attempts do
		ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if attempt < attempts then
			task.wait(attempt)
		end
	end
	return false, result
end

local function deepCopy(t: any): any
	if type(t) ~= "table" then
		return t
	end
	local c = {}
	for k, v in t do
		c[k] = deepCopy(v)
	end
	return c
end

local function waitProbe()
	local deadline = os.clock() + 15
	while not probeDone and os.clock() < deadline do
		task.wait(0.2)
	end
end

-- Reads a crew. `fresh` forces a DataStore read (otherwise the cache is fine).
local function readCrew(id: string, fresh: boolean?): any
	if not storeOk or not store then
		return cache[id]
	end
	if not fresh and cache[id] then
		return cache[id]
	end
	local ok, rec = retry(3, function()
		return (store :: DataStore):GetAsync("crew_" .. id)
	end)
	if ok then
		if rec then
			cache[id] = rec -- the stored copy is the truth
		else
			cache[id] = nil
		end
		return rec
	end
	return cache[id]
end

-- Atomically edits a crew: `mutate(rec)` runs on the freshest copy and returns
-- (true) to save or (false, why) to abort. It must not yield.
local function editCrew(id: string, mutate: (any) -> (boolean, string?)): (boolean, string?, any)
	local why: string? = nil
	if storeOk and store then
		local result = nil
		local ok, err = retry(3, function()
			return (store :: DataStore):UpdateAsync("crew_" .. id, function(saved)
				why = nil
				if type(saved) ~= "table" or saved.disbanded then
					why = "That crew doesn't exist anymore."
					return nil
				end
				local fine, reason = mutate(saved)
				if not fine then
					why = reason or "Couldn't do that."
					return nil
				end
				saved.version = (saved.version or 0) + 1
				result = saved
				return saved
			end)
		end)
		if not ok then
			warn("[CityGrind] Crew save failed:", err)
			return false, "The crew service is busy. Try again in a moment."
		end
		if why or not result then
			return false, why or "Couldn't do that."
		end
		cache[id] = result
		return true, nil, result
	end
	local rec = cache[id]
	if not rec or rec.disbanded then
		return false, "That crew doesn't exist anymore."
	end
	local copy = deepCopy(rec)
	local fine, reason = mutate(copy)
	if not fine then
		return false, reason or "Couldn't do that."
	end
	copy.version = (copy.version or 0) + 1
	cache[id] = copy
	return true, nil, copy
end

local function setRank(rec: any)
	if not storeOk or not rankStore or rec.disbanded then
		return
	end
	task.spawn(function()
		pcall(function()
			(rankStore :: OrderedDataStore):SetAsync(rec.id, math.floor(rec.rep or 0))
		end)
	end)
end

local function publishChange(id: string, note: { title: string, body: string }?)
	if not storeOk then
		return
	end
	task.spawn(function()
		pcall(function()
			MessagingService:PublishAsync(TOPIC, { id = id, server = SERVER_ID, title = note and note.title, body = note and note.body })
		end)
	end)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function lazy(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

local function uidKey(userId: number): string
	return tostring(userId)
end

local function memberCount(rec: any): number
	local n = 0
	for _ in rec.members do
		n += 1
	end
	return n
end

local function roleOf(rec: any, userId: number): string?
	local m = rec and rec.members and rec.members[uidKey(userId)]
	return m and m.role
end

local function rank(role: string?): number
	return role and CrewsConfig.ROLE_RANK[role] or 0
end

local function colorOf(rec: any): Color3
	local entry = CrewsConfig.COLORS[rec.color] or CrewsConfig.COLORS[1]
	return entry.color
end

local function currentMission(rec: any, now: number)
	local week = CrewsConfig.weekIndex(now)
	local m = rec.mission
	if type(m) ~= "table" or m.week ~= week then
		local def = CrewsConfig.missionFor(rec.id, week)
		return { week = week, id = def.id, progress = 0, done = false }, true
	end
	return m, false
end

local function missionDef(id: string)
	for _, def in CrewsConfig.MISSIONS do
		if def.id == id then
			return def
		end
	end
	return CrewsConfig.MISSIONS[1]
end

local function pruneInvites(rec: any)
	local now = os.time()
	rec.invites = rec.invites or {}
	for k, inv in rec.invites do
		if type(inv) ~= "table" or now - (inv.at or 0) > CrewsConfig.INVITE_DAYS * 86400 then
			rec.invites[k] = nil
		end
	end
end

-- Filters text written by a player for display to everyone. nil = rejected / failed.
local function filterBroadcast(text: string, userId: number): string?
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" then
		return result
	end
	return nil
end

local function cleanSpaces(text: string): string
	return (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

---------------------------------------------------------------------------
-- Membership on this server
---------------------------------------------------------------------------
local function setAttributes(player: Player, rec: any?)
	if not player.Parent then
		return
	end
	if rec then
		local level = CrewsConfig.levelFor(rec.rep or 0)
		player:SetAttribute("CrewId", rec.id)
		player:SetAttribute("CrewName", rec.name)
		player:SetAttribute("CrewTag", rec.tag)
		player:SetAttribute("CrewColor", colorOf(rec))
		player:SetAttribute("CrewRole", roleOf(rec, player.UserId) or "Member")
		player:SetAttribute("CrewLogo", CrewsConfig.LOGOS[rec.logo] or CrewsConfig.LOGOS[1])
		player:SetAttribute("CrewLevel", level)
	else
		player:SetAttribute("CrewId", "")
		player:SetAttribute("CrewName", "")
		player:SetAttribute("CrewTag", "")
		player:SetAttribute("CrewColor", nil)
		player:SetAttribute("CrewRole", "")
		player:SetAttribute("CrewLogo", "")
		player:SetAttribute("CrewLevel", 0)
	end
end

local function changed(player: Player)
	if player.Parent then
		CrewEvent:FireClient(player, "changed")
	end
end

local function attach(player: Player, rec: any)
	crewIdOf[player] = rec.id
	local section = PlayerData.section(player, "crew")
	if section and section.crewId ~= rec.id then
		section.crewId = rec.id
		PlayerData.markChanged(player)
	end
	setAttributes(player, rec)
	changed(player)
end

local function detach(player: Player, message: string?)
	crewIdOf[player] = nil
	local section = PlayerData.section(player, "crew")
	if section and section.crewId ~= "" then
		section.crewId = ""
		PlayerData.markChanged(player)
	end
	setAttributes(player, nil)
	changed(player)
	if message then
		Net.notify(player, "CREW", message)
	end
end

-- Re-applies a crew record to everyone on this server who belongs to it.
local function refreshMembers(id: string)
	local rec = cache[id]
	for player, crewId in crewIdOf do
		if crewId == id then
			if not rec or rec.disbanded then
				detach(player, "Your crew was disbanded.")
			elseif not rec.members[uidKey(player.UserId)] then
				detach(player, "You're no longer in " .. rec.name .. ".")
			else
				setAttributes(player, rec)
				changed(player)
			end
		end
	end
end

local function notifyCrew(id: string, title: string, body: string, except: Player?)
	for player, crewId in crewIdOf do
		if crewId == id and player ~= except then
			Net.notify(player, title, body)
		end
	end
end

-- After any successful edit: update players here and tell other servers.
local function afterEdit(rec: any, note: { title: string, body: string }?, except: Player?)
	refreshMembers(rec.id)
	if note then
		notifyCrew(rec.id, note.title, note.body, except)
	end
	publishChange(rec.id, note)
end

---------------------------------------------------------------------------
-- Rep, wins and missions
---------------------------------------------------------------------------
local function addPending(id: string, rep: number, stat: string?, amount: number?)
	local p = pending[id]
	if not p then
		p = { rep = 0, stats = {} }
		pending[id] = p
	end
	p.rep += rep
	if stat and amount then
		p.stats[stat] = (p.stats[stat] or 0) + amount
	end
end

-- Public: adds crew rep on behalf of a member (saved with the next flush).
function Crews.addCrewRep(player: Player, amount: number)
	local id = crewIdOf[player]
	if id and type(amount) == "number" and amount > 0 and amount == amount then
		addPending(id, math.floor(amount), nil, nil)
	end
end

local function flushCrew(id: string)
	local p = pending[id]
	pending[id] = nil
	-- online members' current wins for the crew stats
	local wins: { [string]: number } = {}
	local names: { [string]: string } = {}
	for player, crewId in crewIdOf do
		if crewId == id then
			wins[uidKey(player.UserId)] = player:GetAttribute("Wins") or 0
			names[uidKey(player.UserId)] = player.DisplayName
		end
	end
	if not p then
		-- nothing earned: only save if someone's win count moved
		local cached = cache[id]
		local moved = false
		for key, w in wins do
			local m = cached and cached.members[key]
			if m and m.wins ~= w then
				moved = true
			end
		end
		if not moved then
			return
		end
	end
	local completed = nil
	local ok, _, rec = editCrew(id, function(r)
		completed = nil
		if p then
			r.rep = (r.rep or 0) + p.rep
			local mission, _ = currentMission(r, os.time())
			r.mission = mission
			local def = missionDef(mission.id)
			local gained = p.stats[def.stat]
			if gained and not mission.done then
				mission.progress = math.min(def.goal, mission.progress + gained)
				if mission.progress >= def.goal then
					mission.done = true
					r.rep += def.reward
					completed = def
				end
			end
		end
		for key, w in wins do
			local m = r.members[key]
			if m then
				m.wins = w
				m.name = names[key] or m.name
			end
		end
		return true
	end)
	if ok and rec then
		setRank(rec)
		local note = nil
		if completed then
			note = { title = "CREW MISSION COMPLETE", body = completed.title .. " - +" .. completed.reward .. " crew rep!" }
		end
		afterEdit(rec, note)
	elseif p then
		-- keep the progress for the next attempt (unless the crew is gone)
		if cache[id] and not cache[id].disbanded then
			addPending(id, p.rep, nil, nil)
			for stat, n in p.stats do
				addPending(id, 0, stat, n)
			end
		end
	end
end

local function flushAll()
	local ids = {}
	for id in pending do
		ids[id] = true
	end
	for _, id in crewIdOf do
		ids[id] = true
	end
	for id in ids do
		flushCrew(id)
	end
end

local function watchStats(player: Player)
	lastStats[player] = {}
	local watched = { Reputation = true }
	for _, stat in CrewsConfig.MISSION_STATS do
		watched[stat] = true
	end
	for stat in watched do
		player:GetAttributeChangedSignal(stat):Connect(function()
			local value = player:GetAttribute(stat)
			local last = lastStats[player]
			if not last or type(value) ~= "number" then
				return
			end
			local before = last[stat]
			last[stat] = value
			if before == nil or not player:GetAttribute("DataLoaded") then
				return -- first value after loading isn't progress
			end
			local delta = value - before
			local id = crewIdOf[player]
			if delta > 0 and id then
				addPending(id, if stat == "Reputation" then delta else 0, stat, delta)
			end
		end)
		local v = player:GetAttribute(stat)
		if type(v) == "number" then
			lastStats[player][stat] = v
		end
	end
end

---------------------------------------------------------------------------
-- Snapshot for the phone app
---------------------------------------------------------------------------
local function getLeaderboard(): { any }
	if leaderboardCache and os.clock() - leaderboardCache.at < LEADERBOARD_SECONDS then
		return leaderboardCache.list
	end
	local list = {}
	local function row(rec: any, rep: number)
		local level = CrewsConfig.levelFor(rep)
		table.insert(list, {
			id = rec.id,
			name = rec.name,
			tag = rec.tag,
			logo = CrewsConfig.LOGOS[rec.logo] or CrewsConfig.LOGOS[1],
			color = colorOf(rec),
			rep = rep,
			level = level,
		})
	end
	local fromStore = false
	if storeOk and rankStore then
		local ok, page = pcall(function()
			return (rankStore :: OrderedDataStore):GetSortedAsync(false, 10):GetCurrentPage()
		end)
		if ok and type(page) == "table" then
			fromStore = true
			for _, entry in page do
				local rec = readCrew(entry.key, false)
				if rec and not rec.disbanded then
					row(rec, entry.value)
				end
			end
		end
	end
	if not fromStore then
		local recs = {}
		for _, rec in cache do
			if not rec.disbanded then
				table.insert(recs, rec)
			end
		end
		table.sort(recs, function(a, b)
			return (a.rep or 0) > (b.rep or 0)
		end)
		for i = 1, math.min(10, #recs) do
			row(recs[i], recs[i].rep or 0)
		end
	end
	leaderboardCache = { at = os.clock(), list = list }
	return list
end

local function crewSnapshot(rec: any, viewer: Player)
	local now = os.time()
	local level, floorRep, nextRep = CrewsConfig.levelFor(rec.rep or 0)
	local members = {}
	local totalWins = 0
	for key, m in rec.members do
		local userId = tonumber(key) or 0
		local here = Players:GetPlayerByUserId(userId)
		local wins = if here then (here:GetAttribute("Wins") or 0) else (m.wins or 0)
		totalWins += wins
		table.insert(members, {
			userId = userId,
			name = if here then here.DisplayName else (m.name or "Player"),
			role = m.role,
			wins = wins,
			online = here ~= nil or (type(m.server) == "string" and m.server ~= "" and now - (m.seen or 0) < ONLINE_STALE),
			here = here ~= nil,
			seen = m.seen or 0,
		})
	end
	table.sort(members, function(a, b)
		if rank(a.role) ~= rank(b.role) then
			return rank(a.role) > rank(b.role)
		end
		if a.online ~= b.online then
			return a.online
		end
		return a.name < b.name
	end)
	local mission = currentMission(rec, now)
	local def = missionDef(mission.id)
	return {
		id = rec.id,
		name = rec.name,
		tag = rec.tag,
		color = colorOf(rec),
		logo = CrewsConfig.LOGOS[rec.logo] or CrewsConfig.LOGOS[1],
		rep = rec.rep or 0,
		level = level,
		levelFloor = floorRep,
		levelNext = nextRep,
		createdAt = rec.createdAt or 0,
		announcement = rec.announcement,
		members = members,
		memberCount = #members,
		maxMembers = CrewsConfig.MAX_MEMBERS,
		totalWins = totalWins,
		myRole = roleOf(rec, viewer.UserId) or "Member",
		mission = {
			title = def.title,
			progress = mission.progress,
			goal = def.goal,
			reward = def.reward,
			done = mission.done,
			endsAt = CrewsConfig.weekEnds(now),
		},
	}
end

local function snapshotFor(player: Player)
	local id = crewIdOf[player]
	local rec = id and cache[id]
	local section = PlayerData.section(player, "crew")
	local invites = {}
	if section and not rec then
		for _, inv in section.invites do
			if os.time() - (inv.at or 0) <= CrewsConfig.INVITE_DAYS * 86400 then
				table.insert(invites, { crewId = inv.crewId, name = inv.name, tag = inv.tag, by = inv.by, at = inv.at })
			end
		end
	end
	return {
		loaded = section ~= nil,
		crew = if rec and not rec.disbanded then crewSnapshot(rec, player) else nil,
		invites = invites,
		leaderboard = getLeaderboard(),
		fee = CrewsConfig.FEE,
		minLevel = CrewsConfig.MIN_LEVEL,
		persistent = storeOk,
	}
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
local function myCrew(player: Player): (any, string?)
	local id = crewIdOf[player]
	local rec = id and cache[id]
	if not rec or rec.disbanded then
		return nil, "You're not in a crew."
	end
	return rec
end

local function claimName(lower: string, id: string): boolean
	if not storeOk or not nameStore then
		if memoryNames[lower] and cache[memoryNames[lower]] and not cache[memoryNames[lower]].disbanded then
			return false
		end
		memoryNames[lower] = id
		return true
	end
	local taken = false
	local ok = retry(3, function()
		return (nameStore :: DataStore):UpdateAsync(lower, function(old)
			taken = false
			if type(old) == "string" and old ~= id then
				taken = true
				return nil
			end
			return id
		end)
	end)
	return ok and not taken
end

local function releaseName(lower: string, id: string)
	if not storeOk or not nameStore then
		if memoryNames[lower] == id then
			memoryNames[lower] = nil
		end
		return
	end
	task.spawn(function()
		pcall(function()
			(nameStore :: DataStore):UpdateAsync(lower, function(old)
				if old == id then
					return nil
				end
				return old
			end)
		end)
		pcall(function()
			(nameStore :: DataStore):RemoveAsync(lower)
		end)
	end)
end

function Crews.create(player: Player, args: any): (boolean, string?)
	if type(args) ~= "table" then
		return false, "Fill in the form."
	end
	local section = PlayerData.section(player, "crew")
	if not section then
		return false, "Your data is still loading."
	end
	if crewIdOf[player] or section.crewId ~= "" then
		return false, "Leave your crew before starting a new one."
	end
	if (player:GetAttribute("Level") or 1) < CrewsConfig.MIN_LEVEL then
		return false, "You need to be level " .. CrewsConfig.MIN_LEVEL .. " to start a crew."
	end
	if (player:GetAttribute("Cash") or 0) < CrewsConfig.FEE then
		return false, "Starting a crew costs " .. CrewsConfig.FEE .. " cash."
	end
	local name = type(args.name) == "string" and cleanSpaces(args.name) or ""
	local tag = type(args.tag) == "string" and string.upper((args.tag:gsub("%s", ""))) or ""
	local color = args.color
	local logo = args.logo
	if #name < CrewsConfig.NAME_MIN or #name > CrewsConfig.NAME_MAX or not name:match("^[%w '%-_%.]+$") then
		return false, "Crew names are 3-20 letters, numbers or spaces."
	end
	if #tag < CrewsConfig.TAG_MIN or #tag > CrewsConfig.TAG_MAX or not tag:match("^[%w]+$") then
		return false, "Tags are 2-4 letters or numbers."
	end
	if type(color) ~= "number" or not CrewsConfig.COLORS[color] then
		return false, "Pick a crew colour."
	end
	if type(logo) ~= "number" or not CrewsConfig.LOGOS[logo] then
		return false, "Pick a crew logo."
	end
	local filteredName = filterBroadcast(name, player.UserId)
	local filteredTag = filterBroadcast(tag, player.UserId)
	if not filteredName or not filteredTag then
		return false, "Couldn't check that name right now. Try again."
	end
	if filteredName ~= name or filteredTag ~= tag then
		return false, "That name or tag isn't allowed. Try another."
	end

	local id = HttpService:GenerateGUID(false):gsub("-", ""):sub(1, 12)
	local lower = string.lower(name)
	if not claimName(lower, id) then
		return false, "A crew called " .. name .. " already exists."
	end
	if not PlayerData.spendCash(player, CrewsConfig.FEE, "Crew founded: " .. name) then
		releaseName(lower, id)
		return false, "Starting a crew costs " .. CrewsConfig.FEE .. " cash."
	end
	local now = os.time()
	local rec = {
		id = id,
		name = name,
		tag = tag,
		color = color,
		logo = logo,
		leader = player.UserId,
		createdAt = now,
		rep = 0,
		version = 1,
		members = {
			[uidKey(player.UserId)] = { name = player.DisplayName, role = "Leader", joined = now, server = SERVER_ID, seen = now, wins = player:GetAttribute("Wins") or 0 },
		},
		invites = {},
		announcement = nil,
		mission = nil,
	}
	rec.mission = (currentMission(rec, now))
	local saved = true
	if storeOk and store then
		local exists = false
		saved = retry(3, function()
			return (store :: DataStore):UpdateAsync("crew_" .. id, function(old)
				exists = old ~= nil
				if exists then
					return nil
				end
				return rec
			end)
		end) and not exists
	end
	if not saved then
		releaseName(lower, id)
		PlayerData.addCash(player, CrewsConfig.FEE, "Crew fee refund")
		return false, "Couldn't save your crew. Your fee was refunded - try again."
	end
	cache[id] = rec
	setRank(rec)
	leaderboardCache = nil
	if player.Parent then
		section.invites = {}
		attach(player, rec)
	end
	return true, "Welcome to " .. name .. " [" .. tag .. "]!"
end

function Crews.invite(from: Player, to: Player): (boolean, string?)
	local rec, why = myCrew(from)
	if not rec then
		return false, why
	end
	if rank(roleOf(rec, from.UserId)) < CrewsConfig.ROLE_RANK.Officer then
		return false, "Only officers and the leader can invite."
	end
	if to == from or not to.Parent then
		return false, "Pick someone else."
	end
	if crewIdOf[to] then
		return false, to.DisplayName .. " is already in a crew."
	end
	local toSection = PlayerData.section(to, "crew")
	if not toSection then
		return false, to.DisplayName .. " is still loading in."
	end
	if memberCount(rec) >= CrewsConfig.MAX_MEMBERS then
		return false, "Your crew is full."
	end
	local Social = lazy("Social")
	if Social and Social.allows then
		local ok, allowed, reason = pcall(Social.allows, from, to, "invite")
		if ok and not allowed then
			return false, reason or (to.DisplayName .. " isn't taking invites right now.")
		end
	end
	local key = uidKey(to.UserId)
	local ok, err, saved = editCrew(rec.id, function(r)
		if rank(roleOf(r, from.UserId)) < CrewsConfig.ROLE_RANK.Officer then
			return false, "Only officers and the leader can invite."
		end
		if r.members[key] then
			return false, to.DisplayName .. " is already in your crew."
		end
		pruneInvites(r)
		r.invites[key] = { by = from.DisplayName, at = os.time() }
		return true
	end)
	if not ok or not saved then
		return false, err
	end
	-- the invitee's own pending list (shown in their Crew app)
	for i = #toSection.invites, 1, -1 do
		local inv = toSection.invites[i]
		if inv.crewId == saved.id or os.time() - (inv.at or 0) > CrewsConfig.INVITE_DAYS * 86400 then
			table.remove(toSection.invites, i)
		end
	end
	table.insert(toSection.invites, 1, { crewId = saved.id, name = saved.name, tag = saved.tag, by = from.DisplayName, at = os.time() })
	while #toSection.invites > 10 do
		table.remove(toSection.invites)
	end
	PlayerData.markChanged(to)

	local Messages = lazy("Messages")
	local sent = false
	if Messages and Messages.sendInvite then
		local okCall, delivered, reason = pcall(Messages.sendInvite, from, to, "crew", {
			crewId = saved.id,
			label = saved.name .. " [" .. saved.tag .. "]", -- stored names are already filtered
		})
		if okCall and delivered then
			sent = true
		elseif okCall and reason then
			return false, reason
		end
	end
	if not sent then
		CrewEvent:FireClient(to, "invite", { crewId = saved.id, name = saved.name, tag = saved.tag, by = from.DisplayName })
		Net.notify(to, "CREW INVITE", from.DisplayName .. " invited you to " .. saved.name .. " [" .. saved.tag .. "]. Open the Crew app.")
	end
	changed(to)
	return true, "Invite sent to " .. to.DisplayName .. "."
end

local function dropInvite(player: Player, crewId: string)
	local section = PlayerData.section(player, "crew")
	if not section then
		return
	end
	for i = #section.invites, 1, -1 do
		if section.invites[i].crewId == crewId then
			table.remove(section.invites, i)
		end
	end
	PlayerData.markChanged(player)
end

function Crews.accept(player: Player, crewId: any): (boolean, string?)
	if type(crewId) ~= "string" or #crewId > 40 then
		return false, "That invite is no longer valid."
	end
	if crewIdOf[player] then
		return false, "Leave your crew before joining another."
	end
	local section = PlayerData.section(player, "crew")
	if not section then
		return false, "Your data is still loading."
	end
	if busy[player] then
		return false, "One moment..."
	end
	busy[player] = true
	local key = uidKey(player.UserId)
	local ok, why, rec = editCrew(crewId, function(r)
		pruneInvites(r)
		if r.members[key] then
			return true -- already a member (e.g. retried)
		end
		if not r.invites[key] then
			return false, "That invite expired. Ask for a new one."
		end
		if memberCount(r) >= CrewsConfig.MAX_MEMBERS then
			return false, "That crew is full."
		end
		r.invites[key] = nil
		local now = os.time()
		r.members[key] = { name = player.DisplayName, role = "Member", joined = now, server = SERVER_ID, seen = now, wins = player:GetAttribute("Wins") or 0 }
		return true
	end)
	busy[player] = nil
	dropInvite(player, crewId)
	if not ok or not rec then
		changed(player)
		return false, why
	end
	if not player.Parent then
		return false, nil
	end
	section.invites = {}
	attach(player, rec)
	afterEdit(rec, { title = "CREW", body = player.DisplayName .. " joined " .. rec.name .. "!" }, player)
	return true, "You joined " .. rec.name .. " [" .. rec.tag .. "]!"
end

function Crews.decline(player: Player, crewId: any): (boolean, string?)
	if type(crewId) ~= "string" then
		return false, nil
	end
	dropInvite(player, crewId)
	local key = uidKey(player.UserId)
	task.spawn(editCrew, crewId, function(r)
		if not r.invites or not r.invites[key] then
			return false
		end
		r.invites[key] = nil
		return true
	end)
	changed(player)
	return true, "Invite declined."
end

local function disbandCrew(rec: any, byName: string)
	local ok, why, saved = editCrew(rec.id, function(r)
		r.disbanded = true
		r.members = {}
		r.invites = {}
		return true
	end)
	if not ok or not saved then
		return false, why
	end
	releaseName(string.lower(saved.name), saved.id)
	if storeOk and rankStore then
		task.spawn(function()
			pcall(function()
				(rankStore :: OrderedDataStore):RemoveAsync(saved.id)
			end)
		end)
	end
	pending[saved.id] = nil
	leaderboardCache = nil
	afterEdit(saved, { title = "CREW", body = saved.name .. " was disbanded by " .. byName .. "." })
	return true, nil
end

function Crews.leave(player: Player): (boolean, string?)
	local rec, why = myCrew(player)
	if not rec then
		return false, why
	end
	local key = uidKey(player.UserId)
	if roleOf(rec, player.UserId) == "Leader" then
		if memberCount(rec) <= 1 then
			local ok, err = disbandCrew(rec, player.DisplayName)
			if ok then
				return true, "You left and the crew was disbanded."
			end
			return false, err
		end
		return false, "Make someone else leader first, or disband the crew."
	end
	flushCrew(rec.id)
	local ok, err, saved = editCrew(rec.id, function(r)
		if not r.members[key] then
			return true
		end
		if r.members[key].role == "Leader" then
			return false, "Make someone else leader first, or disband the crew."
		end
		r.members[key] = nil
		return true
	end)
	if not ok or not saved then
		return false, err
	end
	detach(player, nil)
	afterEdit(saved, { title = "CREW", body = player.DisplayName .. " left the crew." }, player)
	return true, "You left " .. saved.name .. "."
end

-- Role changes and kicks on any member, online or not.
local function manage(player: Player, action: string, targetId: any): (boolean, string?)
	local rec, why = myCrew(player)
	if not rec then
		return false, why
	end
	if type(targetId) ~= "number" or targetId % 1 ~= 0 or targetId == player.UserId then
		return false, "Pick another member."
	end
	local me, them = uidKey(player.UserId), uidKey(targetId)
	local targetName = "They"
	local resultMsg = ""
	local ok, err, saved = editCrew(rec.id, function(r)
		local myRole = r.members[me] and r.members[me].role
		local target = r.members[them]
		if not myRole then
			return false, "You're not in this crew anymore."
		end
		if not target then
			return false, "They're not in the crew anymore."
		end
		targetName = target.name or "They"
		if action == "kick" then
			if not (myRole == "Leader" or (myRole == "Officer" and target.role == "Member")) then
				return false, "You can't remove that member."
			end
			r.members[them] = nil
			resultMsg = targetName .. " was removed from the crew."
		elseif action == "promote" then
			if myRole ~= "Leader" or target.role ~= "Member" then
				return false, "Only the leader can promote members to officer."
			end
			target.role = "Officer"
			resultMsg = targetName .. " is now an officer."
		elseif action == "demote" then
			if myRole ~= "Leader" or target.role ~= "Officer" then
				return false, "Only the leader can demote officers."
			end
			target.role = "Member"
			resultMsg = targetName .. " is now a member."
		elseif action == "transfer" then
			if myRole ~= "Leader" then
				return false, "Only the leader can hand over the crew."
			end
			target.role = "Leader"
			r.members[me].role = "Officer"
			r.leader = targetId
			resultMsg = targetName .. " is the new crew leader."
		else
			return false, nil
		end
		return true
	end)
	if not ok or not saved then
		return false, err
	end
	if action == "kick" then
		local kicked = Players:GetPlayerByUserId(targetId)
		if kicked and crewIdOf[kicked] == saved.id then
			detach(kicked, "You were removed from " .. saved.name .. ".")
		end
	end
	afterEdit(saved, { title = "CREW", body = resultMsg })
	return true, resultMsg
end

function Crews.announce(player: Player, text: any): (boolean, string?)
	local rec, why = myCrew(player)
	if not rec then
		return false, why
	end
	if rank(roleOf(rec, player.UserId)) < CrewsConfig.ROLE_RANK.Officer then
		return false, "Only officers and the leader can post announcements."
	end
	if type(text) ~= "string" then
		return false, nil
	end
	text = cleanSpaces(text)
	if #text < 1 or utf8.len(text) == nil or #text > CrewsConfig.ANNOUNCE_MAX then
		return false, "Announcements are 1-" .. CrewsConfig.ANNOUNCE_MAX .. " characters."
	end
	local filtered = filterBroadcast(text, player.UserId)
	if not filtered then
		return false, "Couldn't post that right now. Try again."
	end
	local me = uidKey(player.UserId)
	local ok, err, saved = editCrew(rec.id, function(r)
		if rank(roleOf(r, player.UserId)) < CrewsConfig.ROLE_RANK.Officer or not r.members[me] then
			return false, "Only officers and the leader can post announcements."
		end
		r.announcement = { text = filtered, by = player.DisplayName, at = os.time() }
		return true
	end)
	if not ok or not saved then
		return false, err
	end
	afterEdit(saved, { title = "CREW ANNOUNCEMENT", body = filtered }, player)
	return true, "Announcement posted."
end

-- Public: the player's crew, or nil.
function Crews.crewOf(player: Player): { id: string, name: string, tag: string, color: Color3, role: string }?
	local id = crewIdOf[player]
	local rec = id and cache[id]
	if not rec or rec.disbanded then
		return nil
	end
	return { id = rec.id, name = rec.name, tag = rec.tag, color = colorOf(rec), role = roleOf(rec, player.UserId) or "Member" }
end

---------------------------------------------------------------------------
-- Loading players
---------------------------------------------------------------------------
local function onLoaded(player: Player)
	waitProbe()
	local section = PlayerData.section(player, "crew")
	if not section or not player.Parent then
		return
	end
	if type(section.invites) ~= "table" then
		section.invites = {}
	end
	local id = section.crewId
	if type(id) ~= "string" or id == "" then
		setAttributes(player, nil)
		changed(player)
		return
	end
	local rec = readCrew(id, true)
	local key = uidKey(player.UserId)
	if not rec or rec.disbanded or not rec.members[key] then
		-- (in memory mode crews don't outlive the server, so the old id just clears)
		if rec and storeOk then
			detach(player, if rec.disbanded then rec.name .. " was disbanded while you were away." else "You're no longer in " .. rec.name .. ".")
		else
			detach(player, nil)
		end
		return
	end
	attach(player, rec)
	-- mark online + refresh name/wins
	task.spawn(function()
		local ok, _, saved = editCrew(id, function(r)
			local m = r.members[key]
			if not m then
				return false
			end
			m.server = SERVER_ID
			m.seen = os.time()
			m.name = player.DisplayName
			m.wins = player:GetAttribute("Wins") or m.wins or 0
			return true
		end)
		if ok and saved then
			afterEdit(saved, nil)
		end
	end)
end

local function onRemoving(player: Player)
	local id = crewIdOf[player]
	crewIdOf[player] = nil
	lastStats[player] = nil
	busy[player] = nil
	if not id then
		return
	end
	local key = uidKey(player.UserId)
	local wins = player:GetAttribute("Wins") or 0
	local p = pending[id]
	pending[id] = nil
	local ok, _, saved = editCrew(id, function(r)
		local m = r.members[key]
		if p then
			r.rep = (r.rep or 0) + p.rep
			local mission = currentMission(r, os.time())
			r.mission = mission
			local def = missionDef(mission.id)
			local gained = p.stats[def.stat]
			if gained and not mission.done then
				mission.progress = math.min(def.goal, mission.progress + gained)
				if mission.progress >= def.goal then
					mission.done = true
					r.rep += def.reward
				end
			end
		end
		if m then
			m.server = ""
			m.seen = os.time()
			m.wins = wins
		end
		return true
	end)
	if ok and saved then
		setRank(saved)
		afterEdit(saved, nil)
	elseif p and cache[id] and not cache[id].disbanded then
		addPending(id, p.rep, nil, nil)
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local ACTIONS: { [string]: { cooldown: number, run: (Player, any) -> (boolean, string?) } } = {
	create = { cooldown = 4, run = Crews.create },
	invite = {
		cooldown = 2,
		run = function(player, args)
			local target = type(args) == "table" and args.target
			if typeof(target) ~= "Instance" or not target:IsA("Player") then
				return false, "Pick a player."
			end
			return Crews.invite(player, target)
		end,
	},
	accept = { cooldown = 1, run = function(player, args)
		return Crews.accept(player, type(args) == "table" and args.crewId)
	end },
	decline = { cooldown = 0.5, run = function(player, args)
		return Crews.decline(player, type(args) == "table" and args.crewId)
	end },
	leave = { cooldown = 2, run = function(player)
		return Crews.leave(player)
	end },
	disband = {
		cooldown = 3,
		run = function(player)
			local rec, why = myCrew(player)
			if not rec then
				return false, why
			end
			if roleOf(rec, player.UserId) ~= "Leader" then
				return false, "Only the leader can disband the crew."
			end
			local ok, err = disbandCrew(rec, player.DisplayName)
			return ok, if ok then "Crew disbanded." else err
		end,
	},
	announce = { cooldown = 10, run = function(player, args)
		return Crews.announce(player, type(args) == "table" and args.text)
	end },
}
for _, action in { "kick", "promote", "demote", "transfer" } do
	ACTIONS[action] = { cooldown = 1, run = function(player, args)
		return manage(player, action, type(args) == "table" and args.userId)
	end }
end

function Crews.start(_city: Instance?)
	-- Probe DataStore access once (fails fast in Studio without API access).
	task.spawn(function()
		if store then
			local ok = pcall(function()
				(store :: DataStore):GetAsync("probe")
			end)
			storeOk = ok
		end
		probeDone = true
		if not storeOk then
			warn("[CityGrind] Crews are running in memory only (no DataStore access).")
			return
		end
		pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function(message)
				local data = message.Data
				if type(data) ~= "table" or type(data.id) ~= "string" or data.server == SERVER_ID then
					return
				end
				local relevant = cache[data.id] ~= nil
				for _, crewId in crewIdOf do
					if crewId == data.id then
						relevant = true
					end
				end
				if not relevant then
					return
				end
				readCrew(data.id, true)
				refreshMembers(data.id)
				if type(data.title) == "string" and type(data.body) == "string" then
					notifyCrew(data.id, data.title, data.body)
				end
			end)
		end)
	end)

	CrewRequest.OnServerInvoke = function(player: Player, action: any, args: any)
		local entry = type(action) == "string" and ACTIONS[action]
		if not entry then
			return { ok = false, message = "Unknown action." }
		end
		if not Net.allow(player, "Crew" .. action, entry.cooldown) then
			return { ok = false, message = "Slow down a little." }
		end
		local ok, result, message = pcall(entry.run, player, args)
		if not ok then
			warn("[CityGrind] Crew action failed:", result)
			return { ok = false, message = "Something went wrong. Try again." }
		end
		leaderboardCache = if action == "create" or action == "disband" then nil else leaderboardCache
		return { ok = result == true, message = message }
	end

	CrewGet.OnServerInvoke = function(player: Player)
		if not Net.allow(player, "CrewGet", 0.5) then
			return nil
		end
		local ok, snap = pcall(snapshotFor, player)
		return if ok then snap else nil
	end

	-- Crew invite cards in the Messages app.
	task.spawn(function()
		local Messages = lazy("Messages")
		if Messages and Messages.onInvite then
			Messages.onInvite("crew", function(_from: Player?, to: Player, payload: any)
				-- Messages shows the returned message to the player
				return Crews.accept(to, type(payload) == "table" and payload.crewId or nil)
			end)
		end
	end)

	PlayerData.onLoaded(onLoaded)
	Players.PlayerAdded:Connect(watchStats)
	for _, player in Players:GetPlayers() do
		watchStats(player)
	end
	Players.PlayerRemoving:Connect(onRemoving)

	task.spawn(function()
		while true do
			task.wait(FLUSH_SECONDS)
			local ok, err = pcall(flushAll)
			if not ok then
				warn("[CityGrind] Crew flush failed:", err)
			end
		end
	end)

	game:BindToClose(function()
		if not storeOk then
			return
		end
		local count = 0
		for player in crewIdOf do
			count += 1
			task.spawn(function()
				onRemoving(player)
				count -= 1
			end)
		end
		local deadline = os.clock() + 20
		while count > 0 and os.clock() < deadline do
			task.wait(0.2)
		end
		pcall(flushAll)
	end)
end

return Crews
