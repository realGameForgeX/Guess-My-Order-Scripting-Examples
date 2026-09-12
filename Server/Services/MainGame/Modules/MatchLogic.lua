-- // Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

-- // Updated Require Paths to MatchTypes Folder
local Services = ServerScriptService:WaitForChild("Services")
local MainGame = Services:WaitForChild("MainGame")
local MatchTypes = MainGame:WaitForChild("MatchTypes")

local AiMatch = require(MatchTypes:WaitForChild("AiMatch"))
local PvpMatch = require(MatchTypes:WaitForChild("PvpMatch"))

local MatchLogic = {}

--------------------------------------------------------------------------------
-- // MATCH ROUTERS
--------------------------------------------------------------------------------

function MatchLogic:StartMatch(p1, p2, model, bottleCount, isAi)
	local matchId = HttpService:GenerateGUID(false)

	if isAi then
		AiMatch:Start(p1, model, bottleCount, matchId)
	else
		PvpMatch:Start(p1, p2, model, bottleCount, matchId)
	end
end

function MatchLogic:SubmitCombinations(player, playingTable)
	local data = playingTable[player.UserId]
	if not data or data.MatchEnding then return end

	if data.Mode == "AI" then
		AiMatch:SubmitCombinations(player, playingTable)
	elseif data.Mode == "PVP" then
		PvpMatch:SubmitCombinations(player, playingTable)
	end
end

function MatchLogic:HandleMoveMade(player, orderNamesArray, playingTable)
	local data = playingTable[player.UserId]
	if not data or data.MatchEnding then return end

	if data.Mode == "AI" then
		AiMatch:HandleMoveMade(player, orderNamesArray, playingTable)
	elseif data.Mode == "PVP" then
		PvpMatch:HandleMoveMade(player, orderNamesArray, playingTable)
	end
end

function MatchLogic:GiveUp(player, playingTable)
	local data = playingTable[player.UserId]
	if not data or data.MatchEnding then return end

	if data.Mode == "AI" then
		AiMatch:GiveUp(player, playingTable)
	elseif data.Mode == "PVP" then
		PvpMatch:GiveUp(player, playingTable)
	end
end

return MatchLogic
