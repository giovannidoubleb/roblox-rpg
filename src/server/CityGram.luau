-- CITY GRIND: CityGram + follows (sections 27, 28, 36, 88).
--
-- Posts are photos from your Gallery (SceneSnapshots) with a caption. Captions and
-- comments are filtered with TextService for broadcast BEFORE they are stored, so the
-- stored text is already safe for every viewer. Likes, comments and views come only
-- from real players; posting itself gives nothing: fame/rep come from engagement
-- (+1 fame per 5 likes from distinct players, +1 rep per like capped at 20/day).
--
-- DataStores (all pcall'd; without access everything works in memory for this server):
--   CityGrind_Posts_v1     post_<id>  = { id, u, n, cap, l, fl, t, likes, likers, lc, ever, ec, cm, cmc, views, del? }
--                          snap_<id>  = snapshot (immutable copy, so deleting the gallery photo keeps the post)
--                          user_<uid> = { ids = { { id, t } } } newest first (<= 100)
--                          recent     = { list = { { id, u, t } } } newest first (<= 200)
--   CityGrind_PostLikes_v1 (ordered, scope "d<day of post>") key postId -> likes   (Popular = last 48 h)
--   CityGrind_Follows_v1   user_<uid> = { followers = { [id] = t } (<= 500 newest), following = { [id] = t },
--                                         fc, gc, ever = { [id] = true }, everN, pf (pending fame), pl (pending likes),
--                                         inbox = { { id, from, n, t } } }
-- MessagingService topic "CityGrind_CityGram": new posts, cross-server notifications, "settle" pings.
--
-- Remotes: CityGramAction (RemoteFunction) (action, a, b) -> (ok, message, data)
--            feed tab [userId] | post photoId caption | like id | unlike id | comment id text | comments id
--            view id | share id toUserId | delete id | snap id | follow uid | unfollow uid
--            followers uid | following uid | myFollowing
--          CityGramProfile (RemoteFunction) (userId) -> { followers, following, posts = { id x3 }, postCount,
--            isFollowing, self, profilePhoto, photos }
--          CityGramEvent (RemoteEvent, server -> client): "Inbox" (count) | "Following" (ids)
-- Player attributes: Followers, Following, CityGramPosts (numbers)
-- Saved section "citygram": { posts, day, postsToday, lastPost, likesReceived, repDay, repToday, seen = { ids }, inbox = { ... } }

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserService = game:GetService("UserService")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local MediaConfig = require(shared:WaitForChild("MediaConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local CityGram = {}

local TOPIC = "CityGrind_CityGram"

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
PlayerData.registerSection("citygram", function()
	return {
		posts = 0,
		day = 0,
		postsToday = 0,
		lastPost = 0,
		likesReceived = 0,
		repDay = 0,
		repToday = 0,
		seen = {}, -- post ids already counted as viewed (newest last, <= 400)
		inbox = {}, -- posts shared with you { id, from, n, t }
	}
end)

local function sec(player: Player): any
	return PlayerData.section(player, "citygram")
end

---------------------------------------------------------------------------
-- Optional neighbours
---------------------------------------------------------------------------
local function optional(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

local function socialCall(fn: string, ...): (boolean, any, any)
	local Social = optional("Social")
	if not Social or type(Social[fn]) ~= "function" then
		return false, nil, nil
	end
	local ok, a, b = pcall(Social[fn], ...)
	return ok, a, b
end

-- Hidden from `viewer`: anyone either side blocked, or someone the viewer muted.
local function hiddenFor(viewer: Player, userId: number): boolean
	if userId == viewer.UserId then
		return false
	end
	local ok, blocked = socialCall("isBlockedId", viewer, userId)
	if ok and blocked then
		return true
	end
	local ok2, muted = socialCall("isMutedBy", viewer, userId)
	return ok2 and muted == true
end

---------------------------------------------------------------------------
-- Storage helpers (DataStore or in-memory)
---------------------------------------------------------------------------
type Store = { name: string, ds: DataStore? }

local function openStore(name: string): Store
	local ds: DataStore? = nil
	pcall(function()
		ds = DataStoreService:GetDataStore(name)
	end)
	return { name = name, ds = ds }
end

local postStore = openStore("CityGrind_Posts_v1")
local followStore = openStore("CityGrind_Follows_v1")
local memory: { [string]: any } = {}

local function retry<T>(fn: () -> T): (boolean, T?)
	for attempt = 1, 3 do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		task.wait(attempt)
	end
	return false, nil
end

local function dsGet(store: Store, key: string): (boolean, any)
	if not store.ds then
		return true, memory[store.name .. ":" .. key]
	end
	return retry(function()
		return (store.ds :: DataStore):GetAsync(key)
	end)
end

local function dsSet(store: Store, key: string, value: any): boolean
	if not store.ds then
		memory[store.name .. ":" .. key] = value
		return true
	end
	return (retry(function()
		return (store.ds :: DataStore):SetAsync(key, value)
	end))
end

-- fn(old) returns the new value, or nil to leave the record untouched.
local function dsUpdate(store: Store, key: string, fn: (any) -> any): (boolean, any)
	if not store.ds then
		local mkey = store.name .. ":" .. key
		local new = fn(memory[mkey])
		if new ~= nil then
			memory[mkey] = new
		end
		return true, memory[mkey]
	end
	return retry(function()
		return (store.ds :: DataStore):UpdateAsync(key, function(old)
			return fn(old)
		end)
	end)
end

local function dsRemove(store: Store, key: string)
	if not store.ds then
		memory[store.name .. ":" .. key] = nil
		return
	end
	task.spawn(retry, function()
		return (store.ds :: DataStore):RemoveAsync(key)
	end)
end

local function dayOf(t: number): number
	return math.floor(t / 86400)
end

local function likesStore(day: number): OrderedDataStore?
	if not postStore.ds then
		return nil
	end
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore("CityGrind_PostLikes_v1", "d" .. day)
	end)
	return if ok then store else nil
end

local function publish(message: any)
	task.spawn(pcall, function()
		MessagingService:PublishAsync(TOPIC, message)
	end)
end

local function newId(): string
	return (HttpService:GenerateGUID(false):gsub("%-", "")):sub(1, 16):lower()
end

local function validId(id: any): boolean
	return type(id) == "string" and #id >= 8 and #id <= 32 and id:match("^%w+$") ~= nil
end

local function validUserId(uid: any): boolean
	return type(uid) == "number" and uid % 1 == 0 and uid > 0 and uid < 1e13
end

local function mapCount(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------
local function trimText(text: any, max: number): string?
	if type(text) ~= "string" then
		return nil
	end
	if #text > max * 4 then
		return nil
	end
	text = text:gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
	local len = utf8.len(text)
	if not len or len > max then
		return nil
	end
	return text
end

local function filterBroadcast(text: string, userId: number): string?
	if text == "" then
		return ""
	end
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" then
		return result
	end
	-- Studio test players (negative ids) can't be filtered; their text passes in Studio only.
	if userId <= 0 and game:GetService("RunService"):IsStudio() then
		return text
	end
	return nil
end

local nameCache: { [number]: string } = {}
local function namesFor(ids: { number }): { [number]: string }
	local out, missing = {}, {}
	for _, id in ids do
		local p = Players:GetPlayerByUserId(id)
		if p then
			out[id] = p.DisplayName
		elseif nameCache[id] then
			out[id] = nameCache[id]
		else
			table.insert(missing, id)
		end
	end
	if #missing > 0 then
		local ok, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(missing)
		end)
		if ok and type(infos) == "table" then
			for _, info in infos do
				if type(info) == "table" and info.Id then
					nameCache[info.Id] = tostring(info.DisplayName or info.Username)
					out[info.Id] = nameCache[info.Id]
				end
			end
		end
	end
	for _, id in ids do
		out[id] = out[id] or "Player"
	end
	return out
end

---------------------------------------------------------------------------
-- Notifications (batched: "@A and 3 others liked your post")
---------------------------------------------------------------------------
local VERBS = { like = "liked your post", comment = "commented on your post", follow = "followed you" }
local pendingNotes: { [number]: { [string]: { names: { string }, count: number } } } = {}

local function deliver(toUserId: number, title: string, body: string)
	local p = Players:GetPlayerByUserId(toUserId)
	if p then
		Net.notify(p, title, body)
	else
		publish({ k = "notify", to = toUserId, ti = title, b = body })
	end
end

local function flushNotes(toUserId: number)
	local entries = pendingNotes[toUserId]
	pendingNotes[toUserId] = nil
	if not entries then
		return
	end
	for kind, e in entries do
		local who = "@" .. e.names[1]
		if e.count == 2 and e.names[2] then
			who ..= " and @" .. e.names[2]
		elseif e.count > 1 then
			who ..= string.format(" and %d others", e.count - 1)
		end
		deliver(toUserId, "CITYGRAM", who .. " " .. VERBS[kind])
	end
end

local function note(toUserId: number, kind: string, from: Player)
	if toUserId == from.UserId then
		return
	end
	local entries = pendingNotes[toUserId]
	if not entries then
		entries = {}
		pendingNotes[toUserId] = entries
		task.delay(6, flushNotes, toUserId)
	end
	local e = entries[kind]
	if not e then
		e = { names = {}, count = 0 }
		entries[kind] = e
	end
	if not table.find(e.names, from.DisplayName) then
		e.count += 1
		if #e.names < 2 then
			table.insert(e.names, from.DisplayName)
		end
	end
end

---------------------------------------------------------------------------
-- Rate limits per hour
---------------------------------------------------------------------------
local hourly: { [Player]: { [string]: { start: number, n: number } } } = {}
local function underHourly(player: Player, key: string, max: number): boolean
	local byKey = hourly[player]
	if not byKey then
		byKey = {}
		hourly[player] = byKey
	end
	local now = os.clock()
	local e = byKey[key]
	if not e or now - e.start > 3600 then
		e = { start = now, n = 0 }
		byKey[key] = e
	end
	if e.n >= max then
		return false
	end
	e.n += 1
	return true
end

---------------------------------------------------------------------------
-- Follows
---------------------------------------------------------------------------
local function defaultFollow()
	return { followers = {}, following = {}, fc = 0, gc = 0, ever = {}, everN = 0, pf = 0, pl = 0, inbox = {} }
end

local function fillFollow(rec: any): any
	rec = if type(rec) == "table" then rec else {}
	for k, v in defaultFollow() do
		if rec[k] == nil then
			rec[k] = v
		end
	end
	return rec
end

local followCache: { [number]: { rec: any, at: number } } = {}

local function getFollow(userId: number, maxAge: number?): any
	local c = followCache[userId]
	if c and os.clock() - c.at < (maxAge or 30) then
		return c.rec
	end
	local ok, rec = dsGet(followStore, "user_" .. userId)
	if not ok then
		return if c then c.rec else defaultFollow()
	end
	rec = fillFollow(rec)
	followCache[userId] = { rec = rec, at = os.clock() }
	return rec
end

local function cacheFollow(userId: number, rec: any)
	followCache[userId] = { rec = fillFollow(rec), at = os.clock() }
end

local function mirrorCounts(userId: number)
	local p = Players:GetPlayerByUserId(userId)
	local c = followCache[userId]
	if p and c then
		p:SetAttribute("Followers", c.rec.fc)
		p:SetAttribute("Following", c.rec.gc)
	end
end

local CityGramEvent: RemoteEvent

local function sendFollowing(player: Player)
	local rec = getFollow(player.UserId)
	local ids = {}
	for id in rec.following do
		local n = tonumber(id)
		if n then
			table.insert(ids, n)
		end
	end
	if CityGramEvent then
		CityGramEvent:FireClient(player, "Following", ids)
	end
end

local function creditLikes(player: Player, n: number)
	local s = sec(player)
	if not s or n <= 0 then
		return
	end
	local before = s.likesReceived
	s.likesReceived += n
	local fame = math.floor(s.likesReceived / MediaConfig.LIKES_PER_FAME) - math.floor(before / MediaConfig.LIKES_PER_FAME)
	local today = dayOf(os.time())
	if s.repDay ~= today then
		s.repDay = today
		s.repToday = 0
	end
	local rep = math.min(n * MediaConfig.REP_PER_LIKE, MediaConfig.REP_DAILY_CAP - s.repToday)
	PlayerData.markChanged(player)
	if fame > 0 then
		PlayerData.addFame(player, fame)
	end
	if rep > 0 then
		s.repToday += rep
		PlayerData.addReputation(player, rep)
	end
end

local function addToInbox(player: Player, entry: any)
	local s = sec(player)
	if not s then
		return
	end
	for i, e in s.inbox do
		if e.id == entry.id then
			table.remove(s.inbox, i)
			break
		end
	end
	table.insert(s.inbox, 1, entry)
	while #s.inbox > MediaConfig.INBOX_CAP do
		table.remove(s.inbox)
	end
	PlayerData.markChanged(player)
	if CityGramEvent then
		CityGramEvent:FireClient(player, "Inbox", #s.inbox)
	end
end

-- Collects fame / likes / shares that arrived while the player was away or on another server.
local settling: { [Player]: boolean } = {}
local function settle(player: Player)
	if settling[player] or not sec(player) then
		return
	end
	settling[player] = true
	local fame, likes, inbox = 0, 0, {}
	local ok, rec = dsUpdate(followStore, "user_" .. player.UserId, function(old)
		fame, likes, inbox = 0, 0, {}
		old = fillFollow(old)
		if old.pf <= 0 and old.pl <= 0 and #old.inbox == 0 then
			return nil
		end
		fame, likes, inbox = old.pf, old.pl, old.inbox
		old.pf, old.pl, old.inbox = 0, 0, {}
		return old
	end)
	settling[player] = nil
	if not ok then
		return
	end
	if rec then
		cacheFollow(player.UserId, rec)
	end
	mirrorCounts(player.UserId)
	if fame > 0 then
		PlayerData.addFame(player, fame)
	end
	if likes > 0 then
		creditLikes(player, likes)
	end
	for i = #inbox, 1, -1 do
		local e = inbox[i]
		if type(e) == "table" and validId(e.id) then
			addToInbox(player, { id = e.id, from = e.from, n = tostring(e.n or "Someone"):sub(1, 40), t = e.t or os.time() })
		end
	end
end

local function targetAllows(a: Player, targetUserId: number, kind: string): (boolean, string?)
	local target = Players:GetPlayerByUserId(targetUserId)
	if target then
		local ok, allowed, reason = socialCall("allows", a, target, kind)
		if ok and not allowed then
			return false, reason or "You can't do that."
		end
		return true, nil
	end
	local ok, blocked = socialCall("isBlockedId", a, targetUserId)
	if ok and blocked then
		return false, "You can't interact with this player."
	end
	return true, nil
end

function CityGram.follow(a: Player, targetUserId: number): (boolean, string?)
	if typeof(a) ~= "Instance" or not a:IsA("Player") or not validUserId(targetUserId) then
		return false, "Unknown player."
	end
	if targetUserId == a.UserId then
		return false, "You can't follow yourself."
	end
	if not Net.allow(a, "CityGramFollow", 1) or not underHourly(a, "follow", MediaConfig.FOLLOW_CHANGES_PER_HOUR) then
		return false, "Slow down a little."
	end
	local allowed, reason = targetAllows(a, targetUserId, "follow")
	if not allowed then
		return false, reason
	end
	local names = namesFor({ targetUserId })
	local targetName = names[targetUserId]
	local tKey, aKey = tostring(targetUserId), tostring(a.UserId)

	local already, full, firstEver = false, false, false
	local ok, mine = dsUpdate(followStore, "user_" .. a.UserId, function(old)
		already, full, firstEver = false, false, false
		old = fillFollow(old)
		if old.following[tKey] then
			already = true
			return nil
		end
		if old.gc >= MediaConfig.MAX_FOLLOWING then
			full = true
			return nil
		end
		old.following[tKey] = os.time()
		old.gc += 1
		if not old.ever[tKey] and old.everN < 2000 then
			old.ever[tKey] = true
			old.everN += 1
			firstEver = true
		end
		return old
	end)
	if not ok then
		return false, "CityGram is busy. Try again in a moment."
	end
	if already then
		return false, "You already follow " .. targetName .. "."
	end
	if full then
		return false, string.format("You can follow up to %d players.", MediaConfig.MAX_FOLLOWING)
	end
	cacheFollow(a.UserId, mine)

	local target = Players:GetPlayerByUserId(targetUserId)
	local fameHere = firstEver and target ~= nil and PlayerData.isLoaded(target)
	local okT, theirs = dsUpdate(followStore, "user_" .. targetUserId, function(old)
		old = fillFollow(old)
		if not old.followers[aKey] then
			old.fc += 1
		end
		old.followers[aKey] = os.time()
		if mapCount(old.followers) > MediaConfig.FOLLOW_ID_CAP then
			local oldestKey, oldestT = nil, math.huge
			for k, t in old.followers do
				if t < oldestT then
					oldestKey, oldestT = k, t
				end
			end
			if oldestKey then
				old.followers[oldestKey] = nil
			end
		end
		if firstEver and not fameHere then
			old.pf += MediaConfig.FAME_PER_FOLLOWER
		end
		return old
	end)
	if okT and theirs then
		cacheFollow(targetUserId, theirs)
	end
	if fameHere and target then
		PlayerData.addFame(target, MediaConfig.FAME_PER_FOLLOWER)
	elseif not target then
		publish({ k = "settle", u = targetUserId })
	end
	mirrorCounts(a.UserId)
	mirrorCounts(targetUserId)
	note(targetUserId, "follow", a)
	sendFollowing(a)
	return true, "You followed " .. targetName .. "."
end

function CityGram.unfollow(a: Player, targetUserId: number): (boolean, string?)
	if typeof(a) ~= "Instance" or not a:IsA("Player") or not validUserId(targetUserId) then
		return false, "Unknown player."
	end
	if not Net.allow(a, "CityGramFollow", 1) or not underHourly(a, "follow", MediaConfig.FOLLOW_CHANGES_PER_HOUR) then
		return false, "Slow down a little."
	end
	local tKey, aKey = tostring(targetUserId), tostring(a.UserId)
	local was = false
	local ok, mine = dsUpdate(followStore, "user_" .. a.UserId, function(old)
		was = false
		old = fillFollow(old)
		if not old.following[tKey] then
			return nil
		end
		was = true
		old.following[tKey] = nil
		old.gc = math.max(0, old.gc - 1)
		return old
	end)
	if not ok then
		return false, "CityGram is busy. Try again in a moment."
	end
	if not was then
		return false, "You don't follow them."
	end
	cacheFollow(a.UserId, mine)
	local okT, theirs = dsUpdate(followStore, "user_" .. targetUserId, function(old)
		old = fillFollow(old)
		old.followers[aKey] = nil
		old.fc = math.max(0, old.fc - 1)
		return old
	end)
	if okT and theirs then
		cacheFollow(targetUserId, theirs)
	end
	if not Players:GetPlayerByUserId(targetUserId) then
		publish({ k = "settle", u = targetUserId })
	end
	mirrorCounts(a.UserId)
	mirrorCounts(targetUserId)
	sendFollowing(a)
	return true, "Unfollowed " .. namesFor({ targetUserId })[targetUserId] .. "."
end

function CityGram.isFollowing(aUserId: number, bUserId: number): boolean
	if not validUserId(aUserId) or not validUserId(bUserId) then
		return false
	end
	return getFollow(aUserId).following[tostring(bUserId)] ~= nil
end

function CityGram.followerCount(userId: number): number
	return if validUserId(userId) then getFollow(userId).fc else 0
end

function CityGram.followingCount(userId: number): number
	return if validUserId(userId) then getFollow(userId).gc else 0
end

-- Up to 500 most recent follower ids.
function CityGram.followerIds(userId: number): { number }
	local out = {}
	if not validUserId(userId) then
		return out
	end
	for id in getFollow(userId).followers do
		local n = tonumber(id)
		if n then
			table.insert(out, n)
		end
	end
	return out
end

local function followingIds(userId: number): { number }
	local out = {}
	for id in getFollow(userId).following do
		local n = tonumber(id)
		if n then
			table.insert(out, n)
		end
	end
	return out
end

---------------------------------------------------------------------------
-- Posts: caches
---------------------------------------------------------------------------
local metaCache: { [string]: { m: any, at: number } } = {}
local snapCache: { [string]: any } = {}
local snapOrder: { string } = {}
local userLists: { [number]: { ids: { any }, at: number } } = {}
local recent: { any } = {}
local popularCache: { ids: { string }, at: number }? = nil
local pendingViews: { [string]: number } = {}

local function getMeta(id: string, maxAge: number?): any
	if not validId(id) then
		return nil
	end
	local c = metaCache[id]
	if c and os.clock() - c.at < (maxAge or 20) then
		return c.m
	end
	local ok, m = dsGet(postStore, "post_" .. id)
	if ok and type(m) == "table" and m.id == id then
		metaCache[id] = { m = m, at = os.clock() }
		return m
	end
	return if c then c.m else nil
end

local function setMetaCache(m: any)
	if type(m) == "table" and validId(m.id) then
		metaCache[m.id] = { m = m, at = os.clock() }
	end
end

-- Fetches several metas in parallel (cached).
local function getMetas(ids: { string }, maxAge: number?): { any }
	local results = {}
	local pending = #ids
	if pending == 0 then
		return results
	end
	local thread = coroutine.running()
	local finished = false
	for i, id in ids do
		task.spawn(function()
			results[i] = getMeta(id, maxAge) or false
			pending -= 1
			if pending == 0 and finished then
				task.spawn(thread)
			end
		end)
	end
	if pending > 0 then
		finished = true
		coroutine.yield()
	end
	local out = {}
	for i = 1, #ids do
		if results[i] then
			table.insert(out, results[i])
		end
	end
	return out
end

local function userList(userId: number, maxAge: number?): { any }
	local c = userLists[userId]
	if c and os.clock() - c.at < (maxAge or 120) then
		return c.ids
	end
	local ok, data = dsGet(postStore, "user_" .. userId)
	if ok then
		local ids = if type(data) == "table" and type(data.ids) == "table" then data.ids else {}
		userLists[userId] = { ids = ids, at = os.clock() }
		return ids
	end
	return if c then c.ids else {}
end

local function rememberRecent(entry: any)
	for i, e in recent do
		if e.id == entry.id then
			table.remove(recent, i)
			break
		end
	end
	table.insert(recent, 1, entry)
	while #recent > 200 do
		table.remove(recent)
	end
end

local function refreshRecent()
	local ok, data = dsGet(postStore, "recent")
	if ok and type(data) == "table" and type(data.list) == "table" then
		local merged = {}
		local seen = {}
		for _, e in data.list do
			if type(e) == "table" and validId(e.id) and not seen[e.id] then
				seen[e.id] = true
				table.insert(merged, e)
			end
		end
		for _, e in recent do
			if not seen[e.id] then
				seen[e.id] = true
				table.insert(merged, e)
			end
		end
		table.sort(merged, function(a, b)
			return (a.t or 0) > (b.t or 0)
		end)
		while #merged > 200 do
			table.remove(merged)
		end
		recent = merged
	end
end

local function getSnap(id: string): any
	local hit = snapCache[id]
	if hit then
		return hit
	end
	local ok, snap = dsGet(postStore, "snap_" .. id)
	if ok and type(snap) == "table" then
		snapCache[id] = snap
		table.insert(snapOrder, id)
		while #snapOrder > 150 do
			snapCache[table.remove(snapOrder, 1) :: string] = nil
		end
		return snap
	end
	return nil
end

-- What a viewer is sent for one post.
local function view(viewer: Player, m: any): any
	local key = tostring(viewer.UserId)
	return {
		id = m.id,
		u = m.u,
		n = m.n,
		cap = m.cap,
		l = m.l,
		fl = m.fl,
		t = m.t,
		likes = m.likes or 0,
		liked = type(m.likers) == "table" and m.likers[key] ~= nil,
		comments = m.cmc or 0,
		views = m.views or 0,
		mine = m.u == viewer.UserId,
	}
end

local function visible(viewer: Player, m: any): boolean
	return type(m) == "table" and not m.del and not hiddenFor(viewer, m.u)
end

---------------------------------------------------------------------------
-- Posting
---------------------------------------------------------------------------
local function createPost(player: Player, photoId: any, caption: any): (boolean, string?, any)
	if not Net.allow(player, "CityGramPost", 2) then
		return false, "Slow down.", nil
	end
	local s = sec(player)
	if not s then
		return false, "Your phone is still loading.", nil
	end
	local now = os.time()
	if now - s.lastPost < MediaConfig.POST_COOLDOWN then
		return false, string.format("Wait %ds before posting again.", MediaConfig.POST_COOLDOWN - (now - s.lastPost)), nil
	end
	local today = dayOf(now)
	if s.day ~= today then
		s.day = today
		s.postsToday = 0
	end
	if s.postsToday >= MediaConfig.POSTS_PER_DAY then
		return false, "That's enough posts for today. Come back tomorrow!", nil
	end
	local text = trimText(caption or "", MediaConfig.CAPTION_MAX)
	if not text then
		return false, string.format("Captions can be up to %d characters.", MediaConfig.CAPTION_MAX), nil
	end
	local Media = optional("Media")
	if not Media or not validId(photoId) or not Media.ownsPhoto(player, photoId) then
		return false, "Pick one of your own photos.", nil
	end
	local record = Media.getPhoto(photoId)
	if not record or record.o ~= player.UserId or type(record.s) ~= "table" then
		return false, "That photo couldn't be loaded.", nil
	end
	local filtered = filterBroadcast(text, player.UserId)
	if not filtered then
		return false, "Couldn't check that caption. Try different words or try again.", nil
	end

	local id = newId()
	local meta = {
		id = id,
		u = player.UserId,
		n = player.DisplayName,
		cap = filtered,
		l = tostring(record.s.l or ""),
		fl = tostring(record.s.fl or "None"),
		t = now,
		likes = 0,
		likers = {},
		lc = 0,
		ever = {},
		ec = 0,
		cm = {},
		cmc = 0,
		views = 0,
	}
	if not dsSet(postStore, "snap_" .. id, record.s) or not dsSet(postStore, "post_" .. id, meta) then
		return false, "CityGram is busy. Try again in a moment.", nil
	end
	snapCache[id] = record.s
	table.insert(snapOrder, id)
	setMetaCache(meta)
	local entry = { id = id, t = now }
	local okList, list = dsUpdate(postStore, "user_" .. player.UserId, function(old)
		old = if type(old) == "table" and type(old.ids) == "table" then old else { ids = {} }
		table.insert(old.ids, 1, entry)
		while #old.ids > 100 do
			table.remove(old.ids)
		end
		return old
	end)
	if okList and list then
		userLists[player.UserId] = { ids = list.ids, at = os.clock() }
	end
	rememberRecent({ id = id, u = player.UserId, t = now })
	task.spawn(dsUpdate, postStore, "recent", function(old)
		old = if type(old) == "table" and type(old.list) == "table" then old else { list = {} }
		table.insert(old.list, 1, { id = id, u = player.UserId, t = now })
		while #old.list > 200 do
			table.remove(old.list)
		end
		return old
	end)
	local ordered = likesStore(dayOf(now))
	if ordered then
		task.spawn(pcall, function()
			(ordered :: OrderedDataStore):SetAsync(id, 0)
		end)
	end
	popularCache = nil
	publish({ k = "post", id = id, u = player.UserId, t = now })

	s.lastPost = now
	s.postsToday += 1
	s.posts += 1
	PlayerData.markChanged(player)
	player:SetAttribute("CityGramPosts", s.posts)
	return true, "Posted to CityGram!", view(player, meta)
end

local function deletePost(player: Player, id: any): (boolean, string?)
	local m = validId(id) and getMeta(id, 0)
	if not m or m.del then
		return false, "That post is gone."
	end
	if m.u ~= player.UserId then
		return false, "You can only delete your own posts."
	end
	local ok, new = dsUpdate(postStore, "post_" .. id, function(old)
		if type(old) ~= "table" or old.u ~= player.UserId then
			return nil
		end
		old.del = true
		old.cap = ""
		old.cm = {}
		old.likers = {}
		old.ever = {}
		return old
	end)
	if not ok then
		return false, "CityGram is busy. Try again in a moment."
	end
	setMetaCache(new)
	dsRemove(postStore, "snap_" .. id)
	snapCache[id] = nil
	task.spawn(dsUpdate, postStore, "user_" .. player.UserId, function(old)
		if type(old) ~= "table" or type(old.ids) ~= "table" then
			return nil
		end
		for i, e in old.ids do
			if e.id == id then
				table.remove(old.ids, i)
				return old
			end
		end
		return nil
	end)
	local list = userLists[player.UserId]
	if list then
		for i, e in list.ids do
			if e.id == id then
				table.remove(list.ids, i)
				break
			end
		end
	end
	for i, e in recent do
		if e.id == id then
			table.remove(recent, i)
			break
		end
	end
	local ordered = likesStore(dayOf(m.t))
	if ordered then
		task.spawn(pcall, function()
			(ordered :: OrderedDataStore):RemoveAsync(id)
		end)
	end
	popularCache = nil
	return true, "Post deleted."
end

---------------------------------------------------------------------------
-- Engagement
---------------------------------------------------------------------------
local function engage(ownerId: number)
	local owner = Players:GetPlayerByUserId(ownerId)
	if owner and sec(owner) then
		creditLikes(owner, 1)
		return
	end
	task.spawn(function()
		dsUpdate(followStore, "user_" .. ownerId, function(old)
			old = fillFollow(old)
			old.pl += 1
			return old
		end)
		publish({ k = "settle", u = ownerId })
	end)
end

local function like(player: Player, id: any, on: boolean): (boolean, string?, any)
	if not Net.allow(player, "CityGramLike", 0.4) then
		return false, "Slow down.", nil
	end
	local m = validId(id) and getMeta(id)
	if not visible(player, m) then
		return false, "That post is gone.", nil
	end
	if on and not underHourly(player, "like", 300) then
		return false, "You've liked a lot of posts. Take a break!", nil
	end
	local key = tostring(player.UserId)
	local changed, first = false, false
	local ok, new = dsUpdate(postStore, "post_" .. id, function(old)
		changed, first = false, false
		if type(old) ~= "table" or old.del then
			return nil
		end
		old.likers = old.likers or {}
		old.ever = old.ever or {}
		if on then
			if old.likers[key] then
				return nil
			end
			old.likes = (old.likes or 0) + 1
			if (old.lc or 0) < MediaConfig.LIKER_IDS_CAP then
				old.likers[key] = os.time()
				old.lc = (old.lc or 0) + 1
			end
			if not old.ever[key] and (old.ec or 0) < MediaConfig.LIKER_IDS_CAP then
				old.ever[key] = true
				old.ec = (old.ec or 0) + 1
				first = true
			end
		else
			if not old.likers[key] then
				return nil
			end
			old.likers[key] = nil
			old.lc = math.max(0, (old.lc or 1) - 1)
			old.likes = math.max(0, (old.likes or 1) - 1)
		end
		changed = true
		return old
	end)
	if not ok then
		return false, "CityGram is busy. Try again in a moment.", nil
	end
	if new then
		setMetaCache(new)
	end
	local current = new or m
	if changed then
		local ordered = likesStore(dayOf(current.t))
		if ordered then
			local likes = current.likes
			task.spawn(pcall, function()
				(ordered :: OrderedDataStore):SetAsync(id, likes)
			end)
		end
		if on and first and current.u ~= player.UserId then
			engage(current.u)
			note(current.u, "like", player)
		end
	end
	return true, nil, view(player, current)
end

local function commentsFor(viewer: Player, m: any): { any }
	local out = {}
	for _, c in m.cm or {} do
		if type(c) == "table" and not hiddenFor(viewer, c.u) then
			table.insert(out, { u = c.u, n = c.n, x = c.x, t = c.t })
		end
	end
	return out
end

local function comment(player: Player, id: any, text: any): (boolean, string?, any)
	if not Net.allow(player, "CityGramComment", 3) or not underHourly(player, "comment", 60) then
		return false, "Slow down a little.", nil
	end
	local m = validId(id) and getMeta(id)
	if not visible(player, m) then
		return false, "That post is gone.", nil
	end
	local owner = Players:GetPlayerByUserId(m.u)
	if owner and owner ~= player then
		local allowed, reason = targetAllows(player, m.u, "interact")
		if not allowed then
			return false, reason, nil
		end
	end
	local clean = trimText(text, MediaConfig.COMMENT_MAX)
	if not clean or clean == "" then
		return false, string.format("Comments are 1-%d characters.", MediaConfig.COMMENT_MAX), nil
	end
	local filtered = filterBroadcast(clean, player.UserId)
	if not filtered then
		return false, "Couldn't check that comment. Try again.", nil
	end
	local entry = { u = player.UserId, n = player.DisplayName, x = filtered, t = os.time() }
	local ok, new = dsUpdate(postStore, "post_" .. id, function(old)
		if type(old) ~= "table" or old.del then
			return nil
		end
		old.cm = old.cm or {}
		table.insert(old.cm, entry)
		while #old.cm > MediaConfig.COMMENTS_STORED do
			table.remove(old.cm, 1)
		end
		old.cmc = (old.cmc or 0) + 1
		return old
	end)
	if not ok or not new then
		return false, "CityGram is busy. Try again in a moment.", nil
	end
	setMetaCache(new)
	note(new.u, "comment", player)
	return true, nil, { post = view(player, new), comments = commentsFor(player, new) }
end

local function countView(player: Player, id: any)
	local m = validId(id) and getMeta(id)
	local s = sec(player)
	if not s or not m or m.del or m.u == player.UserId then
		return
	end
	if table.find(s.seen, id) then
		return
	end
	table.insert(s.seen, id)
	while #s.seen > 400 do
		table.remove(s.seen, 1)
	end
	PlayerData.markChanged(player)
	if postStore.ds then
		-- (in memory mode `m` IS the stored record, so the line below already counts it)
		pendingViews[id] = (pendingViews[id] or 0) + 1
	end
	m.views = (m.views or 0) + 1 -- show it right away here; flushed to the store in batches
end

local function flushViews()
	local batch = pendingViews
	pendingViews = {}
	for id, n in batch do
		task.spawn(function()
			local ok, new = dsUpdate(postStore, "post_" .. id, function(old)
				if type(old) ~= "table" or old.del then
					return nil
				end
				old.views = (old.views or 0) + n
				return old
			end)
			if ok and new then
				setMetaCache(new)
			end
		end)
	end
end

local function share(player: Player, id: any, toUserId: any): (boolean, string?)
	if not Net.allow(player, "CityGramShare", 2) or not underHourly(player, "share", 40) then
		return false, "Slow down a little."
	end
	local m = validId(id) and getMeta(id)
	if not visible(player, m) then
		return false, "That post is gone."
	end
	if not validUserId(toUserId) or toUserId == player.UserId then
		return false, "Pick someone to share with."
	end
	local entry = { id = id, from = player.UserId, n = player.DisplayName, t = os.time() }
	local target = Players:GetPlayerByUserId(toUserId)
	if target then
		local allowed, reason = targetAllows(player, toUserId, "message")
		if not allowed then
			return false, reason
		end
		if hiddenFor(target, m.u) then
			return false, target.DisplayName .. " can't see that post."
		end
		addToInbox(target, entry)
		Net.notify(target, "CITYGRAM", "@" .. player.DisplayName .. " shared a post with you. Check your CityGram Inbox.")
		return true, "Shared with " .. target.DisplayName .. "."
	end
	-- not in this server: in-game friends only (their privacy can't be read from here)
	local okF, ids = socialCall("friendIds", player)
	if not okF or type(ids) ~= "table" or not table.find(ids, toUserId) then
		return false, "You can only share with friends who aren't in this server."
	end
	local ok = dsUpdate(followStore, "user_" .. toUserId, function(old)
		old = fillFollow(old)
		table.insert(old.inbox, 1, entry)
		while #old.inbox > 20 do
			table.remove(old.inbox)
		end
		return old
	end)
	if not ok then
		return false, "CityGram is busy. Try again in a moment."
	end
	publish({ k = "settle", u = toUserId })
	deliver(toUserId, "CITYGRAM", "@" .. player.DisplayName .. " shared a post with you.")
	return true, "Shared! They'll see it in their CityGram Inbox."
end

---------------------------------------------------------------------------
-- Feeds
---------------------------------------------------------------------------
local function popularIds(): { string }
	if popularCache and os.clock() - popularCache.at < 60 then
		return popularCache.ids
	end
	local now = os.time()
	local candidates: { string } = {}
	local seen = {}
	if postStore.ds then
		for back = 0, 2 do
			local ordered = likesStore(dayOf(now) - back)
			if ordered then
				local ok, page = pcall(function()
					return (ordered :: OrderedDataStore):GetSortedAsync(false, 30):GetCurrentPage()
				end)
				if ok and type(page) == "table" then
					for _, entry in page do
						if validId(entry.key) and not seen[entry.key] then
							seen[entry.key] = true
							table.insert(candidates, entry.key)
						end
					end
				end
			end
		end
	else
		for key, value in memory do
			local id = key:match("^CityGrind_Posts_v1:post_(%w+)$")
			if id and type(value) == "table" then
				table.insert(candidates, id)
			end
		end
	end
	local metas = getMetas(candidates, 60)
	local cutoff = now - MediaConfig.POPULAR_HOURS * 3600
	local keep = {}
	for _, m in metas do
		if not m.del and (m.t or 0) >= cutoff and (m.likes or 0) > 0 then
			table.insert(keep, m)
		end
	end
	table.sort(keep, function(a, b)
		if a.likes ~= b.likes then
			return a.likes > b.likes
		end
		return a.t > b.t
	end)
	local ids = {}
	for i = 1, math.min(#keep, 30) do
		ids[i] = keep[i].id
	end
	popularCache = { ids = ids, at = os.clock() }
	return ids
end

local function newestFirst(entries: { any }, limit: number): { string }
	table.sort(entries, function(a, b)
		return (a.t or 0) > (b.t or 0)
	end)
	local ids, seen = {}, {}
	for _, e in entries do
		if #ids >= limit then
			break
		end
		if validId(e.id) and not seen[e.id] then
			seen[e.id] = true
			table.insert(ids, e.id)
		end
	end
	return ids
end

local function feed(player: Player, tab: any, userId: any): (boolean, string?, any)
	if not Net.allow(player, "CityGramFeed", 0.8) then
		return false, "Slow down.", nil
	end
	local size = MediaConfig.FEED_SIZE
	local ids: { string } = {}
	local sharedBy: { [string]: any } = {}
	if tab == "following" then
		local rec = getFollow(player.UserId)
		local entries = {}
		for _, e in recent do
			if rec.following[tostring(e.u)] then
				table.insert(entries, e)
			end
		end
		if #entries < size then
			-- top up from the most recently followed accounts' own lists
			local followed = {}
			for id, t in rec.following do
				table.insert(followed, { id = tonumber(id), t = t })
			end
			table.sort(followed, function(a, b)
				return a.t > b.t
			end)
			for i = 1, math.min(#followed, 15) do
				local uid = followed[i].id
				if uid then
					for j, e in userList(uid) do
						if j > 4 then
							break
						end
						table.insert(entries, { id = e.id, t = e.t })
					end
				end
			end
		end
		ids = newestFirst(entries, size)
	elseif tab == "popular" then
		ids = popularIds()
	elseif tab == "nearby" then
		local entries = {}
		for _, p in Players:GetPlayers() do
			for j, e in userList(p.UserId) do
				if j > 4 then
					break
				end
				table.insert(entries, e)
			end
		end
		ids = newestFirst(entries, size)
	elseif tab == "user" then
		if not validUserId(userId) then
			return false, "Unknown player.", nil
		end
		ids = newestFirst(table.clone(userList(userId, 30)), size)
	elseif tab == "inbox" then
		local s = sec(player)
		for _, e in (s and s.inbox or {}) do
			if #ids >= size * 2 then
				break
			end
			table.insert(ids, e.id)
			sharedBy[e.id] = e
		end
	else
		return false, "Unknown feed.", nil
	end
	local posts = {}
	for _, m in getMetas(ids) do
		if visible(player, m) then
			local v = view(player, m)
			local e = sharedBy[m.id]
			if e then
				v.sharedBy = e.n
			end
			table.insert(posts, v)
		end
	end
	return true, nil, { tab = tab, posts = posts }
end

---------------------------------------------------------------------------
-- Profile card data
---------------------------------------------------------------------------
local function profileData(viewer: Player, userId: any): any
	if not validUserId(userId) then
		return nil
	end
	local rec = getFollow(userId)
	local posts = {}
	local list = if hiddenFor(viewer, userId) then {} else userList(userId, 30)
	for i = 1, math.min(#list, 3) do
		posts[i] = list[i].id
	end
	local Media = optional("Media")
	local profilePhoto, photos = nil, {}
	if Media and not hiddenFor(viewer, userId) then
		local ok, id = pcall(Media.profilePhoto, userId)
		profilePhoto = if ok then id else nil
		local ok2, list2 = pcall(Media.publicPhotos, userId)
		if ok2 and type(list2) == "table" then
			for i = 1, math.min(#list2, 6) do
				photos[i] = list2[i]
			end
		end
	end
	return {
		followers = rec.fc,
		following = rec.gc,
		posts = posts,
		postCount = #list,
		isFollowing = userId ~= viewer.UserId and CityGram.isFollowing(viewer.UserId, userId),
		self = userId == viewer.UserId,
		profilePhoto = profilePhoto,
		photos = photos,
	}
end

local function followList(player: Player, userId: any, which: string): (boolean, string?, any)
	if not validUserId(userId) then
		return false, "Unknown player.", nil
	end
	local rec = getFollow(userId)
	local map = if which == "followers" then rec.followers else rec.following
	local entries = {}
	for id, t in map do
		local n = tonumber(id)
		if n and not hiddenFor(player, n) then
			table.insert(entries, { u = n, t = t })
		end
	end
	table.sort(entries, function(a, b)
		return a.t > b.t
	end)
	local ids = {}
	for i = 1, math.min(#entries, 60) do
		ids[i] = entries[i].u
	end
	local names = namesFor(ids)
	local out = {}
	for i, id in ids do
		out[i] = { u = id, n = names[id], online = Players:GetPlayerByUserId(id) ~= nil }
	end
	return true, nil, { list = out, total = if which == "followers" then rec.fc else rec.gc }
end

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local function handle(player: Player, action: any, a: any, b: any): (boolean, string?, any)
	if action == "feed" then
		return feed(player, a, b)
	elseif action == "post" then
		return createPost(player, a, b)
	elseif action == "like" then
		return like(player, a, true)
	elseif action == "unlike" then
		return like(player, a, false)
	elseif action == "comment" then
		return comment(player, a, b)
	elseif action == "follow" then
		local ok, msg = CityGram.follow(player, a)
		return ok, msg, nil
	elseif action == "unfollow" then
		local ok, msg = CityGram.unfollow(player, a)
		return ok, msg, nil
	end
	if not Net.allow(player, "CityGramRead", 0.1) then
		return false, "Slow down.", nil
	end
	if action == "comments" then
		local m = validId(a) and getMeta(a, 3)
		if not visible(player, m) then
			return false, "That post is gone.", nil
		end
		return true, nil, { post = view(player, m), comments = commentsFor(player, m) }
	elseif action == "view" then
		countView(player, a)
		return true, nil, nil
	elseif action == "snap" then
		local m = validId(a) and getMeta(a)
		if not visible(player, m) then
			return false, "That post is gone.", nil
		end
		local snap = getSnap(a)
		if not snap then
			return false, "That photo couldn't be loaded.", nil
		end
		return true, nil, snap
	elseif action == "share" then
		return share(player, a, b)
	elseif action == "delete" then
		return deletePost(player, a)
	elseif action == "followers" or action == "following" then
		return followList(player, a, action)
	elseif action == "myFollowing" then
		return true, nil, followingIds(player.UserId)
	elseif action == "post_get" then
		local m = validId(a) and getMeta(a)
		if not visible(player, m) then
			return false, "That post is gone.", nil
		end
		return true, nil, view(player, m)
	end
	return false, "Unknown action.", nil
end

function CityGram.start(_city: Instance?)
	local CityGramAction = Net.remote("RemoteFunction", "CityGramAction")
	local CityGramProfile = Net.remote("RemoteFunction", "CityGramProfile")
	CityGramEvent = Net.remote("RemoteEvent", "CityGramEvent")

	CityGramAction.OnServerInvoke = function(player: Player, action: any, a: any, b: any)
		local ok, success, message, data = pcall(handle, player, action, a, b)
		if not ok then
			warn("[CityGrind] CityGram action failed:", success)
			return false, "Something went wrong.", nil
		end
		return success, message, data
	end
	CityGramProfile.OnServerInvoke = function(player: Player, userId: any)
		if not Net.allow(player, "CityGramProfile", 0.3) then
			return nil
		end
		local ok, data = pcall(profileData, player, userId)
		return if ok then data else nil
	end

	-- Studio without API access: GetDataStore works but every request fails, so
	-- fall back to this server's memory instead of retrying (and failing) every action.
	if postStore.ds and game:GetService("RunService"):IsStudio() then
		task.spawn(function()
			local ok = pcall(function()
				(postStore.ds :: DataStore):GetAsync("probe")
			end)
			if not ok then
				postStore.ds = nil
				followStore.ds = nil
				table.clear(followCache)
			end
		end)
	end

	PlayerData.onLoaded(function(player: Player)
		local s = sec(player)
		if s then
			player:SetAttribute("CityGramPosts", s.posts)
		end
		getFollow(player.UserId, 0)
		mirrorCounts(player.UserId)
		settle(player)
		sendFollowing(player)
		userList(player.UserId, 0)
		if s and CityGramEvent then
			CityGramEvent:FireClient(player, "Inbox", #s.inbox)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		hourly[player] = nil
		settling[player] = nil
		followCache[player.UserId] = nil
		userLists[player.UserId] = nil
	end)

	-- cross-server: new posts, notifications and "you have pending stuff" pings
	task.spawn(function()
		pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function(message)
				local data = message.Data
				if type(data) ~= "table" then
					return
				end
				if data.k == "post" and validId(data.id) and validUserId(data.u) then
					rememberRecent({ id = data.id, u = data.u, t = tonumber(data.t) or os.time() })
					userLists[data.u] = nil
					popularCache = nil
				elseif data.k == "notify" and validUserId(data.to) then
					local p = Players:GetPlayerByUserId(data.to)
					if p and type(data.b) == "string" then
						Net.notify(p, tostring(data.ti or "CITYGRAM"):sub(1, 30), data.b:sub(1, 200))
					end
				elseif data.k == "settle" and validUserId(data.u) then
					followCache[data.u] = nil
					local p = Players:GetPlayerByUserId(data.u)
					if p then
						settle(p)
					end
				end
			end)
		end)
	end)

	task.spawn(function()
		refreshRecent()
		while true do
			task.wait(30)
			flushViews()
			refreshRecent()
		end
	end)
	game:BindToClose(function()
		flushViews()
		task.wait(2) -- let the batched view writes go out
	end)
end

return CityGram
