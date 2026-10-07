-- CITY GRIND: tiny helpers for building UI in code.

local TweenService = game:GetService("TweenService")

local UI = {}

UI.FONT = Enum.Font.GothamMedium
UI.FONT_BOLD = Enum.Font.GothamBold
UI.FONT_BLACK = Enum.Font.GothamBlack

UI.colors = {
	panel = Color3.fromRGB(18, 18, 24),
	panelLight = Color3.fromRGB(34, 34, 44),
	text = Color3.fromRGB(240, 240, 245),
	subtext = Color3.fromRGB(160, 160, 175),
	cash = Color3.fromRGB(110, 230, 120),
	xp = Color3.fromRGB(90, 170, 255),
	stamina = Color3.fromRGB(255, 200, 60),
	danger = Color3.fromRGB(255, 90, 90),
	accent = Color3.fromRGB(255, 120, 60),
}

-- UI.new("Frame", { Size = ..., Parent = ... }, { children })
function UI.new(className: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		inst.BorderSizePixel = 0
	end
	local parent
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			(inst :: any)[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function UI.corner(radius: number): UICorner
	return UI.new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

function UI.padding(px: number): UIPadding
	return UI.new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	})
end

function UI.stroke(color: Color3, thickness: number, transparency: number?): UIStroke
	return UI.new("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function UI.label(props: { [string]: any }, children: { Instance }?): TextLabel
	local defaults = {
		BackgroundTransparency = 1,
		Font = UI.FONT,
		TextColor3 = UI.colors.text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in props do
		defaults[k] = v
	end
	return UI.new("TextLabel", defaults, children)
end

function UI.button(props: { [string]: any }, children: { Instance }?): TextButton
	local defaults = {
		BackgroundColor3 = UI.colors.panelLight,
		Font = UI.FONT_BOLD,
		TextColor3 = UI.colors.text,
		TextSize = 16,
		AutoButtonColor = true,
	}
	for k, v in props do
		defaults[k] = v
	end
	local b = UI.new("TextButton", defaults, children)
	UI.corner(10).Parent = b
	UI.pressFeedback(b)
	return b
end

-- A quick "squish" when a button is pressed (mouse, touch or gamepad A).
-- Hover / press colour already comes from AutoButtonColor. Buttons inside a
-- list or grid layout are left alone so the press never nudges their
-- neighbours; the UIScale is only created on the first press.
local PRESS_IN = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_OUT = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
function UI.pressFeedback(button: GuiButton)
	local scale: UIScale? = nil
	local function inLayout(): boolean
		local parent = button.Parent
		return parent ~= nil and parent:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
	end
	local function press(down: boolean)
		if down then
			if inLayout() then
				return
			end
			if not scale then
				if button:FindFirstChildOfClass("UIScale") then
					return -- the button scales itself; don't fight it
				end
				scale = UI.new("UIScale", { Name = "PressScale", Parent = button })
			end
		end
		local s = scale
		if s then
			TweenService:Create(s, if down then PRESS_IN else PRESS_OUT, { Scale = if down then 0.94 else 1 }):Play()
		end
	end
	button.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch or (input.KeyCode == Enum.KeyCode.ButtonA and button.Selectable) then
			press(true)
		end
	end)
	button.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch or input.KeyCode == Enum.KeyCode.ButtonA then
			press(false)
		end
	end)
	button.MouseLeave:Connect(function()
		if scale then
			press(false)
		end
	end)
end

-- A horizontal progress bar. Returns the outer frame and a setter.
function UI.bar(props: { [string]: any }, fillColor: Color3): (Frame, (number) -> ())
	local outer = UI.new("Frame", props)
	if not props.BackgroundColor3 then
		outer.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	end
	UI.corner(6).Parent = outer
	local fill = UI.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = fillColor,
		Size = UDim2.fromScale(0, 1),
		Parent = outer,
	}, { UI.corner(6) })
	return outer, function(fraction: number)
		fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	end
end

function UI.formatCash(n: number): string
	return (if n < 0 then "-$" else "$") .. UI.formatNumber(math.abs(n))
end

-- 1234567 -> "1,234,567"
function UI.formatNumber(n: number): string
	local s = tostring(math.floor(math.abs(n)))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return (if n < 0 then "-" else "") .. formatted
end

-- 950 -> "950", 12500 -> "12.5K", 3400000 -> "3.4M" (for tight chips)
function UI.formatCompact(n: number): string
	local a = math.abs(n)
	local sign = if n < 0 then "-" else ""
	if a < 10000 then
		return sign .. UI.formatNumber(a)
	elseif a < 1e6 then
		return sign .. (string.format("%.1f", a / 1e3):gsub("%.0$", "")) .. "K"
	elseif a < 1e9 then
		return sign .. (string.format("%.1f", a / 1e6):gsub("%.0$", "")) .. "M"
	end
	return sign .. (string.format("%.1f", a / 1e9):gsub("%.0$", "")) .. "B"
end

function UI.formatClock(clockTime: number): string
	local hours = math.floor(clockTime)
	local minutes = math.floor((clockTime - hours) * 60)
	local suffix = if hours >= 12 then "PM" else "AM"
	local h12 = hours % 12
	if h12 == 0 then
		h12 = 12
	end
	return string.format("%d:%02d %s", h12, minutes, suffix)
end

function UI.timeAgo(timestamp: number): string
	local diff = math.max(0, os.time() - timestamp)
	if diff < 60 then
		return "just now"
	elseif diff < 3600 then
		return math.floor(diff / 60) .. "m ago"
	elseif diff < 86400 then
		return math.floor(diff / 3600) .. "h ago"
	end
	return math.floor(diff / 86400) .. "d ago"
end

return UI
