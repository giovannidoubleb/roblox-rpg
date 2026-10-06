-- CITY GRIND: Music app (spec section 42).
-- An original procedural music player: a step sequencer that plays the
-- patterns in MusicConfig by triggering built-in client sounds with
-- PlaybackSpeed pitch shifting. At start it checks which samples really load
-- on this device and only uses those; if none load the app says so honestly.
-- Playback is local to this player, so it keeps going while walking, driving
-- or at home. Music volume is separate from notification sounds.
--
-- API (other client modules, e.g. CityTok's editor):
--   Music.tracks() -> { { id, name, bpm, style } }
--   Music.preview(id) -> boolean   plays one track on loop
--   Music.stop()                   stops playback (and any preview)
--   Music.isAvailable() -> boolean?  nil while still checking samples

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent:WaitForChild("UI"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local MC = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("MusicConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Music = {}

local APP_ID = "Music"
local APP_COLOR = Color3.fromRGB(230, 60, 140)
local POOL_SIZES = { tone = 10, kick = 3, snare = 3, hat = 4, fx = 2 }

type Instrument = { sample: MC.Sample, pool: { Sound }, nextVoice: number, tokens: { [Sound]: any } }

local available: boolean? = nil -- nil while probing
local instruments: { [string]: Instrument } = {}
local group: SoundGroup
local volume = 0.5

-- playback state
local trackIndex = 1
local playing = false
local previewing = false
local step = 0 -- 16th steps since the track started
local loopCount = 1
local nextStepAt = 0
local listeners: { () -> () } = {}

local function changed()
	for _, fn in listeners do
		task.spawn(fn)
	end
end

---------------------------------------------------------------------------
-- Sample probe
---------------------------------------------------------------------------
local function probe(sample: MC.Sample): Sound?
	local sound = Instance.new("Sound")
	sound.Name = "MusicProbe"
	sound.SoundId = sample.id
	sound.Volume = 0
	sound.Parent = SoundService
	local status = nil
	pcall(function()
		ContentProvider:PreloadAsync({ sound }, function(_, fetchStatus)
			status = fetchStatus
		end)
	end)
	local deadline = os.clock() + 4
	while not sound.IsLoaded and os.clock() < deadline and status ~= Enum.AssetFetchStatus.Failure do
		task.wait(0.1)
	end
	if sound.IsLoaded and sound.TimeLength > 0 then
		return sound
	end
	sound:Destroy()
	return nil
end

local function setupInstruments()
	group = Instance.new("SoundGroup")
	group.Name = "CityGrindMusic"
	group.Volume = volume
	group.Parent = SoundService

	local pending = 0
	for role, candidates in MC.SAMPLES do
		pending += 1
		task.spawn(function()
			for _, sample in candidates do
				local ok, sound = pcall(probe, sample)
				if ok and sound then
					sound.Name = "Music_" .. role
					sound.SoundGroup = group
					local pool = { sound }
					for _ = 2, POOL_SIZES[role] or 2 do
						local clone = sound:Clone()
						clone.Parent = SoundService
						table.insert(pool, clone)
					end
					instruments[role] = { sample = sample, pool = pool, nextVoice = 1, tokens = {} }
					break
				end
			end
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait(0.1)
	end
	available = next(instruments) ~= nil
	changed()
end

---------------------------------------------------------------------------
-- Voices
---------------------------------------------------------------------------
local function trigger(role: string, semitones: number, gain: number, length: number?)
	local inst = instruments[role]
	if not inst then
		return
	end
	local sound = inst.pool[inst.nextVoice]
	inst.nextVoice = inst.nextVoice % #inst.pool + 1
	sound:Stop()
	sound.PlaybackSpeed = math.clamp(inst.sample.speed * 2 ^ (semitones / 12), 0.05, 8)
	sound.Volume = math.clamp(inst.sample.volume * gain, 0, 3)
	sound.TimePosition = 0
	sound:Play()
	local gate = length or inst.sample.maxLength
	if gate then
		local token = {}
		inst.tokens[sound] = token
		task.delay(gate, function()
			if inst.tokens[sound] == token then
				sound:Stop()
			end
		end)
	end
end

local function stopAllVoices()
	for _, inst in instruments do
		for _, sound in inst.pool do
			sound:Stop()
		end
		table.clear(inst.tokens)
	end
end

---------------------------------------------------------------------------
-- Sequencer
---------------------------------------------------------------------------
local function track(): MC.Track
	return MC.TRACKS[trackIndex]
end

local function stepSeconds(t: MC.Track): number
	return 60 / t.bpm / 4
end

local function barsOf(t: MC.Track): number
	return #t.lead
end

local function loopSeconds(t: MC.Track): number
	return barsOf(t) * 16 * stepSeconds(t)
end

local function loopsOf(t: MC.Track): number
	return math.max(3, math.floor(t.targetSeconds / loopSeconds(t) + 0.5))
end

local function durationOf(t: MC.Track): number
	return loopsOf(t) * loopSeconds(t)
end

local function degreeSemis(scaleName: string, degree: number): number
	local scale = MC.SCALES[scaleName] or MC.SCALES.major
	local i = degree - 1
	local octave = i // 7
	return scale[i % 7 + 1] + 12 * octave
end

local function charDegree(ch: string): number?
	local n = tonumber(ch)
	if n and n >= 1 then
		return n
	end
	local b = string.byte(ch)
	if b >= 65 and b <= 69 then -- A-E
		return b - 64 + 9
	end
	return nil
end

local function lineFor(pattern: string | { string }, bar: number): string
	if type(pattern) == "table" then
		return pattern[(bar - 1) % #pattern + 1]
	end
	return pattern :: string
end

-- How many 16ths a note at `pos` lasts (1 + following '-').
local function noteLength(line: string, pos: number): number
	local n = 1
	for i = pos + 1, #line do
		if line:sub(i, i) == "-" then
			n += 1
		else
			break
		end
	end
	return n
end

local function drumGain(ch: string): number
	if ch == "X" then
		return 1.25
	elseif ch == "g" then
		return 0.45
	elseif ch == "x" then
		return 1
	end
	return 0
end

local function playStep(t: MC.Track, s: number, loop: number, loops: number)
	local bars = barsOf(t)
	local bar = (s // 16) % bars + 1
	local pos = s % 16 + 1
	local sec = stepSeconds(t)
	local intro = loop == 1
	local outro = loop == loops and loops > 2

	-- drums: the intro skips the kick for the first half, the outro keeps only hats
	if not outro then
		local k = drumGain(lineFor(t.kick, bar):sub(pos, pos))
		if k > 0 and not (intro and bar <= bars / 2) then
			trigger("kick", 0, k)
		end
		local sn = drumGain(lineFor(t.snare, bar):sub(pos, pos))
		if sn > 0 and not intro then
			trigger("snare", 0, sn)
		end
	end
	local h = drumGain(lineFor(t.hat, bar):sub(pos, pos))
	if h > 0 then
		trigger("hat", if pos % 2 == 0 then 1 else 0, h)
	end

	-- harmony
	local root = t.chords[(bar - 1) % #t.chords + 1]
	local bassCh = lineFor(t.bass, bar):sub(pos, pos)
	local bassDeg = charDegree(bassCh)
	if bassDeg and not outro then
		-- bass degrees are relative to the chord root, kept inside the scale
		local semis = t.key - 12 + degreeSemis(t.scale, root + bassDeg - 1)
		trigger("tone", semis, 0.75, noteLength(lineFor(t.bass, bar), pos) * sec * 0.95)
	end
	if t.arp and pos % 2 == 1 then
		local chordTones = { 0, 2, 4, 7 }
		local idx = ((pos - 1) // 2) % #chordTones + 1
		local semis = t.key + degreeSemis(t.scale, root + chordTones[idx])
		trigger("tone", semis, if intro then 0.18 else 0.24, sec * 1.6)
	end

	-- melody (rests during the intro so the groove sets up first)
	if not intro then
		local line = t.lead[bar]
		local deg = charDegree(line:sub(pos, pos))
		if deg then
			trigger("tone", t.key + 12 + degreeSemis(t.scale, deg), 0.55, noteLength(line, pos) * sec * 0.95)
		end
	end

	-- a sweep into every new section
	if pos == 1 and bar == 1 and loop > 1 then
		trigger("fx", 0, 1)
	end
end

local function stepTime(t: MC.Track, s: number): number
	-- off-beat 16ths are pushed late by the swing amount
	local sec = stepSeconds(t)
	return s * sec + (if s % 2 == 1 then t.swing * sec else 0)
end

local trackStartedAt = 0

local function startTrack(index: number)
	trackIndex = ((index - 1) % #MC.TRACKS) + 1
	step = 0
	loopCount = 1
	stopAllVoices()
	trackStartedAt = os.clock() + 0.05
	nextStepAt = trackStartedAt
	changed()
end

local function elapsed(): number
	return math.max(0, stepTime(track(), step))
end

RunService.Heartbeat:Connect(function()
	if not playing or not available then
		return
	end
	local t = track()
	local clock = os.clock()
	-- fell far behind (window hidden, hitch): skip ahead instead of machine-gunning notes
	if clock - nextStepAt > 0.25 then
		local sec = stepSeconds(t)
		local skip = math.floor((clock - nextStepAt) / sec)
		step += skip
		trackStartedAt = clock - stepTime(t, step)
		nextStepAt = trackStartedAt + stepTime(t, step)
	end
	local loops = loopsOf(t)
	local perLoop = barsOf(t) * 16
	while clock >= nextStepAt do
		loopCount = step // perLoop + 1
		if loopCount > loops then
			if previewing then
				step = 0
				loopCount = 1
				trackStartedAt = nextStepAt
			else
				startTrack(trackIndex + 1)
				return
			end
		end
		playStep(t, step, loopCount, loops)
		step += 1
		nextStepAt = trackStartedAt + stepTime(t, step)
	end
end)

local function setPlaying(on: boolean)
	if on and not available then
		return
	end
	if on == playing then
		return
	end
	playing = on
	if on then
		-- resume where we paused
		trackStartedAt = os.clock() - stepTime(track(), step)
		nextStepAt = trackStartedAt + stepTime(track(), step)
	else
		stopAllVoices()
	end
	changed()
end

local function setVolume(v: number)
	volume = math.clamp(v, 0, 1)
	if group then
		group.Volume = volume
	end
	changed()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Music.tracks(): { { id: string, name: string, bpm: number, style: string } }
	local list = {}
	for _, t in MC.TRACKS do
		table.insert(list, { id = t.id, name = t.name, bpm = t.bpm, style = t.style })
	end
	return list
end

function Music.isAvailable(): boolean?
	return available
end

function Music.preview(id: string): boolean
	if not available then
		return false
	end
	for i, t in MC.TRACKS do
		if t.id == id then
			previewing = true
			startTrack(i)
			playing = false
			setPlaying(true)
			return true
		end
	end
	return false
end

function Music.stop()
	previewing = false
	setPlaying(false)
end

function Music.setVolume(v: number)
	if type(v) == "number" and v == v then
		setVolume(v)
	end
end

---------------------------------------------------------------------------
-- UI helpers
---------------------------------------------------------------------------
local function fmt(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function instrumentsText(): string
	local have, missing = {}, {}
	for _, role in MC.ROLE_ORDER do
		if instruments[role] then
			table.insert(have, MC.ROLE_NAMES[role])
		else
			table.insert(missing, MC.ROLE_NAMES[role])
		end
	end
	local text = "Instruments: " .. table.concat(have, ", ")
	if #missing > 0 then
		text ..= "  ·  not on this device: " .. table.concat(missing, ", ")
	end
	return text
end

-- A drag slider that also works with touch, plus -/+ buttons for gamepad.
local function volumeSlider(parent: Instance, y: number)
	UI.label({ Text = "🔈", TextSize = 14, Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(20, 24), Parent = parent })
	local minus = UI.button({ Text = "–", TextSize = 16, Position = UDim2.fromOffset(22, y), Size = UDim2.fromOffset(26, 24), Parent = parent })
	local sliderTrack = UI.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(50, 50, 62),
		Position = UDim2.new(0, 56, 0, y + 8),
		Size = UDim2.new(1, -120, 0, 8),
		Parent = parent,
	}, { UI.corner(4) })
	local fill = UI.new("Frame", { BackgroundColor3 = APP_COLOR, Size = UDim2.fromScale(volume, 1), Parent = sliderTrack }, { UI.corner(4) })
	local knob = UI.new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(volume, 0.5),
		Size = UDim2.fromOffset(16, 16),
		Parent = sliderTrack,
	}, { UI.corner(8) })
	local plus = UI.button({ Text = "+", TextSize = 16, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -30, 0, y), Size = UDim2.fromOffset(26, 24), Parent = parent })
	local pct = UI.label({ Text = "", TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.fromOffset(28, 24), Parent = parent })

	local function show()
		fill.Size = UDim2.fromScale(volume, 1)
		knob.Position = UDim2.fromScale(volume, 0.5)
		pct.Text = math.floor(volume * 100 + 0.5) .. "%"
	end
	show()
	local dragging = false
	local function setFromX(x: number)
		local rel = (x - sliderTrack.AbsolutePosition.X) / math.max(1, sliderTrack.AbsoluteSize.X)
		setVolume(rel)
		show()
	end
	sliderTrack.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	minus.Activated:Connect(function()
		setVolume(volume - 0.1)
		show()
	end)
	plus.Activated:Connect(function()
		setVolume(volume + 0.1)
		show()
	end)
	table.insert(listeners, show)
end

local function playPauseText(): string
	return if playing then "⏸" else "▶"
end

local function togglePlay()
	if not playing then
		previewing = false
	end
	setPlaying(not playing)
end

local function skip(delta: number)
	if not available then
		return
	end
	previewing = false
	-- "previous" restarts the current track if it's a few seconds in
	if delta < 0 and elapsed() > 4 then
		startTrack(trackIndex)
	else
		startTrack(trackIndex + delta)
	end
	if not playing then
		setPlaying(true)
	end
end

---------------------------------------------------------------------------
-- Music app
---------------------------------------------------------------------------
local function buildApp(content: ScrollingFrame)
	local built = false
	local nowName: TextLabel
	local nowInfo: TextLabel
	local timeLabel: TextLabel
	local setProgress: (number) -> ()
	local playButton: TextButton
	local rows: { [number]: TextButton } = {}

	local function refreshRows()
		for i, row in rows do
			local current = i == trackIndex
			row.BackgroundColor3 = if current then Color3.fromRGB(70, 30, 55) else colors.panelLight
			local eq = row:FindFirstChild("Eq") :: TextLabel?
			if eq then
				eq.Text = if current and playing then "♪" else ""
			end
		end
	end

	local function refreshNow()
		if not built then
			return
		end
		local t = track()
		nowName.Text = t.name
		nowInfo.Text = string.format("%s · %d BPM · %s", t.style, t.bpm, if previewing then "preview" elseif playing then "playing" else "paused")
		playButton.Text = playPauseText()
		refreshRows()
	end

	local function build()
		Phone.clear(content)
		if available == nil then
			UI.label({ Text = "Tuning up… checking which sounds this device has.", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 50), Parent = content })
			return
		end
		if available == false then
			local c = Phone.card(content, 120, 1)
			UI.label({ Text = "🔇 Music isn't available on this device", Font = UI.FONT_BLACK, TextSize = 15, TextWrapped = true, Size = UDim2.new(1, 0, 0, 40), Parent = c })
			UI.label({
				Text = "CityGrind's music is generated live from sounds built into the Roblox app, and none of them loaded here. Everything else in the game works as normal.",
				TextSize = 12,
				TextColor3 = colors.subtext,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(0, 44),
				Size = UDim2.new(1, 0, 0, 52),
				Parent = c,
			})
			return
		end

		-- now playing
		local c = Phone.card(content, 186, 1)
		c.BackgroundColor3 = Color3.fromRGB(45, 20, 40)
		UI.label({ Text = "NOW PLAYING", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = Color3.fromRGB(255, 150, 200), Size = UDim2.new(1, 0, 0, 14), Parent = c })
		nowName = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 18, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
		nowInfo = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, 0, 0, 14), Parent = c })
		local _, setter = UI.bar({ Position = UDim2.fromOffset(0, 62), Size = UDim2.new(1, 0, 0, 6), Parent = c }, APP_COLOR)
		setProgress = setter
		timeLabel = UI.label({ Text = "", TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 70), Size = UDim2.new(1, 0, 0, 14), Parent = c })
		local controls = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 88), Size = UDim2.new(1, 0, 0, 40), Parent = c })
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder, Parent = controls })
		local prev = UI.button({ Text = "⏮", TextSize = 18, Size = UDim2.fromOffset(52, 40), LayoutOrder = 1, Parent = controls })
		playButton = UI.button({ Text = "▶", TextSize = 20, BackgroundColor3 = APP_COLOR, Size = UDim2.fromOffset(64, 40), LayoutOrder = 2, Parent = controls })
		local nextB = UI.button({ Text = "⏭", TextSize = 18, Size = UDim2.fromOffset(52, 40), LayoutOrder = 3, Parent = controls })
		prev.Activated:Connect(function()
			skip(-1)
		end)
		playButton.Activated:Connect(togglePlay)
		nextB.Activated:Connect(function()
			skip(1)
		end)
		volumeSlider(c, 136)
		UI.label({ Text = "Music volume (separate from notification sounds)", TextSize = 10, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 162), Size = UDim2.new(1, 0, 0, 12), Parent = c })

		-- track list
		UI.label({ Text = "ORIGINAL TRACKS", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = 2, Parent = content })
		for i, t in MC.TRACKS do
			local row = UI.button({ Text = "", Size = UDim2.new(1, -20, 0, 50), LayoutOrder = 2 + i, Parent = content })
			UI.label({ Text = t.name, Font = UI.FONT_BOLD, TextSize = 14, Position = UDim2.fromOffset(12, 7), Size = UDim2.new(1, -60, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
			UI.label({ Text = string.format("%s · %d BPM · %s", t.style, t.bpm, fmt(durationOf(t))), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(12, 27), Size = UDim2.new(1, -60, 0, 14), Parent = row })
			UI.label({ Name = "Eq", Text = "", Font = UI.FONT_BLACK, TextSize = 18, TextColor3 = APP_COLOR, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.new(0, 30, 1, 0), Parent = row })
			row.Activated:Connect(function()
				previewing = false
				startTrack(i)
				playing = false
				setPlaying(true)
			end)
			rows[i] = row
		end
		local info = Phone.card(content, 64, 20)
		UI.label({
			Text = instrumentsText() .. "\nEvery track is an original pattern played live on your device. Keeps playing while you walk, drive or chill at home.",
			TextSize = 10,
			TextColor3 = colors.subtext,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Size = UDim2.fromScale(1, 1),
			Parent = info,
		})
		built = true
		refreshNow()
	end

	table.insert(listeners, function()
		if not built or available == false then
			built = false
			build()
		else
			refreshNow()
		end
	end)

	RunService.Heartbeat:Connect(function()
		if built and Phone.isOpen() and Phone.currentPage() == APP_ID then
			local t = track()
			local total = durationOf(t)
			local e = math.min(elapsed(), total)
			setProgress(e / total)
			timeLabel.Text = fmt(e) .. " / " .. fmt(total)
		end
	end)

	build()
	return function()
		if not built then
			build()
		else
			refreshNow()
		end
	end
end

---------------------------------------------------------------------------
-- Now-playing bar on the phone's home screen
---------------------------------------------------------------------------
local function attachHomeBar()
	local phoneGui = player:WaitForChild("PlayerGui"):WaitForChild("CityGrindPhone", 30)
	local frame = phoneGui and phoneGui:WaitForChild("Phone", 10)
	local screen = frame and frame:WaitForChild("Screen", 10)
	local home = screen and screen:WaitForChild("Home", 10)
	if not home then
		return
	end
	local grid = home:FindFirstChild("Apps") :: GuiObject?
	local gridSize = if grid then grid.Size else nil

	local bar = UI.new("Frame", {
		Name = "NowPlaying",
		BackgroundColor3 = Color3.fromRGB(30, 14, 28),
		BackgroundTransparency = 0.1,
		Position = UDim2.new(0, 14, 1, -76),
		Size = UDim2.new(1, -28, 0, 40),
		Visible = false,
		ZIndex = 5,
		Parent = home,
	}, { UI.corner(12), UI.stroke(APP_COLOR, 1, 0.4) })
	local open = UI.new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, -84, 1, 0), ZIndex = 6, Parent = bar })
	local name = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -94, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6, Parent = bar })
	local sub = UI.label({ Text = "", TextSize = 10, TextColor3 = colors.subtext, Position = UDim2.fromOffset(10, 21), Size = UDim2.new(1, -94, 0, 13), ZIndex = 6, Parent = bar })
	local pp = UI.button({ Text = "▶", TextSize = 15, BackgroundColor3 = APP_COLOR, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -42, 0.5, 0), Size = UDim2.fromOffset(34, 30), ZIndex = 6, Parent = bar })
	local nx = UI.button({ Text = "⏭", TextSize = 14, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(34, 30), ZIndex = 6, Parent = bar })
	open.Activated:Connect(function()
		Phone.showPage(APP_ID)
	end)
	pp.Activated:Connect(togglePlay)
	nx.Activated:Connect(function()
		skip(1)
	end)

	local everStarted = false
	local function refresh()
		if playing then
			everStarted = true
		end
		local show = available == true and everStarted
		bar.Visible = show
		if grid and gridSize then
			grid.Size = if show then UDim2.new(gridSize.X.Scale, gridSize.X.Offset, gridSize.Y.Scale, gridSize.Y.Offset - 46) else gridSize
		end
		local t = track()
		name.Text = "♪ " .. t.name
		sub.Text = (if playing then "Playing" else "Paused") .. " · " .. t.style
		pp.Text = playPauseText()
	end
	table.insert(listeners, refresh)
	refresh()
end

function Music.start()
	Phone.addApp({ id = APP_ID, label = "Music", icon = "🎵", color = APP_COLOR }, buildApp)
	task.spawn(setupInstruments)
	task.spawn(attachHomeBar)
end

return Music
