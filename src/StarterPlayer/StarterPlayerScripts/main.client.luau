local ReplicatedStorage = game:GetService("ReplicatedStorage")
local start = require(ReplicatedStorage.std.start)

local systems = ReplicatedStorage:WaitForChild("ClientSystems")
start(systems:GetChildren())
