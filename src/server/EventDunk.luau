-- CITY GRIND: Dunk Contest (city event kind, plugs into Events.registerKind).
-- Entrants take turns at one hoop of a free public court. Each turn hands the
-- dunker ATTEMPTS balls, one at a time; they pick their own run-up. A make only
-- counts when Basketball judged the shot a "dunk" on the contest hoop, and the
-- style points come from what the server saw of the dunker's body (sampled every
-- frame): approach speed just before the release, hang time since leaving the
-- floor, how far from the rim they took off, and a bonus the first time they
-- finish from each approach (straight on / wing / baseline). No judges, no dice.
--
-- Saved: section "events".dunkBest (best contest total).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Basketball = require(script.Parent:WaitForChild("Basketball"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local EventDunk = {}

type Sample = { t: number, pos: Vector3, speed: number, air: boolean }
type Dunk = { points: number, detail: string }
type DTurn = {
	player: Player,
	name: string,
	readyAt: number,
	endsAt: number,
	attempts: number,
	score: number,
	best: number,
	dunks: { Dunk },
	angles: { [string]: boolean },
	ball: any?,
	awaySince: number?,
	samples: { Sample },
	ended: boolean,
	order: number,
}
type BallInfo = { turn: DTurn, ev: any, givenAt: number, held: boolean, releasedAt: number?, judged: boolean }

local COURT_PREFER = { "GrandArena", "BeachCourt", "NeighborhoodCourt" }

function EventDunk.init(ctx: any): any
	local EC = ctx.EC
	local D = EC.DUNK
	local now = ctx.now

	local balls: { [any]: BallInfo } = {}
	local activeTurns: { [Player]: DTurn } = {} -- the dunker of every live contest

	---------------------------------------------------------------------------
	-- Body sampling for the dunker (every frame, last 3 seconds kept)
	---------------------------------------------------------------------------
	RunService.Heartbeat:Connect(function()
		if next(activeTurns) == nil then
			return
		end
		local clock = os.clock()
		for p, turn in activeTurns do
			local r = ctx.rootOf(p)
			local h = ctx.humanoidOf(p)
			if r and h then
				local v = r.AssemblyLinearVelocity
				table.insert(turn.samples, {
					t = clock,
					pos = r.Position,
					speed = Vector3.new(v.X, 0, v.Z).Magnitude,
					air = h.FloorMaterial == Enum.Material.Air,
				})
				while #turn.samples > 0 and clock - turn.samples[1].t > 3 do
					table.remove(turn.samples, 1)
				end
			end
		end
	end)

	-- Style points for a made dunk released at os.clock() `at` on rim `rim`.
	local function judge(turn: DTurn, at: number, rim: Vector3, courtCenter: Vector3): Dunk
		local topSpeed = 0
		local lastGround: Sample? = nil
		local atSample: Sample? = nil
		for _, s in turn.samples do
			if s.t <= at + 0.02 then
				atSample = s
				if s.t >= at - 0.8 then
					topSpeed = math.max(topSpeed, s.speed)
				end
				if not s.air then
					lastGround = s
				end
			end
		end
		local airborne = atSample ~= nil and atSample.air
		local airTime = if airborne and lastGround then math.clamp(at - lastGround.t, 0, 1.5) elseif airborne then 1.5 else 0
		local takeoffPos = if airborne and lastGround then lastGround.pos elseif atSample then atSample.pos else rim
		local takeoff = ctx.flatDist(takeoffPos, rim)

		local speedPts = math.clamp(math.floor((topSpeed - D.SPEED_FROM) / D.SPEED_STEP) + 1, 0, D.SPEED_MAX)
		if topSpeed < D.SPEED_FROM then
			speedPts = 0
		end
		local airPts = math.clamp(math.floor(airTime * D.AIR_PER_SECOND), 0, D.AIR_MAX)
		local takeoffPts = 0
		if takeoff >= D.TAKEOFF_FROM then
			takeoffPts = math.clamp(math.floor((takeoff - D.TAKEOFF_FROM) / D.TAKEOFF_STEP) + 1, 0, D.TAKEOFF_MAX)
		end
		-- approach direction relative to the court's long axis (z)
		local fromRim = ctx.flat(takeoffPos - rim)
		local toCenter = ctx.flat(courtCenter - rim)
		local angleName = "straight"
		if fromRim.Magnitude > 0.5 and toCenter.Magnitude > 0.5 then
			local deg = math.deg(math.acos(math.clamp(fromRim.Unit:Dot(toCenter.Unit), -1, 1)))
			angleName = if deg < 25 then "straight" elseif deg < 62 then "wing" else "baseline"
		end
		local varietyPts = 0
		if not turn.angles[angleName] then
			turn.angles[angleName] = true
			varietyPts = D.NEW_ANGLE
		end
		local total = D.BASE + speedPts + airPts + takeoffPts + varietyPts
		local detail = string.format("%d pts: made +%d, speed +%d (%d st/s), air +%d (%.2fs), take-off +%d (%.1f st), %s%s", total, D.BASE, speedPts, math.floor(topSpeed), airPts, airTime, takeoffPts, takeoff, angleName, if varietyPts > 0 then " +" .. varietyPts else "")
		return { points = total, detail = detail }
	end

	---------------------------------------------------------------------------
	-- Ball rules: contest balls only ever go to the dunker; the dunker only
	-- uses contest balls; nothing can be stolen from or by the dunker.
	---------------------------------------------------------------------------
	local policy = Basketball.policy
	local canHold = policy.canHold
	policy.canHold = function(player, ball)
		local info = balls[ball]
		if info then
			return info.turn.player == player and not info.releasedAt and not info.turn.ended
		end
		if activeTurns[player] then
			return false
		end
		return canHold(player, ball)
	end
	local canSteal = policy.canSteal
	policy.canSteal = function(player, victim, ball)
		if balls[ball] or activeTurns[player] or activeTurns[victim] then
			return false
		end
		return canSteal(player, victim, ball)
	end
	local passTargets = policy.passTargets
	policy.passTargets = function(player, ball)
		if balls[ball] then
			return {}
		end
		return passTargets(player, ball)
	end

	local function dropBall(ball: any)
		balls[ball] = nil
		Basketball.destroy(ball)
	end

	---------------------------------------------------------------------------
	-- Turns
	---------------------------------------------------------------------------
	local function endTurn(ev: any, reason: string?)
		local d = ev.data
		local turn: DTurn? = d.turn
		if not turn then
			return
		end
		d.turn = nil
		turn.ended = true
		if activeTurns[turn.player] == turn then
			activeTurns[turn.player] = nil
		end
		if turn.ball then
			dropBall(turn.ball)
			turn.ball = nil
		end
		table.insert(d.done, turn)
		if turn.player.Parent then
			ctx.announce({ turn.player }, string.format("%d POINTS", turn.score))
			if reason then
				ctx.notify(turn.player, "TURN OVER", reason)
			end
		end
		ctx.markDirty()
	end

	local function startTurn(ev: any, p: Player)
		local d = ev.data
		local held = Basketball.heldBall(p)
		if held then
			Basketball.drop(held)
		end
		local t = now()
		local turn: DTurn = {
			player = p,
			name = p.DisplayName,
			readyAt = t + D.READY,
			endsAt = t + D.READY + D.TURN,
			attempts = 0,
			score = 0,
			best = 0,
			dunks = {},
			angles = {},
			ball = nil,
			awaySince = nil,
			samples = {},
			ended = false,
			order = (table.find(d.order, p) or 99),
		}
		d.turn = turn
		activeTurns[p] = turn
		local character = p.Character
		if character then
			character:PivotTo(CFrame.lookAt(d.start, Vector3.new(d.rim.X, d.start.Y, d.rim.Z)))
		end
		ctx.announce({ p }, string.format("YOUR TURN! %d DUNKS", D.ATTEMPTS))
		ctx.notify(p, "YOUR TURN", "Take any run-up you like. Speed, hang time, a long take-off and new angles all score. Only real dunks count.")
		ctx.markDirty()
	end

	local function giveBall(ev: any, turn: DTurn)
		local r = ctx.rootOf(turn.player)
		if not r then
			return
		end
		local ball = Basketball.newBall(r.Position + Vector3.new(0, 2, 0))
		ball.owner = turn.player
		ball.court = ev.data.court
		balls[ball] = { turn = turn, ev = ev, givenAt = os.clock(), held = false, releasedAt = nil, judged = false }
		turn.ball = ball
		turn.attempts += 1
		Basketball.give(ball, turn.player)
		ctx.announce({ turn.player }, string.format("DUNK %d / %d", turn.attempts, D.ATTEMPTS))
	end

	local function scoreMiss(turn: DTurn, why: string)
		table.insert(turn.dunks, { points = 0, detail = why })
		if turn.player.Parent then
			ctx.announce({ turn.player }, why:upper())
		end
		ctx.markDirty()
	end

	Basketball.scored.connect(function(ball, hoop, shot)
		local info = balls[ball]
		if not info or info.judged then
			return
		end
		local turn = info.turn
		local ev = info.ev
		local d = ev.data
		if not d or d.turn ~= turn then
			return
		end
		info.judged = true
		if shot and shot.shooter == turn.player and shot.kind == "dunk" and hoop.court == d.court and hoop.side == d.side then
			local dunk = judge(turn, shot.at, d.rim, d.center)
			table.insert(turn.dunks, dunk)
			turn.score += dunk.points
			turn.best = math.max(turn.best, dunk.points)
			d.last = turn.name .. " · " .. dunk.detail
			ctx.announce(ctx.audience(ev), string.format("%s +%d", turn.name:upper(), dunk.points))
			ctx.markDirty()
		elseif shot and shot.shooter == turn.player then
			scoreMiss(turn, if hoop.court == d.court and hoop.side == d.side then "Not a dunk" else "Wrong hoop")
		else
			scoreMiss(turn, "No good")
		end
		task.delay(0.8, function()
			if balls[ball] then
				dropBall(ball)
			end
			if turn.ball == ball then
				turn.ball = nil
			end
		end)
	end)

	---------------------------------------------------------------------------
	-- Venue
	---------------------------------------------------------------------------
	local function build(ev: any, court: Model)
		local folder = Instance.new("Folder")
		folder.Name = "DunkContest"
		folder.Parent = ctx.root
		local center = ctx.courtCenter(court)
		local side = "North"
		local rim = ctx.rimOf(court, side) :: Vector3
		local dir = ctx.flat(center - rim)
		dir = if dir.Magnitude > 0.1 then dir.Unit else Vector3.new(0, 0, 1)
		local floorY = center.Y + 0.45
		local startFlat = Vector3.new(rim.X, floorY, rim.Z) + dir * D.START_DIST
		ctx.part({
			name = "StartMark",
			size = Vector3.new(0.12, 5, 5),
			cframe = CFrame.new(startFlat + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			color = Color3.fromRGB(255, 70, 70),
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
			collide = false,
			parent = folder,
		})
		local banner = ctx.part({
			name = "Banner",
			size = Vector3.new(24, 4, 0.4),
			cframe = CFrame.new(center + Vector3.new(0, 18, 0)),
			color = Color3.fromRGB(20, 20, 26),
			collide = false,
			parent = folder,
		})
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			ctx.surfaceText(banner, face, "💥 DUNK CONTEST", Color3.fromRGB(255, 90, 90))
		end
		ev.data = {
			court = court,
			side = side,
			rim = rim,
			center = center,
			start = startFlat + Vector3.new(0, 3, 0),
			folder = folder,
			queue = {} :: { Player },
			order = {} :: { Player },
			done = {} :: { DTurn },
			turn = nil :: DTurn?,
			entrants = 0,
			graceUntil = nil :: number?,
			last = nil :: string?,
		}
	end

	---------------------------------------------------------------------------
	-- Handlers
	---------------------------------------------------------------------------
	local function pickCourt(prefer: any): Model?
		return ctx.freeCourt(prefer or COURT_PREFER, ctx.threeCourt()) or ctx.freeCourt(prefer or COURT_PREFER, nil)
	end

	local handlers = {}
	handlers.tip = "Be on the contest court at check-in."

	function handlers.available(): boolean
		return pickCourt(nil) ~= nil
	end

	function handlers.pickVenue(): (Vector3, string?, any)
		local court = pickCourt(nil)
		if not court then
			return nil :: any, nil, nil
		end
		return ctx.courtCenter(court) + Vector3.new(0, 0, ctx.courtSize(court).Z / 2 + 8), ctx.courtLabel(court), court
	end

	function handlers.goLive(ev: any): (string, string?)
		local court = pickCourt(if ev.venue then ev.venue else nil)
		if not court then
			return "postpone", "Every court is busy with games."
		end
		ctx.claimCourt(court, ev.name)
		build(ev, court)
		ev.venue = court
		ev.location = ctx.courtLabel(court)
		ev.pos = ctx.courtCenter(court) + Vector3.new(0, 0, ctx.courtSize(court).Z / 2 + 8)
		ev.state = "Checkin"
		ev.phase = "Check-in: get on the court"
		ev.phaseEndsAt = now() + D.CHECKIN
		return "live", nil
	end

	local function finish(ev: any)
		local d = ev.data
		local turns = table.clone(d.done)
		table.sort(turns, function(a: DTurn, b: DTurn)
			if a.score ~= b.score then
				return a.score > b.score
			end
			if a.best ~= b.best then
				return a.best > b.best
			end
			return a.order < b.order
		end)
		local ranked, lines = {}, {}
		for place, turn in turns do
			local p = turn.player
			if p.Parent and ctx.isRegistered(ev, p) then
				table.insert(ranked, p)
				local sec = ctx.section(p)
				if sec and turn.score > (sec.dunkBest or 0) then
					sec.dunkBest = turn.score
					PlayerData.markChanged(p)
					ctx.notify(p, "PERSONAL BEST", string.format("New Dunk Contest best: %d points.", turn.score))
				end
				if turn.score > 0 then
					PlayerData.addStatXP(p, "Vertical", 20)
					PlayerData.addStatXP(p, "Finishing", 10)
				end
			end
			if place <= 5 then
				local made = 0
				for _, dk in turn.dunks do
					if dk.points > 0 then
						made += 1
					end
				end
				table.insert(lines, string.format("%d. %s — %d pts (%d/%d dunks, best %d)", place, turn.name, turn.score, made, D.ATTEMPTS, turn.best))
			end
		end
		local scores = {}
		for _, turn in turns do
			scores[turn.player] = turn.score
		end
		ctx.payPodium(ev, ranked, d.entrants, function(p: Player)
			return (scores[p] or 0) > 0
		end)
		ctx.pushResult(ev, lines, turns[1] and turns[1].name or nil)
		if turns[1] then
			ctx.announce(ctx.audience(ev), turns[1].name:upper() .. " WINS THE DUNK CONTEST")
		end
		ctx.closeEvent(ev)
	end

	function handlers.tick(ev: any)
		local d = ev.data
		local court: Model = d.court
		if not court.Parent then
			ctx.cancelEvent(ev, "The court is gone.")
			return
		end
		local t = now()
		if ev.state == "Checkin" then
			if t < ev.phaseEndsAt then
				return
			end
			for _, p in table.clone(ev.registered) do
				if p.Parent and ctx.onCourt(court, p, 10) and not p:GetAttribute("InGame") then
					table.insert(d.queue, p)
					table.insert(d.order, p)
				else
					ctx.dropEntrant(ev, p, "MISSED CHECK-IN", "You weren't on the court when the Dunk Contest started.")
				end
			end
			d.entrants = #d.queue
			if d.entrants < ctx.minEntrants(ev.kind) then
				ctx.cancelEvent(ev, string.format("A dunk contest needs at least %d dunkers on the court.", ctx.minEntrants(ev.kind)))
				return
			end
			ev.state = "Running"
			ev.phase = "Dunking"
			ev.phaseEndsAt = 0
			ctx.markDirty()
			return
		end

		local turn: DTurn? = d.turn
		if turn then
			local p = turn.player
			local h = ctx.humanoidOf(p)
			if not p.Parent or not ctx.isRegistered(ev, p) then
				endTurn(ev, nil)
			elseif not h or h.Health <= 0 then
				endTurn(ev, "You went down mid-turn.")
			elseif not ctx.onFoot(p) then
				endTurn(ev, "No vehicles or seats in the dunk contest.")
			else
				if not ctx.onCourt(court, p, 8) then
					turn.awaySince = turn.awaySince or t
					if t - (turn.awaySince :: number) > 5 then
						endTurn(ev, "You left the court.")
					end
				else
					turn.awaySince = nil
				end
				if d.turn == turn and t >= turn.endsAt then
					-- a ball already in the air still gets judged by the grace below
					endTurn(ev, "Time!")
				end
			end
			if d.turn == turn and t >= turn.readyAt then
				local ball = turn.ball
				local info = ball and balls[ball]
				if ball and not info then
					turn.ball = nil
				elseif ball and info then
					local clock = os.clock()
					if ball.holder == p then
						info.held = true
					elseif ball.holder == nil then
						if not info.held then
							-- never reached their hands (no character): hand out a fresh one
							if clock - info.givenAt > 2 then
								dropBall(ball)
								turn.ball = nil
								turn.attempts -= 1
							end
						elseif not info.judged then
							info.releasedAt = info.releasedAt or clock
							if clock - (info.releasedAt :: number) > D.MISS_RETURN then
								info.judged = true
								dropBall(ball)
								turn.ball = nil
								scoreMiss(turn, "Missed")
							end
						end
					else
						dropBall(ball)
						turn.ball = nil
					end
				end
				if not turn.ball then
					if turn.attempts < D.ATTEMPTS then
						giveBall(ev, turn)
					else
						endTurn(ev, nil)
					end
				end
			end
		end

		if not d.turn then
			while #d.queue > 0 and not d.turn do
				local p = table.remove(d.queue, 1) :: Player
				if p.Parent and ctx.isRegistered(ev, p) then
					if ctx.onCourt(court, p, 30) then
						startTurn(ev, p)
					else
						ctx.notify(p, "SKIPPED", "You weren't near the court when your turn came up.")
						table.insert(d.done, {
							player = p,
							name = p.DisplayName,
							readyAt = t,
							endsAt = t,
							attempts = 0,
							score = 0,
							best = 0,
							dunks = {},
							angles = {},
							samples = {},
							ended = true,
							order = table.find(d.order, p) or 99,
						})
					end
				end
			end
		end

		if d.turn or #d.queue > 0 then
			d.graceUntil = nil
			return
		end
		if not d.graceUntil then
			d.graceUntil = t + 2
			return
		end
		if t >= d.graceUntil then
			finish(ev)
		end
	end

	function handlers.live(ev: any, viewer: Player): any
		local d = ev.data
		local lines, status = {}, ""
		local turn: DTurn? = d.turn
		if ev.state == "Checkin" then
			local here = 0
			for _, p in ev.registered do
				if ctx.onCourt(d.court, p, 10) then
					here += 1
				end
			end
			table.insert(lines, string.format("%d / %d dunkers on %s", here, #ev.registered, ctx.courtLabel(d.court)))
			table.insert(lines, string.format("Scoring: made %d · speed up to +%d · air up to +%d · take-off up to +%d · new angle +%d", D.BASE, D.SPEED_MAX, D.AIR_MAX, D.TAKEOFF_MAX, D.NEW_ANGLE))
			status = if ctx.isRegistered(ev, viewer)
				then (if ctx.onCourt(d.court, viewer, 10) then "Checked in. Wait for your turn." else "Get onto the contest court!")
				else "Check-in is open"
		else
			if turn then
				local clock = if now() < turn.readyAt then "ready" else ctx.EC.formatIn(turn.endsAt - now())
				table.insert(lines, string.format("On the hoop: %s · %d pts · dunk %d/%d · %s", turn.name, turn.score, math.max(1, turn.attempts), D.ATTEMPTS, clock))
			end
			if d.last then
				table.insert(lines, "Last: " .. d.last)
			end
			local board = table.clone(d.done)
			table.sort(board, function(a: DTurn, b: DTurn)
				return a.score > b.score
			end)
			for i = 1, math.min(3, #board) do
				table.insert(lines, string.format("#%d %s — %d", i, board[i].name, board[i].score))
			end
			if #d.queue > 0 then
				local names = {}
				for i = 1, math.min(3, #d.queue) do
					table.insert(names, d.queue[i].DisplayName)
				end
				table.insert(lines, "Up next: " .. table.concat(names, ", "))
			end
			if turn and turn.player == viewer then
				status = if now() < turn.readyAt then "Get ready…" else string.format("YOUR TURN · %d pts · dunk %d/%d", turn.score, math.max(1, turn.attempts), D.ATTEMPTS)
			elseif table.find(d.queue, viewer) then
				status = string.format("You're #%d in line", table.find(d.queue, viewer) :: number)
			elseif ctx.isRegistered(ev, viewer) then
				status = "Done dunking. Waiting for results."
			else
				status = "Watching"
			end
		end
		return {
			lines = lines,
			status = status,
			endsAt = if turn and turn.player == viewer then turn.endsAt elseif ev.state == "Checkin" then ev.phaseEndsAt else 0,
			highlight = turn ~= nil and turn.player == viewer,
		}
	end

	function handlers.leave(ev: any, p: Player)
		local d = ev.data
		local i = table.find(d.queue, p)
		if i then
			table.remove(d.queue, i)
		end
		if d.turn and d.turn.player == p then
			endTurn(ev, nil)
		end
	end

	function handlers.cleanup(ev: any)
		local d = ev.data
		if d then
			if d.turn then
				activeTurns[d.turn.player] = nil
				d.turn.ended = true
				d.turn = nil
			end
			for ball, info in balls do
				if info.ev == ev then
					dropBall(ball)
				end
			end
			if d.folder then
				d.folder:Destroy()
			end
			ctx.releaseCourt(d.court)
		end
	end

	Players.PlayerRemoving:Connect(function(p)
		activeTurns[p] = nil
	end)

	return handlers
end

return EventDunk
