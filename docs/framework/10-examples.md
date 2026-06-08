# Complete Examples

This document provides full implementation examples using the IGD Framework.

## Example 1: Shop System

A complete shop system with server validation and client UI.

### Server Component: Shop

```lua
--[=[
    @component Shop
    @dependencies: Currency, Inventory
    @description: Handles item purchases with server-side validation
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

local Composer = require(Framework.Main.Component);
local Replication = require(Framework.Utils.Replication);

-- Shop item definitions (could be in separate module)
local SHOP_ITEMS = {
    sword_basic = { name = 'Basic Sword', price = 100, currency = 'Coins' };
    sword_fire = { name = 'Fire Sword', price = 500, currency = 'Coins' };
    potion_health = { name = 'Health Potion', price = 50, currency = 'Coins' };
    skin_gold = { name = 'Gold Skin', price = 100, currency = 'Gems' };
};

local ShopComponent = Composer.Extend({
    identifier = 'Shop';
    dependencies = { 'Currency', 'Inventory' };

    replication = {
        enabled = true;
        authorized = { 'RequestPurchase', 'GetShopItems' };
    };

    state = {};
    replica_dependencies = {};
});

function ShopComponent:RunOnCompilationCompleted()
    self:AddSignal('ItemPurchased');
end

-- Authorized: Client requests item purchase
function ShopComponent:RequestPurchase(itemId: string)
    -- Validate input
    if type(itemId) ~= 'string' then
        return { success = false, message = 'Invalid item ID' };
    end

    local item = SHOP_ITEMS[itemId];
    if not item then
        return { success = false, message = 'Item not found' };
    end

    -- Get dependencies
    local currency = self.dependencies.Currency;
    local inventory = self.dependencies.Inventory;

    -- Check balance
    local balance = self.data.Currencies[item.currency] or 0;
    if balance < item.price then
        return { success = false, message = 'Insufficient funds' };
    end

    -- Process purchase
    currency:EditCurrency(item.currency, 'Deduct', item.price);

    local added = inventory:AddItem(itemId);
    if not added then
        -- Refund if inventory full
        currency:EditCurrency(item.currency, 'Add', item.price);
        return { success = false, message = 'Inventory full' };
    end

    -- Fire signal
    self.signals.ItemPurchased:Fire(itemId, item);

    -- Notify client
    Replication.FireToClient('Session', self.player, {
        Identifier = 'Shop';
        Call = 'OnPurchaseComplete';
        Args = { itemId, item.name };
    });

    return { success = true, message = 'Purchase successful' };
end

-- Authorized: Get available shop items
function ShopComponent:GetShopItems()
    local items = {};
    for id, item in pairs(SHOP_ITEMS) do
        items[id] = {
            name = item.name;
            price = item.price;
            currency = item.currency;
        };
    end
    return items;
end

return ShopComponent;
```

### Client Controller: Shop

```lua
--[=[
    @controller Shop
    @dependencies: Currency
    @description: Shop UI management
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

local Composer = require(Framework.Main.Controller);
local Replication = require(Framework.Utils.Replication);
local FormatUtils = require(Framework.Utils.FormatUtils);
local Signal = require(Framework.Dependencies.signal);

local ShopController = Composer.Extend({
    identifier = 'Shop';
    dependencies = { 'Currency' };

    state = {
        items = {};
        selectedItem = nil;
    };

    replica_dependencies = {};
});

function ShopController:RunOnCompilationCompleted()
    self:AddSignal('ItemSelected');
    self.purchaseCompleted = Signal.new();
end

function ShopController:RunOnRegistrationCompleted()
    -- Fetch shop items from server
    self:_LoadShopItems();

    -- Set up UI
    self:_SetupUI();

    -- Listen for currency changes to update affordability
    local currency = self.dependencies.Currency;
    currency.currency_updated:Connect(function()
        self:_UpdateAffordability();
    end)
end

-- Called by server after successful purchase
function ShopController:OnPurchaseComplete(itemId: string, itemName: string)
    self.purchaseCompleted:Fire(itemId, itemName);
    self:_ShowNotification('Purchased ' .. itemName .. '!', 'success');
end

-- Public: Attempt to purchase selected item
function ShopController:PurchaseSelected()
    if not self.state.selectedItem then return end

    local result = Replication.InvokeServer('Session', {
        Identifier = 'Shop';
        Call = 'RequestPurchase';
        Args = { self.state.selectedItem };
    });

    if result and not result.success then
        self:_ShowNotification(result.message, 'error');
    end
end

-- Private: Load shop items from server
function ShopController:_LoadShopItems()
    local items = Replication.InvokeServer('Session', {
        Identifier = 'Shop';
        Call = 'GetShopItems';
        Args = {};
    });

    if items then
        self.state.items = items;
        self:_PopulateShopUI();
    end
end

-- Private: Set up UI elements
function ShopController:_SetupUI()
    local player = game.Players.LocalPlayer;
    local gui = player:WaitForChild('PlayerGui');

    self.ui = {
        frame = gui:FindFirstChild('ShopFrame', true);
        itemContainer = gui:FindFirstChild('ShopItems', true);
        itemTemplate = gui:FindFirstChild('ShopItemTemplate', true);
        buyButton = gui:FindFirstChild('BuyButton', true);
        selectedName = gui:FindFirstChild('SelectedItemName', true);
        selectedPrice = gui:FindFirstChild('SelectedItemPrice', true);
    };

    if self.ui.buyButton then
        self.ui.buyButton.Activated:Connect(function()
            self:PurchaseSelected();
        end)
    end

    if self.ui.itemTemplate then
        self.ui.itemTemplate.Visible = false;
    end
end

-- Private: Create shop item buttons
function ShopController:_PopulateShopUI()
    if not self.ui.itemContainer or not self.ui.itemTemplate then return end

    -- Clear existing
    for _, child in self.ui.itemContainer:GetChildren() do
        if child.Name ~= self.ui.itemTemplate.Name then
            child:Destroy();
        end
    end

    -- Create item buttons
    for itemId, item in pairs(self.state.items) do
        local button = self.ui.itemTemplate:Clone();
        button.Name = itemId;
        button.Visible = true;

        local nameLabel = button:FindFirstChild('Name');
        local priceLabel = button:FindFirstChild('Price');

        if nameLabel then nameLabel.Text = item.name; end
        if priceLabel then
            priceLabel.Text = FormatUtils.format_to_short_value(item.price);
        end

        button.Activated:Connect(function()
            self:_SelectItem(itemId);
        end)

        button.Parent = self.ui.itemContainer;
    end

    self:_UpdateAffordability();
end

-- Private: Select an item
function ShopController:_SelectItem(itemId: string)
    self.state.selectedItem = itemId;
    local item = self.state.items[itemId];

    if self.ui.selectedName then
        self.ui.selectedName.Text = item and item.name or '';
    end

    if self.ui.selectedPrice then
        self.ui.selectedPrice.Text = item
            and FormatUtils.format_to_long_value(item.price) .. ' ' .. item.currency
            or '';
    end

    self.signals.ItemSelected:Fire(itemId, item);
end

-- Private: Update which items player can afford
function ShopController:_UpdateAffordability()
    local currency = self.dependencies.Currency;

    for itemId, item in pairs(self.state.items) do
        local button = self.ui.itemContainer:FindFirstChild(itemId);
        if button then
            local balance = currency:GetBalance(item.currency);
            local canAfford = balance >= item.price;

            button.BackgroundColor3 = canAfford
                and Color3.fromRGB(50, 150, 50)
                or Color3.fromRGB(150, 50, 50);
        end
    end
end

-- Private: Show notification
function ShopController:_ShowNotification(message: string, notifType: string)
    Replication.FireToServer('Global', {
        Identifier = 'Notifications';
        Call = 'DisplayNotification';
        Args = { message, notifType };
    });
end

return ShopController;
```

---

## Example 2: Quest System

A multi-objective quest system.

### Server Component: Quests

```lua
--[=[
    @component Quests
    @dependencies: Currency
    @description: Manages player quests and objectives
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

local Composer = require(Framework.Main.Component);
local Replication = require(Framework.Utils.Replication);

-- Quest definitions
local QUESTS = {
    gather_fish = {
        name = 'Gone Fishing';
        description = 'Catch 10 fish';
        objectives = {
            { type = 'catch_fish', required = 10 };
        };
        rewards = {
            { type = 'currency', currency = 'Coins', amount = 500 };
        };
    };
    catch_rare = {
        name = 'Rare Catch';
        description = 'Catch a rare fish';
        objectives = {
            { type = 'catch_rare_fish', required = 1 };
        };
        rewards = {
            { type = 'currency', currency = 'Gems', amount = 10 };
        };
    };
};

local QuestsComponent = Composer.Extend({
    identifier = 'Quests';
    dependencies = { 'Currency' };

    replication = {
        enabled = true;
        authorized = { 'AcceptQuest', 'GetAvailableQuests', 'GetActiveQuests' };
    };

    state = {};
    replica_dependencies = { 'Quests' };
});

function QuestsComponent:RunOnCompilationCompleted()
    self:AddSignal('QuestAccepted');
    self:AddSignal('QuestCompleted');
    self:AddSignal('ObjectiveProgress');

    -- Initialize quest data
    if not self.data.Quests then
        self.data.Quests = { Active = {}, Completed = {} };
    end
end

function QuestsComponent:RunOnRegistrationCompleted()
    self:_SyncQuestsToClient();
end

-- Authorized: Accept a quest
function QuestsComponent:AcceptQuest(questId: string)
    if type(questId) ~= 'string' then return false end

    local quest = QUESTS[questId];
    if not quest then return false end

    -- Check not already active or completed
    if self.data.Quests.Active[questId] then return false end
    if self.data.Quests.Completed[questId] then return false end

    -- Initialize quest progress
    self.data.Quests.Active[questId] = {
        progress = {};
        startedAt = os.time();
    };

    for i, objective in ipairs(quest.objectives) do
        self.data.Quests.Active[questId].progress[i] = 0;
    end

    self.signals.QuestAccepted:Fire(questId, quest);
    self:_SyncQuestsToClient();

    return true;
end

-- Public: Progress an objective (called by other components)
function QuestsComponent:ProgressObjective(objectiveType: string, amount: number?)
    amount = amount or 1;

    for questId, questProgress in pairs(self.data.Quests.Active) do
        local quest = QUESTS[questId];
        if not quest then continue end

        for i, objective in ipairs(quest.objectives) do
            if objective.type == objectiveType then
                questProgress.progress[i] = math.min(
                    questProgress.progress[i] + amount,
                    objective.required
                );

                self.signals.ObjectiveProgress:Fire(questId, i, questProgress.progress[i]);
                self:_CheckQuestCompletion(questId);
            end
        end
    end

    self:_SyncQuestsToClient();
end

-- Authorized: Get available quests
function QuestsComponent:GetAvailableQuests()
    local available = {};
    for questId, quest in pairs(QUESTS) do
        if not self.data.Quests.Active[questId]
           and not self.data.Quests.Completed[questId] then
            available[questId] = {
                name = quest.name;
                description = quest.description;
            };
        end
    end
    return available;
end

-- Authorized: Get active quests with progress
function QuestsComponent:GetActiveQuests()
    local active = {};
    for questId, progress in pairs(self.data.Quests.Active) do
        local quest = QUESTS[questId];
        if quest then
            active[questId] = {
                name = quest.name;
                description = quest.description;
                objectives = {};
            };

            for i, objective in ipairs(quest.objectives) do
                active[questId].objectives[i] = {
                    type = objective.type;
                    current = progress.progress[i];
                    required = objective.required;
                };
            end
        end
    end
    return active;
end

-- Private: Check if quest is complete
function QuestsComponent:_CheckQuestCompletion(questId: string)
    local quest = QUESTS[questId];
    local progress = self.data.Quests.Active[questId];
    if not quest or not progress then return end

    -- Check all objectives
    for i, objective in ipairs(quest.objectives) do
        if progress.progress[i] < objective.required then
            return; -- Not complete
        end
    end

    -- Quest complete - give rewards
    self:_GiveRewards(quest.rewards);

    -- Move to completed
    self.data.Quests.Completed[questId] = {
        completedAt = os.time();
    };
    self.data.Quests.Active[questId] = nil;

    self.signals.QuestCompleted:Fire(questId, quest);

    -- Notify client
    Replication.FireToClient('Session', self.player, {
        Identifier = 'Quests';
        Call = 'OnQuestCompleted';
        Args = { questId, quest.name };
    });
end

-- Private: Give quest rewards
function QuestsComponent:_GiveRewards(rewards)
    local currency = self.dependencies.Currency;

    for _, reward in ipairs(rewards) do
        if reward.type == 'currency' then
            currency:EditCurrency(reward.currency, 'Add', reward.amount);
        end
    end
end

-- Private: Sync to client
function QuestsComponent:_SyncQuestsToClient()
    self.replica.Quests = self.data.Quests;

    Replication.FireToClient('Session', self.player, {
        Identifier = 'Quests';
        Call = 'SyncQuests';
        Args = { self.data.Quests };
    });
end

return QuestsComponent;
```

---

## Example 3: Fishing Game System

A global fishing system that interacts with player components.

### Server System: Fishing

```lua
--[=[
    @system Fishing
    @description: Manages fishing mechanics and fish spawning
]=]

local Fishing = {};

Fishing.config = {
    identifier = 'Fishing';
    replication = {
        enabled = true;
        authorized = { 'CastLine', 'ReelIn' };
    };
};

-- Services
local ReplicatedStorage = game:GetService('ReplicatedStorage');
local Players = game:GetService('Players');

-- Imports
local Registry = require(ReplicatedStorage.Shared.Framework.Registry);
local Replication = require(ReplicatedStorage.Shared.Framework.Utils.Replication);
local Signal = require(ReplicatedStorage.Shared.Framework.Dependencies.signal);

-- Fish definitions
local FISH_TABLE = {
    { id = 'sardine',    name = 'Sardine',    weight = 100, value = 10,  rarity = 'Common' };
    { id = 'bass',       name = 'Bass',       weight = 50,  value = 25,  rarity = 'Common' };
    { id = 'salmon',     name = 'Salmon',     weight = 20,  value = 50,  rarity = 'Uncommon' };
    { id = 'tuna',       name = 'Tuna',       weight = 10,  value = 100, rarity = 'Rare' };
    { id = 'swordfish',  name = 'Swordfish',  weight = 1,   value = 500, rarity = 'Legendary' };
};

-- State
Fishing.ActiveCasts = {}; -- [player.UserId] = castData
Fishing.signals = {
    FishCaught = Signal.new();
};

-- Initialize
function Fishing.Initialize()
    -- Clean up on player leave
    Players.PlayerRemoving:Connect(function(player)
        Fishing.ActiveCasts[player.UserId] = nil;
    end)
end

-- Authorized: Player casts fishing line
function Fishing.CastLine(session, position: Vector3)
    local player = session.player;

    -- Validate
    if Fishing.ActiveCasts[player.UserId] then
        return { success = false, message = 'Already fishing' };
    end

    -- Store cast
    Fishing.ActiveCasts[player.UserId] = {
        position = position;
        castTime = os.time();
        fish = Fishing._RollFish();
        catchTime = os.time() + math.random(3, 8);
    };

    -- Notify client of cast
    Replication.FireToClient('Session', player, {
        Identifier = 'Fishing';
        Call = 'OnLineCast';
        Args = { position };
    });

    return { success = true };
end

-- Authorized: Player reels in
function Fishing.ReelIn(session)
    local player = session.player;
    local cast = Fishing.ActiveCasts[player.UserId];

    if not cast then
        return { success = false, message = 'Not fishing' };
    end

    -- Check timing
    local now = os.time();
    local timeDiff = math.abs(now - cast.catchTime);

    Fishing.ActiveCasts[player.UserId] = nil;

    -- Too early or too late
    if timeDiff > 2 then
        Replication.FireToClient('Session', player, {
            Identifier = 'Fishing';
            Call = 'OnFishMissed';
            Args = {};
        });
        return { success = false, message = 'Missed the fish!' };
    end

    -- Caught fish!
    local fish = cast.fish;

    -- Add to player inventory
    local inventory = session.components.Inventory;
    if inventory then
        inventory:AddItem(fish.id, 1);
    end

    -- Add currency
    local currency = session.components.Currency;
    if currency then
        currency:EditCurrency('Coins', 'Add', fish.value);
    end

    -- Progress quest
    local quests = session.components.Quests;
    if quests then
        quests:ProgressObjective('catch_fish', 1);
        if fish.rarity == 'Rare' or fish.rarity == 'Legendary' then
            quests:ProgressObjective('catch_rare_fish', 1);
        end
    end

    -- Add to quota
    local Quota = require(script.Parent.Quota);
    Quota.AddQuota(fish.value);

    -- Fire signal
    Fishing.signals.FishCaught:Fire(player, fish);

    -- Notify client
    Replication.FireToClient('Session', player, {
        Identifier = 'Fishing';
        Call = 'OnFishCaught';
        Args = { fish };
    });

    return { success = true, fish = fish };
end

-- Private: Roll for fish based on weights
function Fishing._RollFish()
    local totalWeight = 0;
    for _, fish in ipairs(FISH_TABLE) do
        totalWeight = totalWeight + fish.weight;
    end

    local roll = math.random() * totalWeight;
    local cumulative = 0;

    for _, fish in ipairs(FISH_TABLE) do
        cumulative = cumulative + fish.weight;
        if roll <= cumulative then
            return fish;
        end
    end

    return FISH_TABLE[1]; -- Fallback
end

return Fishing;
```

---

## Example 4: Achievement System

Integrating with other components via signals.

### Server Component: Achievements

```lua
--[=[
    @component Achievements
    @dependencies: Currency, Quests
    @description: Tracks player achievements based on actions
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

local Composer = require(Framework.Main.Component);
local Replication = require(Framework.Utils.Replication);

local ACHIEVEMENTS = {
    first_fish = {
        name = 'First Catch';
        description = 'Catch your first fish';
        reward = { currency = 'Gems', amount = 5 };
    };
    quest_master = {
        name = 'Quest Master';
        description = 'Complete 10 quests';
        reward = { currency = 'Gems', amount = 50 };
    };
    big_spender = {
        name = 'Big Spender';
        description = 'Spend 10,000 coins';
        reward = { currency = 'Gems', amount = 25 };
    };
};

local AchievementsComponent = Composer.Extend({
    identifier = 'Achievements';
    dependencies = { 'Currency', 'Quests' };

    replication = {
        enabled = true;
        authorized = { 'GetAchievements' };
    };

    state = {
        stats = {
            fishCaught = 0;
            questsCompleted = 0;
            coinsSpent = 0;
        };
    };

    replica_dependencies = {};
});

function AchievementsComponent:RunOnCompilationCompleted()
    self:AddSignal('AchievementUnlocked');

    -- Initialize data
    if not self.data.Achievements then
        self.data.Achievements = {};
    end

    if not self.data.Stats then
        self.data.Stats = {
            fishCaught = 0;
            questsCompleted = 0;
            coinsSpent = 0;
        };
    end

    self.state.stats = self.data.Stats;
end

function AchievementsComponent:RunOnRegistrationCompleted()
    -- Connect to quest completion
    local quests = self.dependencies.Quests;
    quests.signals.QuestCompleted:Connect(function(questId)
        self:_OnQuestCompleted();
    end)

    -- Connect to global fishing signal
    local Fishing = require(game.ServerScriptService.Server.Systems.Fishing);
    Fishing.signals.FishCaught:Connect(function(player, fish)
        if player == self.player then
            self:_OnFishCaught(fish);
        end
    end)
end

-- Public: Track spending (called by shop)
function AchievementsComponent:TrackSpending(amount: number)
    self.data.Stats.coinsSpent = self.data.Stats.coinsSpent + amount;
    self:_CheckAchievements();
end

-- Authorized: Get all achievements
function AchievementsComponent:GetAchievements()
    local result = {};
    for id, achievement in pairs(ACHIEVEMENTS) do
        result[id] = {
            name = achievement.name;
            description = achievement.description;
            unlocked = self.data.Achievements[id] ~= nil;
        };
    end
    return result;
end

-- Private: Handle fish caught
function AchievementsComponent:_OnFishCaught(fish)
    self.data.Stats.fishCaught = self.data.Stats.fishCaught + 1;
    self:_CheckAchievements();
end

-- Private: Handle quest completed
function AchievementsComponent:_OnQuestCompleted()
    self.data.Stats.questsCompleted = self.data.Stats.questsCompleted + 1;
    self:_CheckAchievements();
end

-- Private: Check and unlock achievements
function AchievementsComponent:_CheckAchievements()
    local stats = self.data.Stats;

    -- First fish
    if stats.fishCaught >= 1 then
        self:_TryUnlock('first_fish');
    end

    -- Quest master
    if stats.questsCompleted >= 10 then
        self:_TryUnlock('quest_master');
    end

    -- Big spender
    if stats.coinsSpent >= 10000 then
        self:_TryUnlock('big_spender');
    end
end

-- Private: Attempt to unlock achievement
function AchievementsComponent:_TryUnlock(achievementId: string)
    if self.data.Achievements[achievementId] then return end

    local achievement = ACHIEVEMENTS[achievementId];
    if not achievement then return end

    -- Mark as unlocked
    self.data.Achievements[achievementId] = {
        unlockedAt = os.time();
    };

    -- Give reward
    local currency = self.dependencies.Currency;
    currency:EditCurrency(
        achievement.reward.currency,
        'Add',
        achievement.reward.amount
    );

    -- Fire signal
    self.signals.AchievementUnlocked:Fire(achievementId, achievement);

    -- Notify client
    Replication.FireToClient('Session', self.player, {
        Identifier = 'Achievements';
        Call = 'OnAchievementUnlocked';
        Args = { achievementId, achievement.name };
    });
end

return AchievementsComponent;
```

---

## Usage Patterns Summary

### Signal-Based Communication

```lua
-- Producer fires signal
self.signals.SomethingHappened:Fire(data);

-- Consumer listens
dependency.signals.SomethingHappened:Connect(function(data)
    self:HandleEvent(data);
end)
```

### Server-to-Client Updates

```lua
-- Update data
self.data.Value = newValue;

-- Replicate to client
Replication.FireToClient('Session', self.player, {
    Identifier = self.config.identifier;
    Call = 'UpdateValue';
    Args = { newValue };
});
```

### Client Request/Response

```lua
-- Client requests
local result = Replication.InvokeServer('Session', {
    Identifier = 'Component';
    Call = 'DoAction';
    Args = { params };
});

-- Server returns
function Component:DoAction(params)
    -- Validate and process
    return { success = true, data = result };
end
```

### Cross-Component Interaction

```lua
-- Use dependencies
local currency = self.dependencies.Currency;
currency:EditCurrency('Coins', 'Add', 100);

-- Or use signals for loose coupling
self.dependencies.Quests.signals.QuestCompleted:Connect(function()
    self:OnQuestDone();
end)
```
