-- CITY GRIND: Treasure Hunt (city event kind, plugs into Events.registerKind).
-- The server hides HUNT.CACHES glowing caches on open ground spread over the
-- districts (raycast + empty-box checks, so never inside a building). Caches
-- appear one by one with a district clue, then a landmark hint, then a compass
-- bearing (and a light pillar). The first registered hunter to physically reach
-- a cache (server distance check every tick) claims it. Most caches wins; ties go
-- to whoever got their last cache first. Everything is removed afterwards.
--
-- Saved: section "events".caches (lifetime caches found).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DistrictsConfig = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("DistrictsConfig"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local AntiCheat = require(script.Parent:WaitForChild("AntiCheat"))
local EventKit = require(script.Parent:WaitForChild("EventKit"))

local EventHunt = {}

type Cache = {
	index: number,
	district: string,
	pos: Vector3,
	model: Model,
	core: BasePart,
	revealAt: number,
	landmarkAt: number,
	bearingAt: number,
	landmarkText: string,
	bearingText: string,
	visible: boolean,
	pillar: boolean,
	claimedBy: string?,
}
type Hunter = { player: Player, name: string, found: number, lastAt: number }

local GOLD = Color3.fromRGB(255, 205, 60)

function EventHunt.init(ctx: any): any
	local EC = ctx.EC
	local H = EC.HUNT
	local now = ctx.now

	local function blocked(pos: Vector3): boolean
		-- keep caches out of gated / non-public court areas (the Hills private club)
		for _, m in game:GetService("CollectionService"):GetTagged("Court") do
			if m:IsA("Model") and not ctx.publicCourt(m) and ctx.flatDist(ctx.courtCenter(m), pos) < 70 then
				return true
			end
		end
		return false
	end

	local function hints(pos: Vector3, districtId: string): (string, string)
		local name, offset = EventKit.landmark(pos, 260)
		local districtName = DistrictsConfig.displayName(districtId)
		if name and offset then
			local dist = offset.Magnitude
			local landmarkText = string.format("near %s", name)
			local bearingText = if dist < 12
				then string.format("right by %s", name)
				else string.format("%d studs %s of %s", math.floor(dist / 5 + 0.5) * 5, EventKit.compass(offset), name)
			return landmarkText, bearingText
		end
		local d = DistrictsConfig.get(districtId)
		local offset2 = if d then ctx.flat(pos - d.center) else Vector3.zero
		local part = if offset2.Magnitude > 40 then EventKit.compass(offset2) .. " side of " .. districtName else "middle of " .. districtName
		return "in the " .. part, string.format("%d studs %s of the %s centre", math.floor(offset2.Magnitude / 5 + 0.5) * 5, EventKit.compass(offset2), districtName)
	end

	local function makeCache(folder: Instance, index: number, pos: Vector3): (Model, BasePart)
		local m = Instance.new("Model")
		m.Name = "Cache" .. index
		m.Parent = folder
		local base = ctx.part({
			name = "Chest",
			size = Vector3.new(2.6, 1.6, 1.8),
			cframe = CFrame.new(pos + Vector3.new(0, 0.8, 0)),
			color = Color3.fromRGB(110, 70, 35),
			material = Enum.Material.Wood,
			collide = false,
			parent = m,
		})
		base.Transparency = 1
		local core = ctx.part({
			name = "Glow",
			size = Vector3.one * 1.3,
			cframe = CFrame.new(pos + Vector3.new(0, 2.3, 0)),
			color = GOLD,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Ball,
			collide = false,
			parent = m,
		})
		core.Transparency = 1
		local light = Instance.new("PointLight")
		light.Color = GOLD
		light.Range = 14
		light.Brightness = 2
		light.Enabled = false
		light.Parent = core
		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Color = ColorSequence.new(GOLD)
		sparkle.LightEmission = 1
		sparkle.Size = NumberSequence.new(0.35, 0)
		sparkle.Lifetime = NumberRange.new(0.8, 1.4)
		sparkle.Speed = NumberRange.new(1.5, 3)
		sparkle.SpreadAngle = Vector2.new(180, 180)
		sparkle.Rate = 12
		sparkle.Enabled = false
		sparkle.Parent = core
		m.PrimaryPart = core
		return m, core
	end

	local function show(cache: Cache)
		cache.visible = true
		for _, d in cache.model:GetDescendants() do
			if d:IsA("BasePart") and d.Name ~= "Pillar" then
				d.Transparency = 0
			elseif d:IsA("PointLight") or d:IsA("ParticleEmitter") then
				d.Enabled = true
			end
		end
	end

	local function addPillar(cache: Cache)
		cache.pillar = true
		local pillar = ctx.part({
			name = "Pillar",
			size = Vector3.new(160, 1.6, 1.6),
			cframe = CFrame.new(cache.pos + Vector3.new(0, 82, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			color = GOLD,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
			collide = false,
			parent = cache.model,
		})
		pillar.Transparency = 0.55
	end

	-- Spreads the caches over the districts (round robin, shuffled), falling
	-- back to known open ground.
	local function placeCaches(folder: Folder, startAt: number): { Cache }
		local districts = table.clone(DistrictsConfig.LIST)
		for i = #districts, 2, -1 do
			local j = ctx.rng:NextInteger(1, i)
			districts[i], districts[j] = districts[j], districts[i]
		end
		local used: { Vector3 } = {}
		local caches: { Cache } = {}
		local fallback = table.clone(H.FALLBACK)
		for i = 1, H.CACHES do
			local d = districts[(i - 1) % #districts + 1]
			local pos: Vector3? = nil
			for _ = 1, 4 do
				local g = EventKit.randomSpot(ctx.rng, d.center, d.size, Vector3.new(4, 6, 4), 12, used, H.MIN_SPACING, { ctx.root })
				if g and not blocked(g) then
					pos = g
					break
				end
			end
			while not pos and #fallback > 0 do
				local f = table.remove(fallback, ctx.rng:NextInteger(1, #fallback)) :: Vector3
				local g = EventKit.groundAt(f, { ctx.root })
				pos = g or Vector3.new(f.X, 0.3, f.Z)
			end
			if not pos then
				break
			end
			local p = pos :: Vector3
			table.insert(used, p)
			local districtId = DistrictsConfig.at(p)
			local landmarkText, bearingText = hints(p, districtId)
			local model, core = makeCache(folder, i, p)
			local revealAt = startAt + (i - 1) * H.CLUE_EVERY
			table.insert(caches, {
				index = i,
				district = districtId,
				pos = p,
				model = model,
				core = core,
				revealAt = revealAt,
				landmarkAt = revealAt + H.LANDMARK_AFTER,
				bearingAt = revealAt + H.BEARING_AFTER,
				landmarkText = landmarkText,
				bearingText = bearingText,
				visible = false,
				pillar = false,
				claimedBy = nil,
			})
		end
		return caches
	end

	local function finish(ev: any)
		local d = ev.data
		local list: { Hunter } = {}
		for _, h in d.hunters do
			table.insert(list, h)
		end
		table.sort(list, function(a: Hunter, b: Hunter)
			if a.found ~= b.found then
				return a.found > b.found
			end
			return a.lastAt < b.lastAt
		end)
		local lines = {}
		local place = 0
		for i, h in list do
			if i <= 5 then
				table.insert(lines, string.format("%d. %s — %d cache%s", i, h.name, h.found, if h.found == 1 then "" else "s"))
			end
			local p = h.player
			if p.Parent and ctx.isRegistered(ev, p) then
				if h.found > 0 then
					place += 1
					PlayerData.addStatXP(p, "Stamina", 15)
					ctx.payPlace(ev, p, place, d.entrants, true)
				else
					ctx.notify(p, "TREASURE HUNT OVER", "You didn't reach a cache this time. Clues get sharper the longer a cache stays hidden.")
				end
			end
		end
		local unclaimed = 0
		for _, c in d.caches do
			if not c.claimedBy then
				unclaimed += 1
			end
		end
		if unclaimed > 0 then
			table.insert(lines, string.format("%d cache%s never found", unclaimed, if unclaimed == 1 then " was" else "s were"))
		end
		local winner = list[1] and list[1].found > 0 and list[1].name or nil
		ctx.pushResult(ev, lines, winner)
		if winner then
			ctx.announce(ctx.audience(ev), winner:upper() .. " WINS THE TREASURE HUNT")
		end
		ctx.closeEvent(ev)
	end

	local handlers = {}
	handlers.tip = "Clues appear in the live panel. Any vehicle or the subway is fair game."

	function handlers.pickVenue(): (Vector3, string?, any)
		local d = DistrictsConfig.get("Neighborhood")
		return if d then d.center else Vector3.zero, "All over the city", nil
	end

	function handlers.goLive(ev: any): (string, string?)
		local folder = Instance.new("Folder")
		folder.Name = "TreasureHunt"
		folder.Parent = ctx.root
		local startAt = now() + H.CHECKIN
		local caches = placeCaches(folder, startAt)
		if #caches == 0 then
			folder:Destroy()
			return "cancel", "No open ground for the caches."
		end
		ev.data = {
			folder = folder,
			caches = caches,
			hunters = {} :: { [Player]: Hunter },
			startAt = startAt,
			endsAt = startAt + H.TIME_LIMIT,
			entrants = 0,
			feed = {} :: { string },
		}
		ev.state = "Checkin"
		ev.phase = "Sign-ups: first clue soon"
		ev.phaseEndsAt = startAt
		return "live", nil
	end

	function handlers.tick(ev: any)
		local d = ev.data
		local t = now()
		if ev.state == "Checkin" then
			if t < ev.phaseEndsAt then
				return
			end
			for _, p in ev.registered do
				if p.Parent then
					d.hunters[p] = { player = p, name = p.DisplayName, found = 0, lastAt = math.huge }
					d.entrants += 1
				end
			end
			if d.entrants < ctx.minEntrants(ev.kind) then
				ctx.cancelEvent(ev, "Nobody signed up to hunt.")
				return
			end
			ev.state = "Running"
			ev.phase = "Hunting"
			ev.phaseEndsAt = d.endsAt
			ctx.announce(ev.registered, "THE HUNT IS ON!")
			ctx.markDirty()
			return
		end

		-- reveal stages
		local left = 0
		for _, c in d.caches do
			if not c.claimedBy then
				left += 1
				if not c.visible and t >= c.revealAt then
					show(c)
					for _, p in ev.registered do
						ctx.notify(p, "🗝️ NEW CLUE", string.format("Cache #%d is somewhere in %s.", c.index, DistrictsConfig.displayName(c.district)))
					end
					ctx.markDirty()
				end
				if c.visible and not c.pillar and t >= c.bearingAt then
					addPillar(c)
				end
			end
		end

		-- touches: first registered hunter in reach claims it
		for _, c in d.caches do
			if c.visible and not c.claimedBy then
				local best: Player? = nil
				local bestDist = H.TOUCH_RADIUS
				for p in d.hunters do
					local r = ctx.rootOf(p)
					local hum = ctx.humanoidOf(p)
					-- [Security] a character that just jumped further than it could run can't claim
					if r and hum and hum.Health > 0 and p.Parent and ctx.isRegistered(ev, p) and AntiCheat.positionOk(p) then
						local dist = ctx.flatDist(r.Position, c.pos)
						if dist <= bestDist and math.abs(r.Position.Y - c.pos.Y) < 9 then
							best, bestDist = p, dist
						end
					end
				end
				if best then
					local h = d.hunters[best]
					h.found += 1
					h.lastAt = t
					c.claimedBy = h.name
					left -= 1
					c.model:Destroy()
					local sec = ctx.section(best)
					if sec then
						sec.caches = (sec.caches or 0) + 1
						PlayerData.markChanged(best)
					end
					ctx.announce({ best }, string.format("CACHE #%d FOUND!", c.index))
					local msg = string.format("%s found cache #%d in %s.", h.name, c.index, DistrictsConfig.displayName(c.district))
					table.insert(d.feed, 1, msg)
					for _, p in ctx.audience(ev) do
						if p ~= best then
							ctx.notify(p, "🗝️ CACHE CLAIMED", msg)
						end
					end
					ctx.markDirty()
				end
			end
		end

		local anyone = false
		for p in d.hunters do
			if p.Parent and ctx.isRegistered(ev, p) then
				anyone = true
			end
		end
		if not anyone then
			ctx.cancelEvent(ev, "Every hunter left.")
			return
		end
		if left <= 0 or t >= d.endsAt then
			finish(ev)
		end
	end

	function handlers.live(ev: any, viewer: Player): any
		local d = ev.data
		local t = now()
		local lines = {}
		local status
		if ev.state == "Checkin" then
			table.insert(lines, string.format("%d hunter%s signed up · %d caches hidden", #ev.registered, if #ev.registered == 1 then "" else "s", #d.caches))
			table.insert(lines, "A new clue drops every " .. H.CLUE_EVERY .. "s. Clues sharpen over time.")
			status = if ctx.isRegistered(ev, viewer) then "Get moving: the first clue drops soon!" else "Sign-ups are open"
		else
			for _, c in d.caches do
				if c.claimedBy then
					table.insert(lines, string.format("#%d ✓ %s · found by %s", c.index, DistrictsConfig.displayName(c.district), c.claimedBy))
				elseif t < c.revealAt then
					table.insert(lines, string.format("#%d clue in %s", c.index, EC.formatIn(c.revealAt - t)))
				elseif t >= c.bearingAt then
					table.insert(lines, string.format("#%d %s · %s (look for the light pillar)", c.index, DistrictsConfig.displayName(c.district), c.bearingText))
				elseif t >= c.landmarkAt then
					table.insert(lines, string.format("#%d %s · %s", c.index, DistrictsConfig.displayName(c.district), c.landmarkText))
				else
					table.insert(lines, string.format("#%d somewhere in %s · more in %s", c.index, DistrictsConfig.displayName(c.district), EC.formatIn(c.landmarkAt - t)))
				end
			end
			local me = d.hunters[viewer]
			if me and ctx.isRegistered(ev, viewer) then
				local rank = 1
				for _, h in d.hunters do
					if h.found > me.found or (h.found == me.found and h.lastAt < me.lastAt) then
						rank += 1
					end
				end
				status = string.format("You've found %d · rank %d", me.found, rank)
			else
				status = if d.feed[1] then d.feed[1] else "Watching the hunt"
			end
		end
		return {
			lines = lines,
			status = status,
			endsAt = ev.phaseEndsAt,
		}
	end

	function handlers.cleanup(ev: any)
		local d = ev.data
		if d and d.folder then
			d.folder:Destroy()
		end
	end

	return handlers
end

return EventHunt
