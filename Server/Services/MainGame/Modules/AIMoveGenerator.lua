local AIMoveGenerator = {}

-- // ---------- Small helpers ----------

local function CopyArray(arr)
	local copy = table.create(#arr)
	for i = 1, #arr do
		copy[i] = arr[i]
	end
	return copy
end

local function OrdersMatch(a, b, count)
	for i = 1, count do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

-- // ---------- Core solving logic ----------

-- Computes the minimal sequence of swaps that turns `startOrder` into
-- `targetOrder`. Uses the standard "fix positions left to right" approach:
-- once position i is made correct, only positions j > i are ever touched
-- again, so the FULL order can only become correct after the LAST swap
-- in the returned list - never sooner. This also happens to produce the
-- true minimum possible number of swaps.
local function ComputeMinimalFixSwaps(startOrder, targetOrder, count)
	local working = CopyArray(startOrder)
	local fixSwaps = {}

	for i = 1, count do
		if working[i] ~= targetOrder[i] then
			for j = i + 1, count do
				if working[j] == targetOrder[i] then
					working[i], working[j] = working[j], working[i]
					table.insert(fixSwaps, { i, j })
					break
				end
			end
		end
	end

	return fixSwaps
end

-- Produces one "filler pair" of moves: a swap immediately followed by its
-- own reversal. Net effect on the bottle order is nothing, which makes it
-- always safe to use as padding - it can never accidentally solve (or
-- un-solve) anything. We still guard against the single mid-pair swapped
-- state accidentally equaling the target, just to be airtight.
local function GenerateFillerPair(referenceOrder, targetOrder, count)
	if count < 2 then
		return nil
	end

	for _attempt = 1, 20 do
		local i = math.random(1, count)
		local j = math.random(1, count)

		if i ~= j and referenceOrder[i] ~= referenceOrder[j] then
			local probe = CopyArray(referenceOrder)
			probe[i], probe[j] = probe[j], probe[i]

			if not OrdersMatch(probe, targetOrder, count) then
				return { { i, j }, { i, j } }
			end
		end
	end

	-- Fallback in case random attempts kept missing (tiny bottle counts,
	-- unlucky rolls, etc.) - just scan for the first valid pair.
	for i = 1, count - 1 do
		for j = i + 1, count do
			if referenceOrder[i] ~= referenceOrder[j] then
				local probe = CopyArray(referenceOrder)
				probe[i], probe[j] = probe[j], probe[i]
				if not OrdersMatch(probe, targetOrder, count) then
					return { { i, j }, { i, j } }
				end
			end
		end
	end

	return nil
end

--[[
	AIMoveGenerator:GenerateOrderMoves(InitialIncorrectBottleOrder, CorrectBottleOrder, NumberOfMoves)

	Returns a table of swap-moves (each `{Index1, Index2}`) that, when
	applied in order to InitialIncorrectBottleOrder, results in
	CorrectBottleOrder EXACTLY on the last move and not before.
]]
function AIMoveGenerator:GenerateOrderMoves(InitialIncorrectBottleOrder, CorrectBottleOrder, NumberOfMoves)
	assert(type(InitialIncorrectBottleOrder) == "table", "InitialIncorrectBottleOrder must be a table")
	assert(type(CorrectBottleOrder) == "table", "CorrectBottleOrder must be a table")
	assert(#InitialIncorrectBottleOrder == #CorrectBottleOrder, "Order length mismatch between initial and correct order")

	local count = #CorrectBottleOrder
	NumberOfMoves = math.max(0, math.floor(NumberOfMoves or 0))

	local fixSwaps = ComputeMinimalFixSwaps(InitialIncorrectBottleOrder, CorrectBottleOrder, count)
	local minimumSwaps = #fixSwaps

	if minimumSwaps == 0 then
		-- Orders already match going in. Nothing needs "fixing", so the
		-- whole sequence (if any) will just be self-cancelling filler.
		warn("[AIMoveGenerator] InitialIncorrectBottleOrder already matches CorrectBottleOrder - nothing to solve.")
		if NumberOfMoves % 2 == 1 then
			NumberOfMoves += 1
			warn("[AIMoveGenerator] Bumping NumberOfMoves by 1 to keep the padding pairs even.")
		end
	else
		if NumberOfMoves < minimumSwaps then
			warn(string.format(
				"[AIMoveGenerator] NumberOfMoves (%d) is below the minimum required (%d) - raising it to %d.",
				NumberOfMoves, minimumSwaps, minimumSwaps
				))
			NumberOfMoves = minimumSwaps
		end

		if (NumberOfMoves - minimumSwaps) % 2 == 1 then
			local bumped = NumberOfMoves + 1
			warn(string.format(
				"[AIMoveGenerator] NumberOfMoves (%d) must differ from the minimum (%d) by an even amount - bumping to %d.",
				NumberOfMoves, minimumSwaps, bumped
				))
			NumberOfMoves = bumped
		end
	end

	local fillerPairsNeeded = (NumberOfMoves - minimumSwaps) // 2
	local finalMoves = {}

	-- Filler moves go first: since each pair nets out to zero change, the
	-- AI can visually "fiddle around" before it starts actually solving,
	-- without any risk of touching the correct order early.
	local fillerReference = CopyArray(InitialIncorrectBottleOrder)
	for _ = 1, fillerPairsNeeded do
		local pair = GenerateFillerPair(fillerReference, CorrectBottleOrder, count)
		if pair then
			table.insert(finalMoves, pair[1])
			table.insert(finalMoves, pair[2])
			-- fillerReference doesn't need updating - the pair cancels itself out
		end
	end

	-- Now the real, order-correcting swaps. The last entry here is what
	-- brings the order to an exact match.
	for _, swap in ipairs(fixSwaps) do
		table.insert(finalMoves, swap)
	end

	return finalMoves
end

return AIMoveGenerator
