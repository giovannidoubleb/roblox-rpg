-- CITY GRIND: jobs on the client (sections 40, 68, 77, 110).
-- * Phone app "Jobs": every job with its real pay range at your job level,
--   level / XP bar, requirement, next unlock, START SHIFT / QUIT and GPS.
-- * Shift HUD: objective, progress, timer, earnings, hot-food timer, combo.
-- * Waypoint beam + marker to the current objective, highlight / ghost for
--   the exact shelf box or build spot.
-- * Hides other players' job markers and prompts that aren't for your job.
-- The server owns every shift; this file only shows state and sends
-- "start" / "quit" requests.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local JobsConfig = require(shared:WaitForChild("JobsConfig"))

local player = Players.LocalPlayer
local colors = UI.colors
local JOBS = JobsConfig.JOBS

local Jobs = {}

local JobAction: RemoteEvent? = nil
local state: any = nil -- the active shift payload from the server, or nil

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function jobLevel(id: string): number
	return player:GetAttribute("JobLevel_" .. id) or 1
end

local function jobXP(id: string): number
	return player:GetAttribute("JobXP_" .. id) or 0
end

local function send(action: string, id: string?)
	if JobAction then
		JobAction:FireServer(action, id)
	else
		HUD.push("JOBS", "Still connecting, try again in a second.")
	end
end

-- Does the player own a car? Read from the Vehicles system's mirror attribute.
local vehiclesConfig: any = nil
local function ownsCar(): boolean?
	if JobsConfig.isCarKind(player:GetAttribute("Driving")) then
		return true
	end
	local json = player:GetAttribute("VehiclesOwned")
	if type(json) ~= "string" then
		return nil
	end
	if vehiclesConfig == nil then
		local module = shared:FindFirstChild("VehiclesConfig")
		local ok, result = pcall(function()
			return require(module :: any)
		end)
		vehiclesConfig = if module and ok then result else false
	end
	local ok, owned = pcall(function()
		return game:GetService("HttpService"):JSONDecode(json)
	end)
	if not ok or type(owned) ~= "table" then
		return nil
	end
	for id, value in owned do
		local key = if type(id) == "string" then id else value
		local spec = vehiclesConfig and vehiclesConfig.byId and vehiclesConfig.byId[key]
		if spec and JobsConfig.isCarKind(spec.kind) then
			return true
		end
	end
	return false
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function nextUnlock(id: string, level: number)
	for _, u in JOBS[id].unlocks do
		if u.level > level then
			return u
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Waypoint: beam from you to the objective, marker with distance,
-- highlight on the exact box and a ghost of the piece to build.
---------------------------------------------------------------------------
local waypoint: { marker: BasePart, beam: Beam, a0: Attachment, label: TextLabel }? = nil
local highlight: Highlight
local ghost: BasePart? = nil

local function clearWaypoint()
	if waypoint then
		waypoint.marker:Destroy()
		waypoint.a0:Destroy()
		waypoint = nil
	end
end

local function setWaypoint(target: Vector3?, name: string?, color: Color3)
	if not target then
		clearWaypoint()
		return
	end
	if not waypoint then
		local marker = UI.new("Part", {
			Name = "JobWaypoint",
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Transparency = 1,
			Size = Vector3.one,
			Parent = Workspace,
		})
		local a1 = UI.new("Attachment", { Parent = marker })
		local a0 = UI.new("Attachment", { Position = Vector3.new(0, -2.5, 0) })
		local beam = UI.new("Beam", {
			Attachment0 = a0,
			Attachment1 = a1,
			Transparency = NumberSequence.new(0.25),
			Width0 = 1,
			Width1 = 1,
			FaceCamera = true,
			LightEmission = 1,
			Segments = 1,
			Parent = marker,
		})
		local gui = UI.new("BillboardGui", { Size = UDim2.fromOffset(220, 46), StudsOffset = Vector3.new(0, 7, 0), AlwaysOnTop = true, LightInfluence = 0, Parent = marker })
		local label = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 17, TextStrokeTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = gui })
		waypoint = { marker = marker, beam = beam, a0 = a0, label = label }
	end
	local wp = waypoint :: any
	wp.marker.Position = target + Vector3.new(0, 2, 0)
	wp.beam.Color = ColorSequence.new(color)
	wp.label.TextColor3 = color
	wp.name = name or "Objective"
end

local function setGhost(spec: any, color: Color3)
	if ghost then
		ghost:Destroy()
		ghost = nil
	end
	if type(spec) ~= "table" or typeof(spec.cframe) ~= "CFrame" or typeof(spec.size) ~= "Vector3" then
		return
	end
	local g = UI.new("Part", {
		Name = "JobGhost",
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Material = Enum.Material.ForceField,
		Color = color,
		Transparency = 0.2,
		Size = spec.size,
		CFrame = spec.cframe,
		Parent = Workspace,
	})
	ghost = g
end

---------------------------------------------------------------------------
-- Hiding job props that aren't yours
---------------------------------------------------------------------------
local jobsFolder: Instance? = nil

local function applyVisibility(inst: Instance)
	local myJob = player:GetAttribute("Job") or ""
	if inst:IsA("ProximityPrompt") then
		local start = inst:GetAttribute("JobStart")
		local only = inst:GetAttribute("JobOnly")
		local owner = inst:GetAttribute("JobOwner")
		if start ~= nil then
			inst.Enabled = myJob == ""
		elseif only ~= nil then
			inst.Enabled = myJob == only
		elseif owner ~= nil then
			inst.Enabled = owner == player.UserId
		end
	elseif inst:IsA("BillboardGui") or inst:IsA("Light") then
		-- may replicate after its (hidden) part
		local parent = inst.Parent
		local owner = parent and parent:GetAttribute("JobOwner")
		if owner ~= nil and owner ~= player.UserId then
			(inst :: any).Enabled = false
		end
	elseif inst:IsA("BasePart") then
		local owner = inst:GetAttribute("JobOwner")
		if owner ~= nil and owner ~= player.UserId then
			inst.LocalTransparencyModifier = 1
			for _, d in inst:GetDescendants() do
				if d:IsA("BillboardGui") or d:IsA("Light") then
					d.Enabled = false
				end
			end
		end
	end
end

local function applyAll()
	if not jobsFolder then
		return
	end
	for _, d in jobsFolder:GetDescendants() do
		applyVisibility(d)
	end
end

---------------------------------------------------------------------------
-- Shift HUD
---------------------------------------------------------------------------
local gui: ScreenGui
local panel: Frame
local titleLabel: TextLabel
local timerLabel: TextLabel
local objectiveLabel: TextLabel
local progressLabel: TextLabel
local setProgress: (number) -> ()
local earnedLabel: TextLabel
local extraLabel: TextLabel
local quitButton: TextButton
local quitArmedUntil = 0
local summaryPanel: Frame

local function buildHUD()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindJobs",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 3,
		Parent = player:WaitForChild("PlayerGui"),
	})
	panel = UI.new("Frame", {
		Name = "ShiftPanel",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.12,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.45, 0),
		Size = UDim2.fromOffset(250, 150),
		Visible = false,
		Parent = gui,
	}, { UI.corner(14), UI.padding(10) })
	HUD.slot("left", panel, 20)
	local stroke = UI.stroke(colors.accent, 1.5, 0.35)
	stroke.Name = "Accent"
	stroke.Parent = panel
	titleLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 16, TextColor3 = colors.accent, Size = UDim2.new(1, -60, 0, 18), Parent = panel })
	timerLabel = UI.label({ Text = "0:00", Font = UI.FONT_BLACK, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(60, 18), Parent = panel })
	objectiveLabel = UI.label({ Text = "", TextSize = 14, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 36), Parent = panel })
	local _, setter = UI.bar({ Position = UDim2.fromOffset(0, 64), Size = UDim2.new(1, 0, 0, 8), Parent = panel }, colors.cash)
	setProgress = setter
	progressLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 75), Size = UDim2.new(1, 0, 0, 15), Parent = panel })
	earnedLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 18, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 94), Size = UDim2.new(0.5, 0, 0, 20), Parent = panel })
	extraLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.stamina, Position = UDim2.fromOffset(0, 114), Size = UDim2.new(1, -80, 0, 16), Parent = panel })
	quitButton = UI.button({ Text = "QUIT", TextSize = 13, BackgroundColor3 = colors.danger, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(76, 28), Parent = panel })
	quitButton.Activated:Connect(function()
		-- two taps so a stray touch doesn't throw away a shift
		if os.clock() < quitArmedUntil then
			quitArmedUntil = 0
			send("quit")
		else
			quitArmedUntil = os.clock() + 3
			quitButton.Text = "SURE?"
			task.delay(3, function()
				if quitButton.Text == "SURE?" then
					quitButton.Text = "QUIT"
				end
			end)
		end
	end)

	summaryPanel = UI.new("Frame", {
		Name = "ShiftSummary",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.05,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.38),
		Size = UDim2.fromOffset(300, 150),
		Visible = false,
		Parent = gui,
	}, { UI.corner(16), UI.padding(14), UI.stroke(colors.cash, 2, 0.2) })
end

local function showSummary(s: any)
	local def = JOBS[s.job]
	if not def then
		return
	end
	for _, child in summaryPanel:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local headline = if s.completed then "SHIFT COMPLETE" else "SHIFT OVER"
	UI.label({ Text = def.icon .. "  " .. headline, Font = UI.FONT_BLACK, TextSize = 20, TextColor3 = if s.completed then colors.cash else colors.stamina, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 24), Parent = summaryPanel })
	UI.label({ Text = s.reason, TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 16), Parent = summaryPanel })
	UI.label({ Text = UI.formatCash(s.earned), Font = UI.FONT_BLACK, TextSize = 30, TextColor3 = colors.cash, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 32), Parent = summaryPanel })
	local lines = string.format("%d/%d %s", s.done, s.goal, s.word)
	if s.bonus and s.bonus > 0 then
		lines ..= string.format("  ·  completion bonus %s", UI.formatCash(s.bonus))
	end
	UI.label({ Text = lines, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 82), Size = UDim2.new(1, 0, 0, 16), Parent = summaryPanel })
	UI.label({
		Text = def.name .. " level " .. s.level .. (if s.levelledUp then "  ·  LEVEL UP!" else ""),
		Font = UI.FONT_BOLD,
		TextSize = 13,
		TextColor3 = if s.levelledUp then colors.xp else colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 102),
		Size = UDim2.new(1, 0, 0, 16),
		Parent = summaryPanel,
	})
	summaryPanel.Visible = true
	local shownAt = os.clock()
	summaryPanel:SetAttribute("ShownAt", shownAt)
	task.delay(6, function()
		if summaryPanel:GetAttribute("ShownAt") == shownAt then
			summaryPanel.Visible = false
		end
	end)
	HUD.push(headline, string.format("%s: %s for %d/%d %s.", def.name, UI.formatCash(s.earned), s.done, s.goal, s.word))
end

local function refreshPanel()
	if not state then
		panel.Visible = false
		return
	end
	local def = JOBS[state.job]
	panel.Visible = true
	local accent = panel:FindFirstChild("Accent") :: UIStroke
	accent.Color = def.color
	titleLabel.Text = def.icon .. "  " .. string.upper(def.name)
	titleLabel.TextColor3 = def.color
	objectiveLabel.Text = state.objective or ""
	setProgress(if state.goal > 0 then state.progress / state.goal else 0)
	progressLabel.Text = string.format("%d / %d %s", state.progress, state.goal, state.word)
	earnedLabel.Text = UI.formatCash(state.earned)
end

---------------------------------------------------------------------------
-- Phone app
---------------------------------------------------------------------------
local appContent: ScrollingFrame? = nil

local function buildJobCard(content: ScrollingFrame, id: string, order: number)
	local def = JOBS[id]
	local level = jobLevel(id)
	local lo, hi = JobsConfig.payRange(id, level)
	local steps = JobsConfig.steps(id, level)
	local card = Phone.card(content, 246, order)
	UI.stroke(def.color, 1.5, 0.5).Parent = card

	UI.label({ Text = def.icon .. "  " .. string.upper(def.name), Font = UI.FONT_BLACK, TextSize = 15, Size = UDim2.new(1, -56, 0, 18), Parent = card })
	UI.new("TextLabel", {
		Text = "LV " .. level,
		Font = UI.FONT_BLACK,
		TextSize = 12,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = def.color,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(50, 18),
		Parent = card,
	}, { UI.corner(9) })
	UI.label({ Text = string.format("$%d–$%d per shift", lo, hi), Font = UI.FONT_BLACK, TextSize = 16, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 18), Parent = card })
	UI.label({ Text = string.format("%d %s  ·  pay x%.2f", steps, def.stepWord, JobsConfig.payMult(id, level)), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 41), Size = UDim2.new(1, 0, 0, 13), Parent = card })

	local maxed = level >= JobsConfig.MAX_LEVEL
	local toNext = JobsConfig.xpToNext(level)
	local _, setXP = UI.bar({ Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 0, 7), Parent = card }, colors.xp)
	setXP(if maxed then 1 else jobXP(id) / toNext)
	UI.label({ Text = if maxed then "MAX LEVEL" else string.format("%d / %d job XP", jobXP(id), toNext), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 67), Size = UDim2.new(1, 0, 0, 13), Parent = card })

	UI.label({ Text = def.blurb, TextSize = 12, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 0, 44), Parent = card })

	local reqText = "Requirement: " .. def.requirement
	local reqColor = colors.subtext
	if id == "Taxi" then
		local has = ownsCar()
		if has == true then
			reqText ..= "  ✓"
			reqColor = colors.cash
		elseif has == false then
			reqText = "Requirement: own a car. Buy one at Budget Wheels."
			reqColor = colors.danger
		end
	end
	UI.label({ Text = reqText, TextSize = 11, TextWrapped = true, TextColor3 = reqColor, Position = UDim2.fromOffset(0, 130), Size = UDim2.new(1, 0, 0, 26), Parent = card })
	local nu = nextUnlock(id, level)
	UI.label({
		Text = if nu then string.format("Next unlock (LV %d): %s", nu.level, nu.text) else "All unlocks earned",
		TextSize = 11,
		TextWrapped = true,
		TextColor3 = colors.xp,
		Position = UDim2.fromOffset(0, 158),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = card,
	})

	local onThis = state and state.job == id
	local onOther = state and state.job ~= id
	if onThis then
		local quit = UI.button({ Text = "QUIT SHIFT", TextSize = 13, BackgroundColor3 = colors.danger, Position = UDim2.fromOffset(0, 186), Size = UDim2.new(0.62, -4, 0, 30), Parent = card })
		quit.Activated:Connect(function()
			send("quit")
		end)
	elseif onOther then
		UI.label({ Text = "Finish your current shift first", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 186), Size = UDim2.new(0.62, -4, 0, 30), Parent = card })
	else
		local start = UI.button({ Text = "START SHIFT", TextSize = 13, BackgroundColor3 = def.color, Position = UDim2.fromOffset(0, 186), Size = UDim2.new(0.62, -4, 0, 30), Parent = card })
		start.Activated:Connect(function()
			send("start", id)
		end)
	end
	local gps = UI.button({ Text = "📍 GPS", TextSize = 13, BackgroundColor3 = Color3.fromRGB(40, 120, 220), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 186), Size = UDim2.new(0.38, -4, 0, 30), Parent = card })
	gps.Activated:Connect(function()
		if onThis and state and state.target then
			Phone.setGPS(state.targetName or JobsConfig.START_NAMES[id], state.target)
		else
			Phone.setGPS(JobsConfig.START_NAMES[id], JobsConfig.START[id])
		end
	end)
end

local function renderApp()
	local content = appContent
	if not content then
		return
	end
	Phone.clear(content)
	local header = Phone.card(content, if state then 96 else 60, 0)
	if state then
		local def = JOBS[state.job]
		UI.label({ Text = "ON SHIFT  ·  " .. def.icon .. " " .. def.name, Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = def.color, Size = UDim2.new(1, 0, 0, 16), Parent = header })
		UI.label({ Text = state.objective or "", TextSize = 12, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 30), Parent = header })
		UI.label({ Text = string.format("%d/%d %s  ·  %s earned", state.progress, state.goal, state.word, UI.formatCash(state.earned)), Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 0, 16), Parent = header })
	else
		UI.label({ Text = "JOB CENTER", Font = UI.FONT_BLACK, TextSize = 15, Size = UDim2.new(1, 0, 0, 18), Parent = header })
		UI.label({ Text = "Pick a job and start a shift. Pay grows with each job's level.", TextSize = 11, TextWrapped = true, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 28), Parent = header })
	end
	for i, id in JobsConfig.ORDER do
		buildJobCard(content, id, i)
	end
end

local function buildApp(content: ScrollingFrame)
	appContent = content
	return renderApp
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function onState(kind: any, data: any)
	if kind == "state" and type(data) == "table" and JOBS[data.job] then
		local fresh = state == nil
		state = data
		if fresh then
			-- the shift's own waypoint replaces any map GPS
			Phone.clearGPS()
			summaryPanel.Visible = false
		end
		local def = JOBS[data.job]
		setWaypoint(data.target, data.targetName, def.color)
		highlight.Adornee = if typeof(data.adornee) == "Instance" then data.adornee else nil
		highlight.Enabled = highlight.Adornee ~= nil
		highlight.FillColor = def.color
		setGhost(data.ghost, def.color)
		refreshPanel()
		Phone.refresh("Jobs")
	elseif kind == "end" and type(data) == "table" then
		state = nil
		clearWaypoint()
		highlight.Adornee = nil
		highlight.Enabled = false
		setGhost(nil, colors.accent)
		refreshPanel()
		showSummary(data)
		Phone.refresh("Jobs")
	elseif kind == "open" then
		Phone.setOpen(true)
		Phone.showPage("Jobs")
	end
end

function Jobs.start()
	Phone.addApp({ id = "Jobs", label = "Jobs", icon = "💼", color = Color3.fromRGB(60, 140, 90) }, buildApp)

	task.spawn(function()
		buildHUD()
		highlight = UI.new("Highlight", {
			Name = "JobHighlight",
			FillTransparency = 0.35,
			OutlineColor = Color3.new(1, 1, 1),
			DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			Enabled = false,
			-- Highlights render reliably only inside Workspace; with no Adornee a
			-- highlight affects its parent, so keep it disabled until it has one.
			Parent = UI.new("Folder", { Name = "CityGrindJobFX", Parent = Workspace }),
		})

		local remotes = shared:WaitForChild("Remotes")
		JobAction = remotes:WaitForChild("JobAction") :: RemoteEvent
		local JobState = remotes:WaitForChild("JobState") :: RemoteEvent
		JobState.OnClientEvent:Connect(onState)

		-- refresh the app whenever job levels or ownership change
		player.AttributeChanged:Connect(function(name)
			if name:sub(1, 8) == "JobLevel" or name:sub(1, 5) == "JobXP" or name == "VehiclesOwned" then
				Phone.refresh("Jobs")
			elseif name == "Job" then
				applyAll()
			end
		end)

		-- timer, hot food / combo text, waypoint distance: 10 Hz (all whole seconds / metres)
		local hudAcc = 0
		RunService.Heartbeat:Connect(function(dt)
			hudAcc += dt
			if hudAcc < 0.1 then
				return
			end
			hudAcc = 0
			if not state then
				return
			end
			local t = Workspace:GetServerTimeNow()
			local left = (state.endsAt or t) - t
			timerLabel.Text = formatTime(left)
			timerLabel.TextColor3 = if left < 20 then colors.danger else colors.text
			local extra = ""
			if state.hotUntil then
				local hot = state.hotUntil - t
				extra = if hot > 0 then string.format("🔥 Hot for %ds — faster = bigger tip", math.ceil(hot)) else "❄️ Food went cold, no tip"
			elseif state.combo and state.combo > 0 then
				extra = string.format("⚡ Combo x%.1f", 1 + 0.1 * state.combo)
			end
			extraLabel.Text = extra
			local wp = waypoint :: any
			if wp then
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					if wp.a0.Parent ~= root then
						-- the old attachment dies with a previous character: make a new one
						if not pcall(function()
							wp.a0.Parent = root
						end) then
							wp.a0 = UI.new("Attachment", { Position = Vector3.new(0, -2.5, 0), Parent = root })
							wp.beam.Attachment0 = wp.a0
						end
					end
					local p = wp.marker.Position
					local dist = Vector3.new(root.Position.X - p.X, 0, root.Position.Z - p.Z).Magnitude
					wp.label.Text = string.format("%s  ·  %dm", wp.name, math.floor(dist / 3.57))
				end
			end
		end)

		-- pulse the ghost so the build spot is easy to spot
		task.spawn(function()
			while true do
				local g = ghost
				if g and g.Parent then
					TweenService:Create(g, TweenInfo.new(0.6), { Transparency = 0.6 }):Play()
					task.wait(0.6)
					if g.Parent then
						TweenService:Create(g, TweenInfo.new(0.6), { Transparency = 0.15 }):Play()
					end
					task.wait(0.6)
				else
					task.wait(0.5)
				end
			end
		end)

		-- job props: hide other players' markers and prompts that aren't for you
		local city = Workspace:WaitForChild("City", 60)
		local folder = city and city:WaitForChild("Jobs", 60)
		if folder then
			jobsFolder = folder
			applyAll()
			folder.DescendantAdded:Connect(function(d)
				-- attributes are set before parenting, but wait a frame for children
				task.defer(applyVisibility, d)
				if d:IsA("BasePart") and d:GetAttribute("JobOwner") ~= nil then
					task.defer(function()
						for _, sub in d:GetDescendants() do
							applyVisibility(sub)
						end
						applyVisibility(d)
					end)
				end
			end)
		end
	end)
end

return Jobs
