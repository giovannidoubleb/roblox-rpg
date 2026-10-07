-- CITY GRIND: Photo Challenge (city event kind, plugs into Events.registerKind).
-- A theme drops when it goes live. Entrants shoot with the phone Camera app
-- (every photo is a server-built SceneSnapshot, see Media.luau) and submit one
-- photo from their Gallery that was taken AFTER the challenge started (a photo
-- they also posted on CityGram is the same Gallery photo). The server checks the
-- theme against the saved snapshot itself: where the camera was (district), the
-- in-game clock, who is in frame, which vehicles are in frame. Then a voting
-- window: real players only (entrants and anyone watching), one vote each, never
-- for your own photo. Most votes wins; a tie goes to the earlier submission.
--
-- Saved: section "events".photoWins.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local DistrictsConfig = require(shared:WaitForChild("DistrictsConfig"))
local SceneSnapshot = require(shared:WaitForChild("SceneSnapshot"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local EventKit = require(script.Parent:WaitForChild("EventKit"))

local EventPhoto = {}

type Entry = { userId: number, name: string, photoId: string, snap: any, at: number, place: string, people: number }

local NEON = Enum.Material.Neon.Value

local function getMedia(): any
	local module = script.Parent:FindFirstChild("Media")
	if not module then
		return nil
	end
	local ok, M = pcall(require, module)
	return if ok then M else nil
end

-- Is in-game hour `h` inside [from, to) (which may wrap past midnight)?
local function inWindow(h: number, from: number, to: number): boolean
	if from <= to then
		return h >= from and h < to
	end
	return h >= from or h < to
end

-- In-game hours of [from, to) covered while the clock runs from `start` for `span` hours.
local function overlapHours(start: number, span: number, from: number, to: number): number
	local covered = 0
	local step = 0.1
	local h = 0
	while h < span do
		if inWindow((start + h) % 24, from, to) then
			covered += step
		end
		h += step
	end
	return covered
end

function EventPhoto.init(ctx: any): any
	local EC = ctx.EC
	local P = EC.PHOTO
	local now = ctx.now
	local lastTheme: string? = nil

	---------------------------------------------------------------------------
	-- Theme checks against the snapshot the server built
	---------------------------------------------------------------------------
	local function cameraPos(snap: any): Vector3?
		if type(snap) ~= "table" or type(snap.c) ~= "table" then
			return nil
		end
		local ok, cf = pcall(SceneSnapshot.arrToCf, snap.c)
		return if ok then cf.Position else nil
	end

	local function hasUnderglow(snap: any): boolean
		for _, v in (if type(snap.h) == "table" then snap.h else {}) do
			for _, a in (if type(v) == "table" and type(v.b) == "table" then v.b else {}) do
				if type(a) == "table" and a[12] == NEON and type(a[2]) == "number" and type(a[3]) == "number" and type(a[4]) == "number" then
					local dims = { a[2], a[3], a[4] }
					table.sort(dims)
					-- a flat glowing plate under the car, not a headlight
					if dims[1] <= 0.35 and dims[2] * dims[3] >= 4 then
						return true
					end
				end
			end
		end
		return false
	end

	local function nearCourt(snap: any): boolean
		local courts = {}
		for _, m in CollectionService:GetTagged("Court") do
			if m:IsA("Model") then
				table.insert(courts, ctx.courtCenter(m))
			end
		end
		for _, person in (if type(snap.p) == "table" then snap.p else {}) do
			if type(person) == "table" and type(person.r) == "table" then
				local ok, cf = pcall(SceneSnapshot.arrToCf, person.r)
				if ok then
					for _, c in courts do
						if (cf.Position - c).Magnitude <= 40 then
							return true
						end
					end
				end
			end
		end
		return false
	end

	local function matches(theme: any, snap: any): (boolean, string?)
		local cam = cameraPos(snap)
		if not cam then
			return false, "That photo can't be read."
		end
		local clock = if type(snap.k) == "number" then snap.k else -1
		local people = if type(snap.p) == "table" then #snap.p else 0
		if theme.id == "sunset" then
			if DistrictsConfig.at(cam) ~= "Beach" then
				return false, "That wasn't taken at the Beach."
			end
			if not inWindow(clock, theme.clockFrom, theme.clockTo) then
				return false, "Wrong time of day: shoot between 16:30 and 20:00."
			end
		elseif theme.id == "night" then
			if DistrictsConfig.at(cam) ~= "Downtown" then
				return false, "That wasn't taken Downtown."
			end
			if not inWindow(clock, theme.clockFrom, theme.clockTo) then
				return false, "It has to be night (19:00-05:30)."
			end
		elseif theme.id == "crew" then
			if people < 3 then
				return false, string.format("Only %d %s in frame; you need 3+.", people, if people == 1 then "person" else "people")
			end
		elseif theme.id == "neon" then
			if not hasUnderglow(snap) then
				return false, "No car with its underglow on is in that photo."
			end
		elseif theme.id == "hoops" then
			if not nearCourt(snap) then
				return false, "Nobody in that photo is at a basketball court."
			end
		end
		return true, nil
	end

	-- Themes that can actually be shot in the next SHOOT seconds.
	local function pickTheme(): any
		local hoursPerSecond = 24 / P.DAY_SECONDS
		local span = P.SHOOT * hoursPerSecond
		local clock = Lighting.ClockTime
		local options = {}
		for _, theme in P.THEMES do
			local ok = true
			if theme.clockFrom then
				ok = overlapHours(clock, span, theme.clockFrom, theme.clockTo) >= P.MIN_WINDOW_HOURS
			end
			if ok and theme.id ~= lastTheme then
				table.insert(options, theme)
			end
		end
		if #options == 0 then
			for _, theme in P.THEMES do
				if not theme.clockFrom then
					table.insert(options, theme)
				end
			end
		end
		local theme = options[ctx.rng:NextInteger(1, #options)]
		lastTheme = theme.id
		return theme
	end

	---------------------------------------------------------------------------
	-- Helpers
	---------------------------------------------------------------------------
	local function entryCount(d: any): number
		local n = 0
		for _ in d.entries do
			n += 1
		end
		return n
	end

	local function eligiblePhotos(d: any, p: Player): { any }
		local sec = PlayerData.section(p, "media")
		local list = {}
		if sec and type(sec.photos) == "table" then
			for _, meta in sec.photos do
				if type(meta) == "table" and type(meta.t) == "number" and meta.t >= d.shootFrom then
					table.insert(list, { id = meta.id, l = meta.l, n = meta.n, t = meta.t })
					if #list >= P.MAX_PHOTOS_LISTED then
						break
					end
				end
			end
		end
		return list
	end

	local function sortedEntries(d: any, tally: { [number]: number }?): { Entry }
		local list: { Entry } = {}
		for _, e in d.entries do
			table.insert(list, e)
		end
		table.sort(list, function(a: Entry, b: Entry)
			if tally then
				local va, vb = tally[a.userId] or 0, tally[b.userId] or 0
				if va ~= vb then
					return va > vb
				end
			end
			return a.at < b.at
		end)
		return list
	end

	local function finish(ev: any)
		local d = ev.data
		local tally = EventKit.tally(d.box)
		local list = sortedEntries(d, tally)
		local lines = {}
		local place = 0
		for i, e in list do
			local votes = tally[e.userId] or 0
			if i <= 5 then
				table.insert(lines, string.format("%d. %s — %d vote%s · %s", i, e.name, votes, if votes == 1 then "" else "s", e.place))
			end
			local p = Players:GetPlayerByUserId(e.userId)
			if p and ctx.isRegistered(ev, p) then
				place += 1
				ctx.payPlace(ev, p, place, #list, votes > 0)
				if place == 1 and votes > 0 then
					local sec = ctx.section(p)
					if sec then
						sec.photoWins = (sec.photoWins or 0) + 1
						PlayerData.markChanged(p)
					end
					PlayerData.addFame(p, 10)
				end
			end
		end
		table.insert(lines, string.format("Theme: %s · %d vote%s cast", d.theme.name, EventKit.voteCount(d.box), if EventKit.voteCount(d.box) == 1 then "" else "s"))
		local top = list[1]
		local winner = if top and (tally[top.userId] or 0) > 0 then top.name else nil
		ctx.pushResult(ev, lines, winner)
		if winner then
			ctx.announce(ctx.audience(ev), winner:upper() .. " WINS THE PHOTO CHALLENGE")
		end
		ctx.closeEvent(ev)
	end

	---------------------------------------------------------------------------
	-- Handlers
	---------------------------------------------------------------------------
	local handlers = {}
	handlers.tip = "The theme drops at the start. Shoot with the Camera app, then tap SUBMIT in the event panel."

	function handlers.available(): boolean
		return getMedia() ~= nil
	end

	function handlers.pickVenue(): (Vector3, string?, any)
		local d = DistrictsConfig.get("Neighborhood")
		return if d then d.center else Vector3.zero, "Anywhere in the city", nil
	end

	function handlers.goLive(ev: any): (string, string?)
		local theme = pickTheme()
		ev.data = {
			theme = theme,
			shootFrom = os.time() - 1,
			entries = {} :: { [number]: Entry },
			box = EventKit.newVotes(),
			entrants = 0,
		}
		-- sign-ups stay open while people shoot ("Checkin" keeps joining allowed)
		ev.state = "Checkin"
		ev.phase = "Shoot: " .. theme.name
		ev.phaseEndsAt = now() + P.SHOOT
		ev.location = "Anywhere · theme: " .. theme.name
		for _, p in Players:GetPlayers() do
			ctx.notify(p, "📸 PHOTO CHALLENGE THEME", string.format("\"%s\" — %s. Join in the Events app.", theme.name, theme.rule))
		end
		return "live", nil
	end

	function handlers.tick(ev: any)
		local d = ev.data
		local t = now()
		-- entries from players who left no longer count
		for userId in d.entries do
			local p = Players:GetPlayerByUserId(userId)
			if not p or not ctx.isRegistered(ev, p) then
				d.entries[userId] = nil
				ctx.markDirty()
			end
		end
		if ev.state == "Checkin" then
			if t < ev.phaseEndsAt then
				return
			end
			d.entrants = entryCount(d)
			if d.entrants < ctx.minEntrants(ev.kind) then
				ctx.cancelEvent(ev, string.format("Only %d matching photo%s came in; a vote needs %d.", d.entrants, if d.entrants == 1 then "" else "s", ctx.minEntrants(ev.kind)))
				return
			end
			ev.state = "Voting"
			ev.phase = "Voting"
			ev.phaseEndsAt = t + P.VOTE
			for _, p in Players:GetPlayers() do
				ctx.notify(p, "📸 PHOTO VOTE OPEN", string.format("%d photos for \"%s\". Open Events > Live > WATCH to vote (not for your own).", d.entrants, d.theme.name))
			end
			ctx.markDirty()
			return
		end
		-- Voting
		if entryCount(d) < ctx.minEntrants(ev.kind) then
			ctx.cancelEvent(ev, "Too many photographers left before the vote finished.")
			return
		end
		if t >= ev.phaseEndsAt then
			finish(ev)
		end
	end

	function handlers.live(ev: any, viewer: Player): any
		local d = ev.data
		local lines = {
			string.format("Theme: %s", d.theme.name),
			"Rule: " .. d.theme.rule,
		}
		local status
		local mine: Entry? = d.entries[viewer.UserId]
		local out: any = { lines = lines, endsAt = ev.phaseEndsAt }
		if ev.state == "Checkin" then
			table.insert(lines, string.format("%d photo%s submitted · %d photographers", entryCount(d), if entryCount(d) == 1 then "" else "s", #ev.registered))
			if ctx.isRegistered(ev, viewer) then
				status = if mine then string.format("Submitted ✓ (%s). You can swap it until the timer ends.", mine.place) else "Snap a photo with the Camera app, then SUBMIT it."
				out.submit = {
					title = "Submit for \"" .. d.theme.name .. "\"",
					note = "Only photos taken after the challenge started. " .. d.theme.rule .. ".",
					photos = eligiblePhotos(d, viewer),
					current = if mine then mine.photoId else nil,
				}
			else
				status = "Photographers are out shooting"
			end
		else
			local voted = d.box.votes[viewer.UserId]
			table.insert(lines, string.format("%d photos · %d vote%s cast", entryCount(d), EventKit.voteCount(d.box), if EventKit.voteCount(d.box) == 1 then "" else "s"))
			local entries = {}
			for _, e in sortedEntries(d, nil) do
				table.insert(entries, {
					key = e.userId,
					name = e.name,
					detail = string.format("%s · %d in frame", e.place, e.people),
					mine = e.userId == viewer.UserId,
					photo = true,
				})
			end
			out.ballot = {
				title = "📸 " .. d.theme.name,
				note = "One vote each. You can't vote for your own photo. Tap a photo to view it.",
				entries = entries,
				voted = voted,
				canVote = voted == nil,
				endsAt = ev.phaseEndsAt,
			}
			status = if voted then "Vote locked in ✓" else "Voting is open: tap VOTE"
		end
		out.status = status
		return out
	end

	function handlers.request(ev: any, player: Player, action: string, b: any, _c: any): any
		local d = ev.data
		if action == "Submit" then
			if ev.state ~= "Checkin" then
				return { ok = false, msg = "Submissions are closed." }
			end
			if not ctx.isRegistered(ev, player) then
				return { ok = false, msg = "Join the Photo Challenge first." }
			end
			if type(b) ~= "string" or #b > 40 then
				return { ok = false, msg = "Pick a photo." }
			end
			local Media = getMedia()
			if not Media or not Media.ownsPhoto(player, b) then
				return { ok = false, msg = "That photo isn't in your Gallery." }
			end
			local record = Media.getPhoto(b)
			if type(record) ~= "table" or record.o ~= player.UserId or type(record.s) ~= "table" then
				return { ok = false, msg = "Couldn't load that photo. Try again." }
			end
			if type(record.t) ~= "number" or record.t < d.shootFrom then
				return { ok = false, msg = "That photo was taken before the challenge started." }
			end
			if ev.state ~= "Checkin" or not ctx.isRegistered(ev, player) then
				return { ok = false, msg = "Submissions are closed." }
			end
			local ok, why = matches(d.theme, record.s)
			if not ok then
				return { ok = false, msg = "Doesn't fit the theme: " .. (why or "") }
			end
			local people = if type(record.s.p) == "table" then #record.s.p else 0
			local previous = d.entries[player.UserId]
			d.entries[player.UserId] = {
				userId = player.UserId,
				name = player.DisplayName,
				photoId = b,
				snap = record.s,
				at = if previous then previous.at else now(),
				place = if type(record.s.l) == "string" then record.s.l else "the city",
				people = people,
			}
			ctx.markDirty()
			return { ok = true, msg = if previous then "Entry swapped. Good luck!" else "Photo submitted. Good luck!" }
		elseif action == "Entry" then
			if type(b) ~= "number" then
				return { ok = false, msg = "Bad request." }
			end
			local e: Entry? = d.entries[b]
			if not e then
				return { ok = false, msg = "That entry is gone." }
			end
			if ev.state ~= "Voting" and b ~= player.UserId then
				return { ok = false, msg = "Photos are shown when voting opens." }
			end
			return { ok = true, snap = e.snap, name = e.name, place = e.place }
		elseif action == "Vote" then
			if ev.state ~= "Voting" then
				return { ok = false, msg = "Voting isn't open." }
			end
			if not ctx.isRegistered(ev, player) and not ev.watchers[player] then
				return { ok = false, msg = "Tap WATCH on the challenge to vote." }
			end
			local ok, msg = EventKit.castVote(d.box, player, b, function(userId: number): boolean
				return d.entries[userId] ~= nil
			end)
			if ok then
				ctx.markDirty()
			end
			return { ok = ok, msg = msg, voted = d.box.votes[player.UserId] }
		end
		return { ok = false, msg = "Nothing to do here right now." }
	end

	function handlers.leave(ev: any, p: Player)
		ev.data.entries[p.UserId] = nil
	end

	return handlers
end

return EventPhoto
