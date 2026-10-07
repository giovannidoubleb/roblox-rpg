-- CITY GRIND: vote + photo-submit panels for the city event kinds that need them
-- (Photo Challenge, Fashion Show). Driven by the live data the server pushes:
--   data.ballot = { title, note, entries = { { key, name, detail, mine, photo? } }, voted, canVote, endsAt }
--   data.submit = { title, note, photos = { { id, l, n, t } }, current }
-- Every tap goes to EventsRequest ("Vote" / "Submit" / "Entry"); the server
-- checks everything (one vote, not yourself, photo taken during the event...).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local EC = require(shared:WaitForChild("EventsConfig"))
local SceneSnapshot = require(shared:WaitForChild("SceneSnapshot"))

local colors = UI.colors

local EventBallot = {}

type Request = (string, ...any) -> any

local request: Request = function(_action: string, ...: any): any
	return nil
end
local panel: Frame
local titleLabel: TextLabel
local timerLabel: TextLabel
local noteLabel: TextLabel
local list: ScrollingFrame

local mode: string? = nil -- "ballot" | "submit"
local eventId: string? = nil
local current: any = nil -- the ballot / submit table being shown
local signature = ""
local confirmKey: any = nil
local snapCache: { [string]: any } = {}

local function optionalClient(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

local function clearList()
	for _, child in list:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function close()
	panel.Visible = false
	mode = nil
	eventId = nil
	current = nil
	signature = ""
	confirmKey = nil
end
EventBallot.close = close

-- Photo fetches go one at a time (the server rate-limits them).
local nextFetchAt = 0
local function throttled<T>(fn: () -> T): T
	while os.clock() < nextFetchAt do
		task.wait(nextFetchAt - os.clock())
	end
	nextFetchAt = os.clock() + 0.4
	local result = fn()
	nextFetchAt = os.clock() + 0.4
	return result
end

-- Draws a snapshot into a small viewport, fetching it lazily.
local function thumbnail(parent: Instance, cacheKey: string, fetch: () -> any, onOpen: ((any) -> ())?)
	local view = UI.new("ViewportFrame", {
		BackgroundColor3 = Color3.fromRGB(12, 12, 16),
		Size = UDim2.new(0, 96, 1, -8),
		Position = UDim2.fromOffset(4, 4),
		Ambient = Color3.fromRGB(160, 160, 170),
		LightColor = Color3.new(1, 1, 1),
		Parent = parent,
	}, { UI.corner(8) })
	local loading = UI.label({ Text = "📷", TextSize = 18, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = view })
	task.spawn(function()
		local snap = snapCache[cacheKey]
		if not snap then
			snap = throttled(fetch)
			if snap then
				snapCache[cacheKey] = snap
			end
		end
		if not view.Parent then
			return
		end
		if not snap then
			loading.Text = "—"
			return
		end
		loading:Destroy()
		pcall(SceneSnapshot.render, view, snap, { maxParts = 160 })
		if onOpen then
			local tap = UI.new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = view })
			tap.Activated:Connect(function()
				onOpen(snap)
			end)
		end
	end)
end

local function openBig(snap: any, title: string, sub: string)
	local Media = optionalClient("Media")
	if Media and Media.openViewer then
		pcall(Media.openViewer, { snap = snap, title = title, sub = sub, actions = {} })
	end
end

local renderBallot: () -> ()

local function castVote(key: any)
	if not eventId or not current then
		return
	end
	if confirmKey ~= key then
		confirmKey = key
		renderBallot()
		return
	end
	confirmKey = nil
	local result = request("Vote", eventId, key)
	if result and result.ok then
		current.voted = result.voted or key
		current.canVote = false
		HUD.push("VOTE CAST", result.msg or "Vote locked in.")
	elseif result and result.msg then
		HUD.push("CAN'T VOTE", result.msg)
	end
	renderBallot()
end

function renderBallot()
	local b = current
	if not b then
		return
	end
	clearList()
	titleLabel.Text = b.title or "VOTE"
	noteLabel.Text = b.note or ""
	for i, e in b.entries or {} do
		local picked = b.voted == e.key
		local height = if e.photo then 104 else 64
		local row = UI.new("Frame", {
			BackgroundColor3 = if picked then Color3.fromRGB(110, 70, 200) else colors.panelLight,
			Size = UDim2.new(1, -4, 0, height),
			LayoutOrder = i,
			Parent = list,
		}, { UI.corner(10) })
		local left = 10
		if e.photo then
			local key = tostring(eventId) .. ":" .. tostring(e.key)
			local evId = eventId
			thumbnail(row, key, function()
				local result = request("Entry", evId, e.key)
				return if result and result.ok then result.snap else nil
			end, function(snap)
				openBig(snap, e.name .. "'s photo", e.detail or "")
			end)
			left = 108
		end
		UI.label({
			Text = e.name .. (if e.mine then " (you)" else ""),
			Font = UI.FONT_BOLD,
			TextSize = 13,
			Position = UDim2.fromOffset(left, 6),
			Size = UDim2.new(1, -left - 90, 0, 16),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		})
		UI.label({
			Text = e.detail or "",
			TextSize = 11,
			TextColor3 = colors.subtext,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(left, 24),
			Size = UDim2.new(1, -left - 90, 1, -28),
			Parent = row,
		})
		local label, color
		if picked then
			label, color = "✓ VOTED", Color3.fromRGB(110, 70, 200)
		elseif e.mine then
			label, color = "YOURS", Color3.fromRGB(70, 70, 80)
		elseif not b.canVote then
			label, color = "—", Color3.fromRGB(70, 70, 80)
		elseif confirmKey == e.key then
			label, color = "CONFIRM?", Color3.fromRGB(230, 150, 40)
		else
			label, color = "VOTE", Color3.fromRGB(40, 170, 90)
		end
		local button = UI.button({
			Text = label,
			TextSize = 12,
			BackgroundColor3 = color,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(78, 30),
			Parent = row,
		})
		if b.canVote and not e.mine and not picked then
			button.Activated:Connect(function()
				castVote(e.key)
			end)
		end
	end
	if #(b.entries or {}) == 0 then
		UI.label({ Text = "No entries yet.", TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 30), Parent = list })
	end
end

local function renderSubmit()
	local s = current
	if not s then
		return
	end
	clearList()
	titleLabel.Text = s.title or "SUBMIT"
	noteLabel.Text = s.note or ""
	local Media = optionalClient("Media")
	local cam = UI.button({ Text = "📷  OPEN CAMERA", TextSize = 13, BackgroundColor3 = Color3.fromRGB(60, 120, 220), Size = UDim2.new(1, -4, 0, 34), LayoutOrder = 0, Parent = list })
	cam.Activated:Connect(function()
		if Media and Media.openCamera then
			close()
			local Phone = optionalClient("Phone")
			if Phone and Phone.setOpen then
				pcall(Phone.setOpen, false)
			end
			pcall(Media.openCamera)
		else
			HUD.push("CAMERA", "Open the Camera app on your phone.")
		end
	end)
	for i, photo in s.photos or {} do
		local entered = s.current == photo.id
		local row = UI.new("Frame", {
			BackgroundColor3 = if entered then Color3.fromRGB(30, 110, 70) else colors.panelLight,
			Size = UDim2.new(1, -4, 0, 96),
			LayoutOrder = i,
			Parent = list,
		}, { UI.corner(10) })
		thumbnail(row, "own:" .. photo.id, function()
			return if Media and Media.fetchPhoto then Media.fetchPhoto(photo.id) else nil
		end, function(snap)
			openBig(snap, "Your photo", tostring(photo.l or ""))
		end)
		UI.label({ Text = tostring(photo.l or "Photo"), Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(108, 8), Size = UDim2.new(1, -200, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		UI.label({
			Text = string.format("%d in frame · %s", tonumber(photo.n) or 0, UI.timeAgo(tonumber(photo.t) or os.time())),
			TextSize = 11,
			TextColor3 = colors.subtext,
			Position = UDim2.fromOffset(108, 28),
			Size = UDim2.new(1, -200, 0, 14),
			Parent = row,
		})
		local button = UI.button({
			Text = if entered then "✓ ENTERED" else "SUBMIT",
			TextSize = 12,
			BackgroundColor3 = if entered then Color3.fromRGB(30, 110, 70) else Color3.fromRGB(40, 170, 90),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(84, 30),
			Parent = row,
		})
		if not entered then
			button.Activated:Connect(function()
				if not eventId then
					return
				end
				button.Text = "…"
				local result = request("Submit", eventId, photo.id)
				if result and result.ok then
					s.current = photo.id
					HUD.push("PHOTO CHALLENGE", result.msg or "Submitted.")
				else
					HUD.push("NOT ACCEPTED", if result and result.msg then result.msg else "Couldn't submit that photo.")
				end
				renderSubmit()
			end)
		end
	end
	if #(s.photos or {}) == 0 then
		UI.label({
			Text = "No photos taken since the challenge started yet. Open the Camera, snap one that fits the theme, then come back here.",
			TextSize = 12,
			TextColor3 = colors.subtext,
			TextWrapped = true,
			Size = UDim2.new(1, -4, 0, 48),
			LayoutOrder = 1,
			Parent = list,
		})
	end
end

local function sigOf(kind: string, data: any): string
	local bits = { kind }
	if kind == "ballot" then
		table.insert(bits, tostring(data.voted))
		table.insert(bits, tostring(data.canVote))
		for _, e in data.entries or {} do
			table.insert(bits, tostring(e.key))
		end
	else
		table.insert(bits, tostring(data.current))
		for _, p in data.photos or {} do
			table.insert(bits, tostring(p.id))
		end
	end
	return table.concat(bits, "|")
end

-- Opens the panel for an event's ballot ("ballot") or photo picker ("submit").
function EventBallot.open(kind: string, id: string, data: any)
	if type(data) ~= "table" then
		return
	end
	mode = kind
	eventId = id
	current = table.clone(data)
	signature = sigOf(kind, data)
	confirmKey = nil
	panel.Visible = true
	if kind == "ballot" then
		renderBallot()
	else
		renderSubmit()
	end
end

-- New live data for an event: refresh the open panel only when it changed.
function EventBallot.update(id: string, live: any)
	if not panel.Visible or eventId ~= id or not mode then
		return
	end
	local data = if mode == "ballot" then live.ballot else live.submit
	if type(data) ~= "table" then
		close()
		return
	end
	if current then
		current.endsAt = data.endsAt or current.endsAt
	end
	local sig = sigOf(mode, data)
	if sig ~= signature then
		EventBallot.open(mode, id, data)
	end
end

function EventBallot.isOpenFor(id: string): boolean
	return panel ~= nil and panel.Visible and eventId == id
end

function EventBallot.build(gui: ScreenGui, requestFn: Request)
	request = requestFn
	panel = UI.new("Frame", {
		Name = "EventBallot",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.04,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 380, 0.75, 0),
		Visible = false,
		ZIndex = 5,
		Parent = gui,
	}, { UI.corner(16), UI.padding(14), UI.stroke(Color3.fromRGB(255, 120, 60), 2, 0.2) })
	UI.new("UISizeConstraint", { MaxSize = Vector2.new(380, 560), MinSize = Vector2.new(260, 260), Parent = panel })
	titleLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 17, Size = UDim2.new(1, -40, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd, Parent = panel })
	timerLabel = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.stamina, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, -40, 0, 14), Parent = panel })
	noteLabel = UI.label({ Text = "", TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, 0, 0, 30), Parent = panel })
	local closeButton = UI.button({ Text = "✕", TextSize = 16, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(32, 32), Parent = panel })
	closeButton.Activated:Connect(close)
	list = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 74),
		Size = UDim2.new(1, 0, 1, -74),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = panel,
	}, { UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	local timerAcc = 0
	RunService.Heartbeat:Connect(function(dt)
		timerAcc += dt
		if timerAcc < 0.25 then
			return
		end
		timerAcc = 0
		if panel.Visible and current then
			local left = (current.endsAt or 0) - Workspace:GetServerTimeNow()
			if mode == "ballot" then
				timerLabel.Text = if left > 0 then "Voting closes in " .. EC.formatIn(left) else "Counting votes…"
			else
				timerLabel.Text = if left > 0 then "Submissions close in " .. EC.formatIn(left) else "Submissions closed"
			end
		end
	end)
end

return EventBallot
