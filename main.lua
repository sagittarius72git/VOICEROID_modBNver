--[[
  VOICEROID mod - main.lua

  ボイスロイドのNPCに、キャラクター専用のセリフ（talk tags）を喋らせる。
  対象のセリフ：あくび・空腹・喉の渇き・「どいて」。
  Makes VOICEROID NPCs speak their own lines (talk tags).
  Covered lines: yawn, hungry, thirsty and "let me pass".

  本体は <yawn> や <let_me_pass> のような決まったタグしか呼ばない。
  そこで同じ場面を Lua で捉えて、<yawn_teto> などに差し替える。
  The game only calls fixed tags such as <yawn> or <let_me_pass>,
  so this file catches the same moments and uses <yawn_teto> etc. instead.

  Author: sagittarius72
  Assisted-by: Claude:claude-fable-5-2
]]

local mod = game.mod_runtime[game.current_mod]

-- ============================================================
-- 設定 / Settings
-- ============================================================

-- 誰がどのセリフを使うか（特性ID → タグの末尾）。
-- キャラクターを増やす時は、ここに1行足す。
-- 変身後の特性（_active）があるキャラクターは、両方を書く。
-- Who uses which lines (trait IDs -> tag suffix).
-- To add a character, add one line here.
-- Characters with a transformed trait (_active) list both.
--   "_teto" → <yawn_teto> <hungry_teto> <thirsty_teto> <let_me_pass_teto>
local VOICES = {
  { suffix = "_maki", traits = { "VOIRO_BODY_MAKI" } },
  { suffix = "_yukari", traits = { "VOIRO_BODY_YUKARI", "VOIRO_BODY_YUKARI_active" } },
  { suffix = "_zunko", traits = { "VOIRO_BODY_ZUNKO", "VOIRO_BODY_ZUNKO_active" } },
  { suffix = "_teto", traits = { "VOIRO_BODY_TETO" } },
}

-- 文字列のIDを、ゲームのIDに一度だけ変換しておく。
-- Turn the ID strings into game IDs once.
for _, voice in ipairs(VOICES) do
  for i, id in ipairs(voice.traits) do
    voice.traits[i] = MutationBranchId.new(id)
  end
end

-- true : 本体の「どいて」を止めて、専用のセリフだけにする。
-- false: 本体のセリフはそのままで、専用のセリフを追加で喋る。
-- true : silence the game's own "let me pass" line and say only ours.
-- false: keep the game's line and say ours in addition.
local REPLACE_LET_ME_PASS = true

-- ============================================================
-- 本体と同じしきい値 / Thresholds copied from the game
-- (BN v0.13.0: src/character.h, src/npcmove.cpp npc::complain)
-- ============================================================

local FATIGUE_TIRED = 191 -- これを超えるとあくび / yawns above this
local FATIGUE_FORCED = 900 -- これを超えると「静かに」の指示でも言う / ignores "don't complain" above this
local KCAL_HUNGRY = 0.9 -- 蓄えがこの割合を下回ると空腹 / hungry below this share of stored kcal
local THIRST_VERY_THIRSTY = 240 -- これを超えると喉の渇き / thirsty above this

local effect = EffectTypeId.new

-- 眠っている間は喋らない / no lines while asleep
local SLEEP_EFFECTS = { effect("sleep"), effect("lying_down"), effect("npc_suspend") }

-- 動けない・ふらついている・燃えている時は本体に任せる（抜け出す判定や消火を邪魔しないため）
-- While stuck, stunned or on fire, leave the move to the game (so escape rolls and
-- putting out the fire still happen).
local HINDER_EFFECTS = {
  effect("stunned"),
  effect("onfire"),
  effect("downed"),
  effect("webbed"),
  effect("lightsnare"),
  effect("heavysnare"),
  effect("beartrap"),
  effect("crushed"),
  effect("in_pit"),
  effect("grabbed"),
}

-- ============================================================
-- 補助 / Helpers
-- ============================================================

-- このNPCのタグ末尾を返す。対象外なら nil。
-- Returns the tag suffix for this NPC, or nil if it has no own lines.
---@param npc Npc
---@return string?
local function suffix_of(npc)
  for _, voice in ipairs(VOICES) do
    for _, trait in ipairs(voice.traits) do
      if npc:has_trait(trait) then return voice.suffix end
    end
  end
  return nil
end

---@param npc Npc
---@param effects EffectTypeId[]
---@return boolean
local function has_any_effect(npc, effects)
  for _, id in ipairs(effects) do
    if npc:has_effect(id) then return true end
  end
  return false
end

-- エラーが出たら一度だけ知らせて、以後は何もしない（毎ターンのエラー表示を防ぐ）。
-- On error, report once and then stay off (avoids an error popup every turn).
local disabled = false

---@param fn fun(params: table): boolean?
---@param params table
---@return boolean?
local function guarded(fn, params)
  if disabled then return nil end
  local ok, result = pcall(fn, params)
  if ok then return result end
  disabled = true
  local text = "VOICEROID mod: Lua error, character lines are turned off. / Luaエラーのため専用セリフを停止しました: "
    .. tostring(result)
  gdebug.log_error(text)
  gapi.add_msg(MsgType.bad, text)
  return nil
end

-- ============================================================
-- あくび・空腹・喉の渇き / Yawn, hungry, thirsty
-- ============================================================

-- 本体（npc::complain）より先に、同じ話題名で喋っておく。
-- 本体は「この話題は今言ったばかり」と判断して、自分の <yawn> などを言わない。
-- 条件と間隔は本体と同じ。
-- Speaks first, under the same issue names the game uses (npc::complain).
-- The game then sees the issue as "just said" and skips its own <yawn> etc.
-- Conditions and intervals match the game.
---@param params { npc: Npc }
local function complain(params)
  local npc = params.npc
  local suffix = suffix_of(npc)
  if not suffix then return end

  -- 仲間で、プレイヤーから見えていて、起きている時だけ
  -- Only for allies the player can see, and only while awake.
  if not npc:is_player_ally() then return end
  if has_any_effect(npc, SLEEP_EFFECTS) then return end
  if not gapi.get_avatar():sees(npc:get_pos_ms()) then return end

  -- 言う時期が来た話題は、同じターンにすべて言う。
  -- 残すと、そのターンのうちに本体が共通のセリフで言ってしまうため。
  -- Every issue that is due is said in the same turn;
  -- anything left over would be said by the game with its generic line.
  local fatigue = npc:get_fatigue()
  if fatigue > FATIGUE_TIRED then
    local forced = fatigue > FATIGUE_FORCED
    npc:complain_about("fatigue", TimeDuration.from_minutes(30), "<yawn" .. suffix .. ">", forced)
  end

  local kcal = npc:get_kcal_percent()
  if kcal < KCAL_HUNGRY then
    -- 3時間、または蓄えに応じて最長6時間ごと / every 3 hours, up to about 6 depending on stored kcal
    local minutes = math.max(180, math.floor(kcal * 60 * 7))
    npc:complain_about("hunger", TimeDuration.from_minutes(minutes), "<hungry" .. suffix .. ">", false)
  end

  if npc:get_thirst() > THIRST_VERY_THIRSTY then
    npc:complain_about("thirst", TimeDuration.from_hours(2), "<thirsty" .. suffix .. ">", false)
  end
end

-- ============================================================
-- どいて / Let me pass
-- ============================================================

-- NPCがプレイヤーのいるマスへ進もうとした時に喋る。
-- 本体はこの場面で <let_me_pass> を言って1ターン待つ（src/npcmove.cpp npc::move_to）。
-- 差し替える時は、移動をここで止めて、同じくこのターンの残りの行動を使い切る。
-- Speaks when an NPC tries to step onto the player's tile.
-- The game says <let_me_pass> here and waits a turn (src/npcmove.cpp npc::move_to).
-- When replacing, the move is stopped here and the rest of this turn's moves are spent, as the game does.
---@param params { npc: Npc, to: TripointBubMs }
---@return boolean? @false で移動を止める / false stops the move
local function let_me_pass(params)
  local npc = params.npc
  local suffix = suffix_of(npc)
  if not suffix then return nil end

  local you = gapi.get_avatar()
  if params.to ~= you:get_pos_ms() then return nil end

  -- 敵対している時は攻撃なので、本体に任せる / hostile means an attack: leave it to the game
  if npc:attitude_to(you) == Attitude.Hostile then return nil end
  if has_any_effect(npc, HINDER_EFFECTS) then return nil end

  npc:say("<let_me_pass" .. suffix .. ">")
  if not REPLACE_LET_ME_PASS then return nil end

  npc:set_moves(math.min(npc:get_moves(), 0))
  return false
end

-- ============================================================
-- フックの入口 / Hook entry points (registered in preload.lua)
-- ============================================================

mod.on_npc_do_turn = function(params) guarded(complain, params) end

mod.on_npc_try_move = function(params) return guarded(let_me_pass, params) end
