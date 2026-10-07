-- CITY GRIND: Fashion Show (city event kind, plugs into Events.registerKind).
-- A pop-up runway is built on open ground (checked with raycasts / empty-box
-- tests, falling back through EC.FASHION.SPOTS). Entrants check in at the
-- runway wearing a Closet outfit (the Shops wardrobe, not the Roblox-avatar
-- toggle), then walk one at a time: reach the end of the runway in time and
-- hold the pose. The outfit shown on the ballot is read from the server-side
-- wardrobe when the walk starts. Then the crowd votes: entrants plus anyone
-- standing at the runway, one vote each, never for yourself. Most votes wins;
-- a tie goes to whoever walked first.
--
-- Saved: section "events".fashionWins.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local ShopsConfig = require(shared:WaitForChild("ShopsConfig"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local AntiCheat = require(script.Parent:WaitForChild("AntiCheat"))
local EventKit = require(script.Parent:WaitForChild("EventKit"))

local EventFashion = {}

type Model_ = { userId: number, player: Player, name: string, outfit: string, pieces: number, order: number, walked: boolean }
type Walk = { entry: Model_, startedAt: number, endsAt: number, reachedAt: number?, offSince: number? }

local PINK = Color3.fromRGB(255, 110, 200)

-- "Black Block Hoodie · Dark Wash Baggy Jeans · ..." from the saved wardrobe.
local function describeOutfit(player: Player): (string?, number)
	local w = PlayerData.section(player, "wardrobe")
	if not w then
		return nil, 0
	end
	if w.useRobloxAvatar then
		return nil, 0
	end
	local bits = {}
	for _, slot in ShopsConfig.SLOTS do
		local id = w.equipped and w.equipped[slot]
		local item = type(id) == "string" and ShopsConfig.ITEMS[id]
		if item then
			local idx = (w.colours and w.colours[slot]) or 1
			local variant = item.variants[idx] or item.variants[1]
			table.insert(bits, (if variant and #item.variants > 1 then variant.name .. " " else "") .. item.name)
		end
	end
	if #bits == 0 then
		return nil, 0
	end
	return table.concat(bits, " · "), #bits
end

function EventFashion.init(ctx: any): any
	local EC = ctx.EC
	local F = EC.FASHION
	local now = ctx.now
	local RUNWAY: Vector3 = F.RUNWAY
	local FOOTPRINT = Vector3.new(RUNWAY.X + 24, 8, RUNWAY.Z + 16)

	local function findSpot(first: Vector3?): Vector3?
		local list = {}
		if first then
			table.insert(list, first)
		end
		for _, s in F.SPOTS do
			table.insert(list, s)
		end
		return EventKit.openSpot(list, FOOTPRINT, { ctx.root })
	end

	---------------------------------------------------------------------------
	-- Venue: runway along +z, the walk starts at the backdrop (-z end)
	---------------------------------------------------------------------------
	local function build(ground: Vector3): any
		local folder = Instance.new("Folder")
		folder.Name = "FashionShow"
		folder.Parent = ctx.root
		local topY = ground.Y + RUNWAY.Y
		local center = Vector3.new(ground.X, ground.Y + RUNWAY.Y / 2, ground.Z)
		ctx.part({ name = "Runway", size = RUNWAY, cframe = CFrame.new(center), color = Color3.fromRGB(245, 245, 250), material = Enum.Material.SmoothPlastic, parent = folder })
		for _, s in { -1, 1 } do
			ctx.part({
				name = "EdgeGlow",
				size = Vector3.new(0.3, 0.2, RUNWAY.Z),
				cframe = CFrame.new(center + Vector3.new(s * (RUNWAY.X / 2 - 0.15), RUNWAY.Y / 2 + 0.1, 0)),
				color = PINK,
				material = Enum.Material.Neon,
				collide = false,
				parent = folder,
			})
			-- low stands for the crowd along both sides
			for row = 1, 2 do
				ctx.part({
					name = "Stand",
					size = Vector3.new(3, row * 1.2, RUNWAY.Z - 10),
					cframe = CFrame.new(Vector3.new(ground.X + s * (RUNWAY.X / 2 + 4 + row * 3), ground.Y + row * 0.6, ground.Z + 3)),
					color = Color3.fromRGB(40, 40, 48),
					material = Enum.Material.Metal,
					parent = folder,
				})
			end
		end
		-- steps up at the start end
		local startZ = ground.Z - RUNWAY.Z / 2
		ctx.part({ name = "Step", size = Vector3.new(RUNWAY.X, RUNWAY.Y / 2, 3), cframe = CFrame.new(Vector3.new(ground.X, ground.Y + RUNWAY.Y / 4, startZ - 1.5)), color = Color3.fromRGB(220, 220, 228), parent = folder })
		-- backdrop + sign
		local back = ctx.part({
			name = "Backdrop",
			size = Vector3.new(RUNWAY.X + 10, 14, 0.8),
			cframe = CFrame.new(Vector3.new(ground.X, ground.Y + 7, startZ - 4.5)),
			color = Color3.fromRGB(20, 18, 26),
			parent = folder,
		})
		ctx.surfaceText(back, Enum.NormalId.Back, "CITY GRIND\nFASHION SHOW", PINK, 20)
		ctx.surfaceText(back, Enum.NormalId.Front, "👗 FASHION SHOW", PINK, 20)
		local endMark = ctx.part({
			name = "PoseMark",
			size = Vector3.new(0.1, 5, 5),
			cframe = CFrame.new(Vector3.new(ground.X, topY + 0.06, ground.Z + RUNWAY.Z / 2 - 3.5)) * CFrame.Angles(0, 0, math.pi / 2),
			color = PINK,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
			collide = false,
			parent = folder,
		})
		for _, s in { -1, 1 } do
			local lamp = ctx.part({
				name = "Spot",
				size = Vector3.new(1, 1, 1),
				cframe = CFrame.new(Vector3.new(ground.X + s * (RUNWAY.X / 2 + 2), topY + 9, ground.Z + RUNWAY.Z / 2 - 3)),
				color = Color3.fromRGB(255, 240, 250),
				material = Enum.Material.Neon,
				collide = false,
				parent = folder,
			})
			local light = Instance.new("SpotLight")
			light.Face = Enum.NormalId.Bottom
			light.Range = 18
			light.Angle = 70
			light.Brightness = 3
			light.Color = Color3.fromRGB(255, 220, 240)
			light.Parent = lamp
		end
		return {
			folder = folder,
			ground = ground,
			topY = topY,
			startPos = Vector3.new(ground.X, topY + 3, startZ + 3),
			endPos = endMark.Position,
			center = center,
		}
	end

	local function onRunway(d: any, p: Player): boolean
		local r = ctx.rootOf(p)
		if not r then
			return false
		end
		local o = r.Position - d.venue.center
		return math.abs(o.X) <= RUNWAY.X / 2 + 0.5 and math.abs(o.Z) <= RUNWAY.Z / 2 + 0.5 and r.Position.Y > d.venue.topY and r.Position.Y < d.venue.topY + 8
	end

	local function nearRunway(d: any, p: Player, range: number): boolean
		local r = ctx.rootOf(p)
		return r ~= nil and ctx.flatDist(r.Position, d.venue.center) <= range and math.abs(r.Position.Y - d.venue.topY) < 25
	end

	---------------------------------------------------------------------------
	-- Results
	---------------------------------------------------------------------------
	local function candidates(d: any): { Model_ }
		local list = {}
		for _, e in d.models do
			if e.walked then
				table.insert(list, e)
			end
		end
		return list
	end

	local function finish(ev: any)
		local d = ev.data
		local tally = EventKit.tally(d.box)
		local list = candidates(d)
		table.sort(list, function(a: Model_, b: Model_)
			local va, vb = tally[a.userId] or 0, tally[b.userId] or 0
			if va ~= vb then
				return va > vb
			end
			return a.order < b.order
		end)
		local lines = {}
		local place = 0
		for i, e in list do
			local votes = tally[e.userId] or 0
			if i <= 5 then
				table.insert(lines, string.format("%d. %s — %d vote%s", i, e.name, votes, if votes == 1 then "" else "s"))
			end
			local p = e.player
			if p.Parent and ctx.isRegistered(ev, p) then
				place += 1
				ctx.payPlace(ev, p, place, #list, votes > 0)
				if place == 1 and votes > 0 then
					local sec = ctx.section(p)
					if sec then
						sec.fashionWins = (sec.fashionWins or 0) + 1
						PlayerData.markChanged(p)
					end
					PlayerData.addFame(p, 10)
				end
			end
		end
		table.insert(lines, string.format("%d vote%s from the crowd", EventKit.voteCount(d.box), if EventKit.voteCount(d.box) == 1 then "" else "s"))
		local top = list[1]
		local winner = if top and (tally[top.userId] or 0) > 0 then top.name else nil
		ctx.pushResult(ev, lines, winner)
		if winner then
			ctx.announce(ctx.audience(ev), winner:upper() .. " WINS THE FASHION SHOW")
		end
		ctx.closeEvent(ev)
	end

	local function canVote(ev: any, d: any, p: Player): boolean
		if ctx.isRegistered(ev, p) then
			return true
		end
		return nearRunway(d, p, F.SPECTATOR_RANGE)
	end

	local function startWalk(ev: any, e: Model_)
		local d = ev.data
		local outfit, pieces = describeOutfit(e.player)
		if outfit then
			e.outfit = outfit
			e.pieces = pieces
		end
		local held = e.player.Character
		if held then
			AntiCheat.allowTeleport(e.player, 3)
			held:PivotTo(CFrame.lookAt(d.venue.startPos, d.venue.startPos + Vector3.new(0, 0, 1)))
		end
		local t = now()
		d.walk = { entry = e, startedAt = t, endsAt = t + F.WALK, reachedAt = nil, offSince = nil }
		ev.phase = "Runway: " .. e.name
		ctx.announce({ e.player }, "YOUR WALK! HIT THE PINK MARK")
		ctx.announce(ctx.audience(ev), "NOW WALKING: " .. e.name:upper())
		ctx.markDirty()
	end

	---------------------------------------------------------------------------
	-- Handlers
	---------------------------------------------------------------------------
	local handlers = {}
	handlers.tip = "Put on your best fit in the Closet (Shops), then be at the runway for check-in."

	function handlers.available(): boolean
		return findSpot(nil) ~= nil
	end

	function handlers.pickVenue(): (Vector3, string?, any)
		local g = findSpot(nil)
		if not g then
			return nil :: any, nil, nil
		end
		local name = EventKit.landmark(g, 200)
		return g, if name then "Runway near " .. name else "Pop-up runway", g
	end

	function handlers.goLive(ev: any): (string, string?)
		local g = findSpot(if typeof(ev.venue) == "Vector3" then ev.venue else nil)
		if not g then
			return "postpone", "The runway spot is blocked."
		end
		local venue = build(g)
		ev.venue = g
		ev.pos = g + Vector3.new(0, 0, RUNWAY.Z / 2 + 6)
		local name = EventKit.landmark(g, 200)
		ev.location = if name then "Runway near " .. name else "Pop-up runway"
		ev.data = {
			venue = venue,
			folder = venue.folder,
			models = {} :: { Model_ },
			queue = {} :: { Model_ },
			walk = nil :: Walk?,
			box = EventKit.newVotes(),
			autoWatched = {} :: { [Player]: boolean },
			entrants = 0,
		}
		ev.state = "Checkin"
		ev.phase = "Check-in at the runway"
		ev.phaseEndsAt = now() + F.CHECKIN
		return "live", nil
	end

	local function autoWatch(ev: any, d: any)
		for _, p in Players:GetPlayers() do
			if not ctx.isRegistered(ev, p) and not d.autoWatched[p] and nearRunway(d, p, F.SPECTATOR_RANGE) then
				d.autoWatched[p] = true
				ev.watchers[p] = true
				ctx.notify(p, "👗 FASHION SHOW", "You're in the crowd! Watch the walks and vote for the best fit.")
			end
		end
	end

	function handlers.tick(ev: any)
		local d = ev.data
		local t = now()
		if not d.folder.Parent then
			ctx.cancelEvent(ev, "The runway is gone.")
			return
		end
		autoWatch(ev, d)

		if ev.state == "Checkin" then
			if t < ev.phaseEndsAt then
				return
			end
			for _, p in table.clone(ev.registered) do
				if not p.Parent or not nearRunway(d, p, 40) or not ctx.onFoot(p) then
					ctx.dropEntrant(ev, p, "MISSED CHECK-IN", "You weren't at the runway when the Fashion Show started.")
				else
					local outfit, pieces = describeOutfit(p)
					if not outfit then
						ctx.dropEntrant(ev, p, "NO CLOSET OUTFIT", "Fashion Show fits come from your Closet. Turn off \"Use my Roblox avatar\" in the Closet next time.")
					else
						local e: Model_ = { userId = p.UserId, player = p, name = p.DisplayName, outfit = outfit, pieces = pieces, order = #d.models + 1, walked = false }
						table.insert(d.models, e)
						table.insert(d.queue, e)
					end
				end
			end
			d.entrants = #d.models
			if d.entrants < ctx.minEntrants(ev.kind) then
				ctx.cancelEvent(ev, string.format("A fashion show needs at least %d models at the runway.", ctx.minEntrants(ev.kind)))
				return
			end
			ev.state = "Running"
			ev.phase = "Runway"
			ev.phaseEndsAt = 0
			ctx.markDirty()
			return
		end

		if ev.state == "Running" then
			local walk: Walk? = d.walk
			if walk then
				local e = walk.entry
				local p = e.player
				local done = false
				if not p.Parent or not ctx.isRegistered(ev, p) then
					done = true
				elseif not onRunway(d, p) then
					walk.offSince = walk.offSince or t
					if t - (walk.offSince :: number) > 2.5 then
						ctx.notify(p, "OFF THE RUNWAY", "You stepped off the runway, so the walk doesn't count.")
						done = true
					end
				else
					walk.offSince = nil
					local r = ctx.rootOf(p)
					local atEnd = r ~= nil and ctx.flatDist(r.Position, d.venue.endPos) <= 4
					if atEnd then
						walk.reachedAt = walk.reachedAt or t
						if t - (walk.reachedAt :: number) >= F.POSE then
							e.walked = true
							done = true
							ctx.announce(ctx.audience(ev), e.name:upper() .. " SERVES!")
						end
					else
						walk.reachedAt = nil
					end
				end
				if not done and t >= walk.endsAt + (if walk.reachedAt then F.POSE else 0) then
					if p.Parent then
						ctx.notify(p, "TIME", "You didn't hold the pose at the pink mark in time.")
					end
					done = true
				end
				if done then
					d.walk = nil
					ctx.markDirty()
				end
			end
			if not d.walk then
				while #d.queue > 0 and not d.walk do
					local e = table.remove(d.queue, 1) :: Model_
					if e.player.Parent and ctx.isRegistered(ev, e.player) then
						if nearRunway(d, e.player, 60) then
							startWalk(ev, e)
						else
							ctx.notify(e.player, "SKIPPED", "You weren't at the runway when your walk came up.")
						end
					end
				end
			end
			if d.walk or #d.queue > 0 then
				return
			end
			local walked = #candidates(d)
			if walked < ctx.minEntrants(ev.kind) then
				ctx.cancelEvent(ev, "Not enough models finished their walk for a vote.")
				return
			end
			ev.state = "Voting"
			ev.phase = "Crowd vote"
			ev.phaseEndsAt = t + F.VOTE
			for _, p in ctx.audience(ev) do
				ctx.notify(p, "👗 VOTE NOW", "Pick the best fit in the event panel. One vote, not for yourself.")
			end
			ctx.markDirty()
			return
		end

		-- Voting
		local alive = 0
		for _, e in candidates(d) do
			if e.player.Parent and ctx.isRegistered(ev, e.player) then
				alive += 1
			end
		end
		if alive < ctx.minEntrants(ev.kind) then
			ctx.cancelEvent(ev, "Too many models left before the vote finished.")
			return
		end
		if t >= ev.phaseEndsAt then
			finish(ev)
		end
	end

	function handlers.live(ev: any, viewer: Player): any
		local d = ev.data
		local lines = {}
		local out: any = { lines = lines, endsAt = ev.phaseEndsAt }
		local status
		if ev.state == "Checkin" then
			local here = 0
			for _, p in ev.registered do
				if nearRunway(d, p, 40) then
					here += 1
				end
			end
			table.insert(lines, string.format("%d / %d models at the runway", here, #ev.registered))
			if ctx.isRegistered(ev, viewer) then
				local outfit = describeOutfit(viewer)
				table.insert(lines, "Your fit: " .. (outfit or "none: turn off \"Use my Roblox avatar\" in the Closet"))
				status = if nearRunway(d, viewer, 40) then "Checked in. Strike a pose while you wait." else "Get to the runway!"
			else
				status = "Models are arriving"
			end
		elseif ev.state == "Running" then
			local walk: Walk? = d.walk
			if walk then
				table.insert(lines, "On the runway: " .. walk.entry.name)
				table.insert(lines, "Wearing: " .. walk.entry.outfit)
				out.endsAt = walk.endsAt
			end
			if #d.queue > 0 then
				local names = {}
				for i = 1, math.min(3, #d.queue) do
					table.insert(names, d.queue[i].name)
				end
				table.insert(lines, "Up next: " .. table.concat(names, ", "))
			end
			if walk and walk.entry.player == viewer then
				status = if walk.reachedAt then "HOLD THE POSE!" else "Walk to the pink mark at the end!"
				out.highlight = true
			elseif ctx.isRegistered(ev, viewer) then
				local pos = 0
				for i, e in d.queue do
					if e.player == viewer then
						pos = i
					end
				end
				status = if pos > 0 then string.format("You walk #%d in line", pos) else "Walk done. Votes open after the last model."
			else
				status = "Watching the runway"
			end
		else
			local voted = d.box.votes[viewer.UserId]
			table.insert(lines, string.format("%d vote%s so far", EventKit.voteCount(d.box), if EventKit.voteCount(d.box) == 1 then "" else "s"))
			local entries = {}
			for _, e in candidates(d) do
				table.insert(entries, { key = e.userId, name = e.name, detail = e.outfit, mine = e.userId == viewer.UserId })
			end
			local allowed = canVote(ev, d, viewer)
			out.ballot = {
				title = "👗 Best Fit",
				note = if allowed then "One vote each. You can't vote for yourself." else "Stand at the runway to vote.",
				entries = entries,
				voted = voted,
				canVote = voted == nil and allowed,
				endsAt = ev.phaseEndsAt,
			}
			status = if voted then "Vote locked in ✓" elseif allowed then "Crowd vote: tap VOTE" else "Get to the runway to vote"
		end
		out.status = status
		return out
	end

	function handlers.request(ev: any, player: Player, action: string, b: any, _c: any): any
		local d = ev.data
		if action ~= "Vote" then
			return { ok = false, msg = "Nothing to do here right now." }
		end
		if ev.state ~= "Voting" then
			return { ok = false, msg = "Voting isn't open." }
		end
		if not canVote(ev, d, player) then
			return { ok = false, msg = "Only models and the crowd at the runway can vote." }
		end
		local ok, msg = EventKit.castVote(d.box, player, b, function(userId: number): boolean
			for _, e in candidates(d) do
				if e.userId == userId then
					return true
				end
			end
			return false
		end)
		if ok then
			ctx.markDirty()
		end
		return { ok = ok, msg = msg, voted = d.box.votes[player.UserId] }
	end

	function handlers.leave(ev: any, p: Player)
		local d = ev.data
		for i, e in d.queue do
			if e.player == p then
				table.remove(d.queue, i)
				break
			end
		end
		if d.walk and d.walk.entry.player == p then
			d.walk = nil
		end
	end

	function handlers.cleanup(ev: any)
		local d = ev.data
		if d then
			if d.folder then
				d.folder:Destroy()
			end
			for p in d.autoWatched do
				ev.watchers[p] = nil
			end
		end
	end

	return handlers
end

return EventFashion
