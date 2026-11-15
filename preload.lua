--[[
  VOICEROID mod - preload.lua

  フックの登録だけを置く。実装は main.lua。
  Only registers hooks. The implementation lives in main.lua.

  Author: sagittarius72
  Assisted-by: Claude:claude-fable-5-2
]]

local mod = game.mod_runtime[game.current_mod]

-- NPCのターン開始時：あくび・空腹・喉の渇きのセリフ
-- At the start of each NPC turn: yawn / hungry / thirsty lines.
game.add_hook("on_npc_do_turn", function(...)
  if mod.on_npc_do_turn then return mod.on_npc_do_turn(...) end
end)

-- NPCが動こうとした時：「どいて」のセリフ
-- When an NPC tries to move: the "let me pass" line.
game.add_hook("on_npc_try_move", function(...)
  if mod.on_npc_try_move then return mod.on_npc_try_move(...) end
end)

-- ゲームの開始時とロード時：<u_name>（プレイヤーの名前）の準備
-- When a game starts or loads: prepare <u_name> (the player's name).
for _, hook in ipairs({ "on_game_started", "on_game_load" }) do
  game.add_hook(hook, function(...)
    if mod.on_game_ready then mod.on_game_ready(...) end
  end)
end
