local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Assets = ReplicatedStorage:WaitForChild("Assets")
local Bottles = Assets:WaitForChild("Bottles")

local BottleUtils = {}

BottleUtils.NORMAL_MODE_BOTTLES = 6
BottleUtils.HARD_MODE_BOTTLES = 8

BottleUtils.NORMAL_BOTTLE_COLORS = {"Blue", "Green", "Orange", "Purple", "Red", "Yellow"}
BottleUtils.HARD_BOTTLE_COLORS   = {"Blue", "Green", "Orange", "Purple", "Red", "Yellow", "White", "Pink"}

BottleUtils.VALID_LOOKUP = {}
for _, color in ipairs(BottleUtils.HARD_BOTTLE_COLORS) do
	BottleUtils.VALID_LOOKUP[color:lower()] = color
end

--------------------------------------------------------------------------------
-- // DERANGEMENT GENERATION (0 MATCHES GUARANTEED)
--------------------------------------------------------------------------------

function BottleUtils:GenerateDerangement(targetOrder)
	local n = #targetOrder
	if n <= 1 then return table.clone(targetOrder) end

	local current = table.clone(targetOrder)
	local attempts = 0
	local maxAttempts = 100

	repeat
		attempts += 1
		-- Fisher-Yates Shuffle
		for i = n, 2, -1 do
			local j = math.random(1, i)
			current[i], current[j] = current[j], current[i]
		end

		-- Count exact matches
		local matches = 0
		for i = 1, n do
			if current[i] == targetOrder[i] then
				matches += 1
			end
		end
	until matches == 0 or attempts >= maxAttempts

	-- Hard Fallback: Forcefully fix any remaining 1-match if max attempts was hit
	for i = 1, n do
		if current[i] == targetOrder[i] then
			-- Swap this matching item with any adjacent non-matching slot
			local swapIndex = (i % n) + 1
			current[i], current[swapIndex] = current[swapIndex], current[i]
		end
	end

	return current
end

--------------------------------------------------------------------------------
-- // MASTER COLOR LAYOUT CREATION
--------------------------------------------------------------------------------

function BottleUtils:GenerateMasterColorLayout(skinName, bottleCount, avoidOrder)
	local isNormalMode = (bottleCount == self.NORMAL_MODE_BOTTLES)
	local allowedColors = isNormalMode and self.NORMAL_BOTTLE_COLORS or self.HARD_BOTTLE_COLORS

	local skinFolder = Bottles:FindFirstChild(skinName or "Default")
	local availableInSkin = {}

	if skinFolder then
		for _, child in ipairs(skinFolder:GetChildren()) do
			if child:IsA("Model") or child:IsA("BasePart") then
				for _, allowed in ipairs(allowedColors) do
					if child.Name:lower() == allowed:lower() then
						table.insert(availableInSkin, allowed)
						break
					end
				end
			end
		end
	end

	if #availableInSkin == 0 then
		availableInSkin = table.clone(allowedColors)
	end

	local shuffled = table.clone(availableInSkin)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	local colors = {}
	for i = 1, bottleCount do
		table.insert(colors, shuffled[(i - 1) % #shuffled + 1])
	end

	-- Shuffle layout for initial randomness
	for i = #colors, 2, -1 do
		local j = math.random(1, i)
		colors[i], colors[j] = colors[j], colors[i]
	end

	-- If an order to avoid is provided (e.g., target layout), force 0 matches
	if avoidOrder and type(avoidOrder) == "table" and #avoidOrder == bottleCount then
		colors = self:GenerateDerangement(avoidOrder)
	end

	return colors
end

function BottleUtils:GenerateRandomServerOrder(bottleCount)
	local isNormalMode = (bottleCount == self.NORMAL_MODE_BOTTLES)
	local colorPool = isNormalMode and self.NORMAL_BOTTLE_COLORS or self.HARD_BOTTLE_COLORS
	local order = {}

	local shuffled = table.clone(colorPool)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	for i = 1, bottleCount do
		table.insert(order, shuffled[(i - 1) % #shuffled + 1])
	end

	return order
end

--------------------------------------------------------------------------------
-- // VALIDATION HELPERS
--------------------------------------------------------------------------------

function BottleUtils:ValidateBottleOrder(orderNamesArray, expectedCount, startingColorsList)
	if type(orderNamesArray) ~= "table" then return false end
	if #orderNamesArray ~= expectedCount then return false end

	local isNormalMode = (expectedCount == self.NORMAL_MODE_BOTTLES)
	local allowedColors = isNormalMode and self.NORMAL_BOTTLE_COLORS or self.HARD_BOTTLE_COLORS

	local allowedLookup = {}
	for _, col in ipairs(allowedColors) do
		allowedLookup[col:lower()] = true
	end

	local seen = {}
	for _, colorName in ipairs(orderNamesArray) do
		if type(colorName) ~= "string" then return false end
		local lowerColor = colorName:lower()

		if not allowedLookup[lowerColor] then return false end

		if isNormalMode then
			if seen[lowerColor] then return false end
			seen[lowerColor] = true
		end
	end

	if startingColorsList and not self:IsSameMultiset(startingColorsList, orderNamesArray) then
		return false
	end

	return true
end

function BottleUtils:IsSameMultiset(oldOrder, newOrder)
	if #oldOrder ~= #newOrder then return false end
	local counts = {}
	for _, v in ipairs(oldOrder) do counts[v] = (counts[v] or 0) + 1 end
	for _, v in ipairs(newOrder) do
		if not counts[v] or counts[v] == 0 then return false end
		counts[v] -= 1
	end
	return true
end

function BottleUtils:IsValidSingleSwap(oldOrder, newOrder)
	if #oldOrder ~= #newOrder then return false end

	local diffIndices = {}
	for i = 1, #oldOrder do
		if oldOrder[i] ~= newOrder[i] then
			table.insert(diffIndices, i)
		end
	end

	if #diffIndices == 0 then return true end
	if #diffIndices ~= 2 then return false end

	local i, j = diffIndices[1], diffIndices[2]
	return oldOrder[i] == newOrder[j] and oldOrder[j] == newOrder[i]
end

return BottleUtils
