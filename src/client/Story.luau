-- CITY GRIND: story client (spec 83, 109, 110).
--   * First-join cinematic: a letterboxed camera fly-over of the city built
--     from what exists at runtime (a court, Downtown, Budget Wheels, the Beach,
--     Luxury, Maple Court), with the two captions and a SKIP button, then the
--     camera returns to the player.
--   * Mission tracker under the stats card (collapsible) with GPS.
--   * Mission / chapter banners (chapter complete = cutscene-lite).
--   * Story.renderTab(content, order) fills the Quests app's Story tab.
-- The server decides every mission; this only shows its state.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local SC = require(shared:WaitForChild("StoryConfig"))
local QC = require(shared:WaitForChild("QuestsConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Story = {}

local ACCENT = Color3.fromRGB(255, 200, 60)

local state: any = nil
local requestRemote: RemoteFunction? = nil
local gui: ScreenGui? = nil
local collapsed = false
local cinematicPlaying = false
local cinematicDone = false

Story.changed = Instance.new("BindableEvent")

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function questsClient(): any
	local module = script.Parent:FindFirstChild("Quests")
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

local function currentMission(): (SC.Chapter?, SC.Mission?)
	if not state or state.done then
		return nil, nil
	end
	local chapter = SC.CHAPTERS[state.chapter]
	return chapter, chapter and chapter.missions[state.mission]
end

local function progressText(m: SC.Mission): string
	local p = state.progress or 0
	if m.goal <= 1 and not m.alt then
		return if p >= m.goal then "Done" else "Not yet"
	end
	local text = QC.formatValue(m.metric, p) .. " / " .. QC.formatValue(m.metric, m.goal)
	if m.alt then
		text ..= "   (" .. QC.formatValue(m.alt.metric, state.altProgress or 0) .. " / " .. QC.formatValue(m.alt.metric, m.alt.goal) .. ")"
	end
	return text
end

local function setGPS()
	if state and state.gps then
		Phone.setGPS(state.gps.name, Vector3.new(state.gps.x, state.gps.y, state.gps.z))
	end
end

---------------------------------------------------------------------------
-- Mission tracker (under the HUD stats card)
---------------------------------------------------------------------------
local refreshTracker: () -> ()

local function buildTracker(root: ScreenGui)
	local panel = UI.new("Frame", {
		Name = "StoryTracker",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 112),
		Size = UDim2.fromOffset(230, 32),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = root,
	}, { UI.corner(12), UI.padding(8), UI.stroke(ACCENT, 1, 0.6) })
	UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = panel })

	local header = UI.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 1, Parent = panel })
	local title = UI.label({ Name = "Title", Text = "", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = ACCENT, Size = UDim2.new(1, -24, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = header })
	local toggle = UI.button({ Name = "Toggle", Text = "–", TextSize = 14, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 4, 0, -4), Size = UDim2.fromOffset(24, 24), Parent = header })

	local body = UI.new("Frame", { Name = "Body", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = panel })
	UI.new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder, Parent = body })
	local objective = UI.label({ Name = "Objective", Text = "", Font = UI.FONT_BOLD, TextSize = 14, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
	local alt = UI.label({ Name = "Alt", Text = "", TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = body })
	local progress = UI.label({ Name = "Progress", Text = "", TextSize = 12, TextColor3 = colors.xp, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 3, Parent = body })
	local buttons = UI.new("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 4, Parent = body })
	local gpsButton = UI.button({ Text = "📍 GPS", TextSize = 12, BackgroundColor3 = Color3.fromRGB(40, 110, 170), Size = UDim2.new(0.5, -3, 1, 0), Parent = buttons })
	local moreButton = UI.button({ Text = "QUESTS", TextSize = 12, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.5, -3, 1, 0), Parent = buttons })

	gpsButton.Activated:Connect(setGPS)
	moreButton.Activated:Connect(function()
		local Q = questsClient()
		if Q and Q.open then
			Q.open("Story")
		end
	end)
	toggle.Activated:Connect(function()
		collapsed = not collapsed
		refreshTracker()
	end)

	refreshTracker = function()
		local chapter, m = currentMission()
		panel.Visible = chapter ~= nil and m ~= nil and state.active and not cinematicPlaying
		if not panel.Visible or not chapter or not m then
			return
		end
		title.Text = string.format("CH %d · %s", state.chapter, chapter.name:upper())
		toggle.Text = if collapsed then "+" else "–"
		body.Visible = not collapsed
		objective.Text = m.text
		alt.Text = if m.alt then m.alt.text elseif m.hint then m.hint else ""
		alt.Visible = alt.Text ~= ""
		progress.Text = progressText(m)
		gpsButton.Visible = state.gps ~= nil
		moreButton.Size = if state.gps then UDim2.new(0.5, -3, 1, 0) else UDim2.new(1, 0, 1, 0)
	end
end

---------------------------------------------------------------------------
-- Banners
---------------------------------------------------------------------------
local function fadeOutAll(frame: Instance, seconds: number)
	local info = TweenInfo.new(seconds)
	for _, d in frame:GetDescendants() do
		if d:IsA("TextLabel") then
			TweenService:Create(d, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		elseif d:IsA("Frame") then
			TweenService:Create(d, info, { BackgroundTransparency = 1 }):Play()
		end
	end
	if frame:IsA("Frame") then
		TweenService:Create(frame, info, { BackgroundTransparency = 1 }):Play()
	end
end

local function showMissionBanner(titleText: string, subtitle: string)
	if not gui then
		return
	end
	local holder = UI.new("Frame", {
		Name = "MissionBanner",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.new(1, 0, 0, 78),
		Parent = gui,
	})
	UI.new("Frame", { BackgroundColor3 = ACCENT, Size = UDim2.new(1, 0, 0, 2), Parent = holder })
	UI.new("Frame", { BackgroundColor3 = ACCENT, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 2), Parent = holder })
	local t = UI.label({ Text = titleText, Font = UI.FONT_BLACK, TextSize = 30, TextColor3 = ACCENT, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 34), Parent = holder })
	UI.label({ Text = subtitle, Font = UI.FONT_BOLD, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 22), Parent = holder })
	t.TextTransparency = 1
	TweenService:Create(t, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
	task.wait(3.6)
	fadeOutAll(holder, 0.5)
	task.wait(0.55)
	holder:Destroy()
end

-- Banners play one after another (a returning player can finish several at once).
local bannerQueue: { { string } } = {}
local bannerBusy = false
local function missionBanner(titleText: string, subtitle: string)
	table.insert(bannerQueue, { titleText, subtitle })
	if bannerBusy then
		return
	end
	bannerBusy = true
	task.spawn(function()
		while #bannerQueue > 0 do
			local entry = table.remove(bannerQueue, 1) :: { string }
			while cinematicPlaying do
				task.wait(0.5)
			end
			showMissionBanner(entry[1], entry[2])
		end
		bannerBusy = false
	end)
end

-- Cutscene-lite: letterbox bars slide in around a big banner.
local function chapterBanner(info: any)
	if not gui or type(info) ~= "table" then
		return
	end
	local root = UI.new("Frame", { Name = "ChapterComplete", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 30, Parent = gui })
	local top = UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), Size = UDim2.new(1, 0, 0.13, 0), Position = UDim2.fromScale(0, -0.13), ZIndex = 30, Parent = root })
	local bottom = UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), AnchorPoint = Vector2.new(0, 1), Size = UDim2.new(1, 0, 0.13, 0), Position = UDim2.fromScale(0, 1.13), ZIndex = 30, Parent = root })
	TweenService:Create(top, TweenInfo.new(0.5), { Position = UDim2.fromScale(0, 0) }):Play()
	TweenService:Create(bottom, TweenInfo.new(0.5), { Position = UDim2.fromScale(0, 1) }):Play()

	local heading = if info.last then "STORY COMPLETE" else "CHAPTER " .. tostring(info.chapter) .. " COMPLETE"
	local big = UI.label({ Text = heading, Font = UI.FONT_BLACK, TextSize = 40, TextColor3 = ACCENT, TextStrokeTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42), Size = UDim2.new(1, 0, 0, 46), ZIndex = 31, Parent = root })
	UI.label({ Text = tostring(info.name):upper(), Font = UI.FONT_BLACK, TextSize = 22, TextStrokeTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 0, 0, 28), ZIndex = 31, Parent = root })
	UI.label({
		Text = string.format("+$%s   +%s XP   +%d rep", QC.commas(info.cash or 0), QC.commas(info.xp or 0), info.rep or 0),
		Font = UI.FONT_BOLD,
		TextSize = 18,
		TextColor3 = colors.cash,
		TextStrokeTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.57),
		Size = UDim2.new(1, 0, 0, 24),
		ZIndex = 31,
		Parent = root,
	})
	local scale = UI.new("UIScale", { Scale = 0.6, Parent = big })
	TweenService:Create(scale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	HUD.push(heading, tostring(info.name) .. " finished. Coach Ray texted you.")
	task.delay(5, function()
		TweenService:Create(top, TweenInfo.new(0.5), { Position = UDim2.fromScale(0, -0.13) }):Play()
		TweenService:Create(bottom, TweenInfo.new(0.5), { Position = UDim2.fromScale(0, 1.13) }):Play()
		for _, d in root:GetChildren() do
			if d:IsA("TextLabel") then
				TweenService:Create(d, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			end
		end
		task.wait(0.6)
		root:Destroy()
	end)
end

---------------------------------------------------------------------------
-- First-join cinematic (109)
---------------------------------------------------------------------------
type Shot = { focus: Vector3, radius: number, height: number }

local function boxOf(inst: Instance): (Vector3?, Vector3?)
	if inst:IsA("Model") then
		local cf, size = inst:GetBoundingBox()
		return cf.Position, size
	elseif inst:IsA("BasePart") then
		return inst.Position, inst.Size
	end
	return nil, nil
end

local function gatherShots(): { Shot }
	local shots: { Shot } = {}
	local city = Workspace:FindFirstChild("City")
	local function add(pos: Vector3?, size: number)
		if pos then
			table.insert(shots, { focus = Vector3.new(pos.X, math.max(pos.Y, 0) + 4, pos.Z), radius = math.clamp(size * 0.6, 45, 220), height = math.clamp(size * 0.35, 28, 140) })
		end
	end
	local function district(name: string)
		local folder = city and city:FindFirstChild("Districts")
		local d = folder and folder:FindFirstChild(name)
		if not d then
			return
		end
		local center, size = d:GetAttribute("Center"), d:GetAttribute("Size")
		if typeof(center) == "Vector3" then
			add(center, if typeof(size) == "Vector3" then math.max(size.X, size.Z) * 0.5 else 160)
		end
	end
	local function building(...: string)
		local buildings = city and city:FindFirstChild("Buildings")
		local model
		for _, name in { ... } do
			model = model or (buildings and buildings:FindFirstChild(name, true))
		end
		if model then
			local pos, size = boxOf(model)
			add(pos, if size then math.max(size.X, size.Z) * 1.4 else 80)
		end
	end

	-- a court (the Neighborhood court first if it exists)
	local courts = CollectionService:GetTagged("Court")
	table.sort(courts, function(a, b)
		return a.Name < b.Name
	end)
	for _, court in courts do
		local c = court:GetAttribute("CourtCenter")
		if typeof(c) == "Vector3" and court:IsDescendantOf(Workspace) then
			add(c, 70)
			break
		end
	end
	district("Downtown")
	building("BudgetWheels", "Budget Wheels")
	district("Beach")
	district("Luxury")
	building("Starter Apartments")
	return shots
end

local function controls(enabled: boolean)
	pcall(function()
		local module = player:WaitForChild("PlayerScripts", 2) and player.PlayerScripts:FindFirstChild("PlayerModule")
		if module then
			local controlModule = (require :: any)(module):GetControls()
			if enabled then
				controlModule:Enable()
			else
				controlModule:Disable()
			end
		end
	end)
end

local function finishCinematic()
	if cinematicDone then
		return
	end
	cinematicDone = true
	if requestRemote then
		local ok, result = pcall(function()
			return (requestRemote :: RemoteFunction):InvokeServer("CinematicDone")
		end)
		if ok and type(result) == "table" then
			state = result
			Story.changed:Fire()
		end
	end
	if refreshTracker then
		refreshTracker()
	end
end

local function playCinematic()
	if cinematicPlaying or cinematicDone or not gui then
		return
	end
	cinematicPlaying = true
	if refreshTracker then
		refreshTracker()
	end
	local camera = Workspace.CurrentCamera
	local gathered, shots = pcall(gatherShots)
	if not camera or not gathered or #shots == 0 then
		cinematicPlaying = false
		finishCinematic()
		return
	end
	local root: Frame? = nil
	-- Anything below may fail (a part removed mid-shot, a missing character):
	-- the camera, HUD and controls are always restored afterwards.
	local ok, err = pcall(function()
		pcall(Phone.setOpen, false)
		HUD.setVisible(false)
		controls(false)

		local skipped = false
		local rootFrame = UI.new("Frame", { Name = "Cinematic", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = gui })
		root = rootFrame
		local top = UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), Size = UDim2.new(1, 0, 0.12, 0), ZIndex = 50, Parent = rootFrame })
		UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.12, 0), ZIndex = 50, Parent = rootFrame })
		local fader = UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0, Size = UDim2.fromScale(1, 1), ZIndex = 52, Parent = rootFrame })
		local caption = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 34, TextStrokeTransparency = 0.4, TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.78), Size = UDim2.new(1, -40, 0, 44), ZIndex = 53, Parent = rootFrame })
		local logo = UI.label({ Text = "CITY GRIND", Font = UI.FONT_BLACK, TextSize = 18, TextColor3 = ACCENT, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 20, 0.06, -10), Size = UDim2.fromOffset(200, 20), ZIndex = 53, Parent = top })
		logo.TextTransparency = 0.2
		local skip = UI.button({ Text = "SKIP  ▶▶", TextSize = 15, BackgroundColor3 = Color3.fromRGB(40, 40, 46), AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -20, 1, -16), Size = UDim2.fromOffset(110, 36), ZIndex = 54, Parent = rootFrame })
		skip.Activated:Connect(function()
			skipped = true
		end)

		local function say(text: string)
			caption.Text = text
			caption.TextTransparency = 1
			TweenService:Create(caption, TweenInfo.new(0.8), { TextTransparency = 0 }):Play()
		end
		local function unsay()
			TweenService:Create(caption, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		end
		-- waits while watching for SKIP
		local function hold(seconds: number): boolean
			local deadline = os.clock() + seconds
			while os.clock() < deadline do
				if skipped then
					return false
				end
				task.wait()
			end
			return true
		end

		camera.CameraType = Enum.CameraType.Scriptable
		local lines = SC.CINEMATIC_LINES
		local SHOT_TIME = 4.2
		local lineAt = { [1] = 1, [math.max(2, #shots - 1)] = 2 }
		for i, shot in shots do
			if skipped then
				break
			end
			local angle = math.rad(35 + i * 70)
			local function at(a: number): CFrame
				local offset = Vector3.new(math.cos(a) * shot.radius, shot.height, math.sin(a) * shot.radius)
				return CFrame.lookAt(shot.focus + offset, shot.focus)
			end
			camera.CFrame = at(angle)
			local move = TweenService:Create(camera, TweenInfo.new(SHOT_TIME, Enum.EasingStyle.Linear), { CFrame = at(angle + math.rad(38)) })
			move:Play()
			TweenService:Create(fader, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
			if lineAt[i] and lines[lineAt[i]] then
				say(lines[lineAt[i]])
			end
			if not hold(SHOT_TIME - 0.5) then
				move:Cancel()
				break
			end
			if lineAt[i] then
				unsay()
			end
			TweenService:Create(fader, TweenInfo.new(0.45), { BackgroundTransparency = 0 }):Play()
			if not hold(0.5) then
				move:Cancel()
				break
			end
			move:Cancel()
		end

		-- back to the player
		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		if head and head:IsA("BasePart") and not skipped then
			local target = CFrame.lookAt(head.Position - head.CFrame.LookVector * 12 + Vector3.new(0, 4, 0), head.Position)
			camera.CFrame = CFrame.lookAt(head.Position + Vector3.new(0, 120, 60), head.Position)
			TweenService:Create(fader, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
			local back = TweenService:Create(camera, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { CFrame = target })
			back:Play()
			hold(2.2)
			back:Cancel()
		end
	end)
	if not ok then
		warn("[CityGrind] Story cinematic failed:", err)
	end
	local cam = Workspace.CurrentCamera or camera
	cam.CameraType = Enum.CameraType.Custom
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		cam.CameraSubject = humanoid
	end
	if root then
		root:Destroy()
	end
	HUD.setVisible(true)
	controls(true)
	cinematicPlaying = false
	finishCinematic()
end

---------------------------------------------------------------------------
-- Story tab in the Quests app
---------------------------------------------------------------------------
function Story.renderTab(content: Instance, order: number)
	if not state then
		local c = Phone.card(content, 44, order)
		UI.label({ Text = "Loading your story...", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.fromScale(1, 1), Parent = c })
		return
	end
	if state.done then
		local c = Phone.card(content, 92, order)
		UI.label({ Text = "🏙️ STORY COMPLETE", Font = UI.FONT_BLACK, TextSize = 16, TextColor3 = ACCENT, Size = UDim2.new(1, 0, 0, 20), Parent = c })
		UI.label({ Text = "From nobody to the top of the city. Keep grinding: daily quests, weekly quests and achievements never stop.", TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 44), TextYAlignment = Enum.TextYAlignment.Top, Parent = c })
	else
		local chapter, m = currentMission()
		if chapter then
			-- chapter header + mission list
			local missions = chapter.missions
			local head = Phone.card(content, 56 + #missions * 34, order)
			UI.label({ Text = string.format("CHAPTER %d OF %d", state.chapter, state.chapterCount or #SC.CHAPTERS), Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = head })
			UI.label({ Text = chapter.name:upper(), Font = UI.FONT_BLACK, TextSize = 18, TextColor3 = ACCENT, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 22), Parent = head })
			for i, mission in missions do
				local status = state.statuses and state.statuses[i] and state.statuses[i].status or "todo"
				local icon = if status == "done" then "✅" elseif status == "current" then "▶️" elseif status == "skipped" then "➖" else "⬜"
				local text = mission.text .. (if status == "skipped" then " (not in this city yet)" else "")
				UI.label({
					Text = icon .. "  " .. text,
					TextSize = 12,
					Font = if status == "current" then UI.FONT_BOLD else UI.FONT,
					TextColor3 = if status == "current" then colors.text else colors.subtext,
					TextWrapped = true,
					TextYAlignment = Enum.TextYAlignment.Top,
					Position = UDim2.fromOffset(0, 44 + (i - 1) * 34),
					Size = UDim2.new(1, 0, 0, 32),
					Parent = head,
				})
			end
			-- current objective
			if m then
				local c = Phone.card(content, 116, order + 1)
				UI.stroke(ACCENT, 1.2, 0.3).Parent = c
				UI.label({ Text = "CURRENT MISSION", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = ACCENT, Size = UDim2.new(1, 0, 0, 14), Parent = c })
				UI.label({ Text = m.text, Font = UI.FONT_BOLD, TextSize = 14, TextWrapped = true, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 34), TextYAlignment = Enum.TextYAlignment.Top, Parent = c })
				local sub = progressText(m)
				if m.alt then
					sub ..= "\n" .. m.alt.text
				elseif m.hint then
					sub ..= "\n" .. m.hint
				end
				UI.label({ Text = sub, TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 0, 30), TextYAlignment = Enum.TextYAlignment.Top, Parent = c })
				if state.gps then
					local gps = UI.button({ Text = "📍 SET GPS: " .. state.gps.name, TextSize = 12, BackgroundColor3 = Color3.fromRGB(40, 110, 170), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 26), Parent = c })
					gps.Activated:Connect(setGPS)
				end
			end
			local reward = Phone.card(content, 40, order + 2)
			UI.label({
				Text = string.format("Chapter reward: $%s  ·  %s XP  ·  %d rep", QC.commas(chapter.cash), QC.commas(chapter.xp), chapter.rep),
				TextSize = 12,
				Font = UI.FONT_BOLD,
				TextColor3 = colors.cash,
				TextWrapped = true,
				Size = UDim2.fromScale(1, 1),
				Parent = reward,
			})
		end
	end
	-- every chapter at a glance
	local list = Phone.card(content, 20 + #SC.CHAPTERS * 20, order + 3)
	UI.label({ Text = "CHAPTERS", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = list })
	for i, chapter in SC.CHAPTERS do
		local finished = state.done or i < state.chapter
		local current = not state.done and i == state.chapter
		UI.label({
			Text = (if finished then "✅ " elseif current then "▶️ " else "🔒 ") .. i .. ". " .. chapter.name,
			TextSize = 12,
			Font = if current then UI.FONT_BOLD else UI.FONT,
			TextColor3 = if current then ACCENT elseif finished then colors.text else colors.subtext,
			Position = UDim2.fromOffset(0, 16 + (i - 1) * 20),
			Size = UDim2.new(1, 0, 0, 18),
			Parent = list,
		})
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function onState(newState: any)
	if type(newState) ~= "table" then
		return
	end
	state = newState
	if refreshTracker then
		refreshTracker()
	end
	Story.changed:Fire()
	local Q = questsClient()
	if Q and Q.refresh then
		Q.refresh()
	end
end

local function setup()
	local remotes = shared:WaitForChild("Remotes")
	requestRemote = remotes:WaitForChild("StoryRequest") :: RemoteFunction
	local event = remotes:WaitForChild("StoryEvent") :: RemoteEvent

	gui = UI.new("ScreenGui", {
		Name = "CityGrindStory",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 20,
		Parent = player:WaitForChild("PlayerGui"),
	})
	-- The tracker sits with the HUD (low display order) so the phone covers it.
	local trackerGui = UI.new("ScreenGui", {
		Name = "CityGrindStoryTracker",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 1,
		Parent = player:WaitForChild("PlayerGui"),
	})
	buildTracker(trackerGui)

	event.OnClientEvent:Connect(function(kind: any, a: any, b: any)
		if kind == "State" then
			onState(a)
		elseif kind == "Cinematic" then
			task.spawn(playCinematic)
		elseif kind == "Mission" and type(a) == "string" and type(b) == "string" then
			missionBanner(a, b)
		elseif kind == "Chapter" then
			chapterBanner(a)
		end
	end)

	if not player:GetAttribute("DataLoaded") then
		player:GetAttributeChangedSignal("DataLoaded"):Wait()
	end
	local ok, result = pcall(function()
		return (requestRemote :: RemoteFunction):InvokeServer("Get")
	end)
	if ok and type(result) == "table" then
		onState(result)
	end
	-- the Cinematic event may have fired before we were listening
	if player:GetAttribute("StoryCinematic") == true then
		task.spawn(playCinematic)
	end
end

function Story.start()
	task.spawn(setup)
end

-- Exposed for other client modules (e.g. a future map overlay).
function Story.state(): any
	return state
end

return Story
