/*
	Сбор: клавиша согласия в диалогах (та же, что в макросе сбора внизу файла), внутри сферы стримера 2,5 м.
*/

#include <a_samp>
#include <streamer>
#include <a_mysql>
#include <sscanf2>
#include <zcmd>

#if !defined MAX_PLAYERS
	#define MAX_PLAYERS (1000)
#endif

#if MAX_PLAYERS > 1000
	#undef MAX_PLAYERS
	#define MAX_PLAYERS (1000)
#endif

#if !defined cache_get_field_content_int
stock cache_get_field_content_int(row, const field[]) {
	new buf[32];
	cache_get_field_content(row, field, buf, sizeof(buf));
	return strval(buf);
}
#endif
#if !defined cache_get_field_content_float
stock Float:cache_get_field_content_float(row, const field[]) {
	new buf[48];
	cache_get_field_content(row, field, buf, sizeof(buf));
	return floatstr(buf);
}
#endif

#pragma dynamic 65536

#define GH_SCRIPT_VERSION			"1"

#define GH_MAX_PER_PLAYER			(5)
#define GH_MAX_INSTANCES			(MAX_PLAYERS * GH_MAX_PER_PLAYER)

#define GH_AREA_RADIUS				(2.5)
#define GH_CMD_DISTANCE				(2.5)
#define GH_CREATE_MIN_SPACING		(5.0)
#define GH_GROW_SECONDS_BASE		(600)
#define GH_GROW_SECONDS_UPGR		(300)

#define GH_VIS_REFRESH_INTERVAL		(15000)

#define GH_ACCOUNT_PVAR				"AccountID"

#define GH_OBJ_BUILDING				(3632)
#define GH_OBJ_SEEDLING				(2203)
#define GH_OBJ_BUSH_S				(745)
#define GH_OBJ_BUSH_M				(826)
#define GH_OBJ_BUSH_L				(8268)
#define GH_OBJ_CRATE				(2912)
#define GH_OBJ_CRATE2				(2914)
#define GH_OBJ_READY_MARKER			(1559)
#define GH_OBJ_READY_EXTRA			(1273)

#define GH_STREAM_DIST				(200.0)
#define GH_AREA_PRIORITY			(0)

#define PRESSED(%1) \
	(((newkeys & (%1)) == (%1)) && ((oldkeys & (%1)) != (%1)))

#define KEY_HARVEST					(KEY_YES)

new MySQL:g_GHMySQL = MySQL:0;

#if defined GH_SQL_EXTERNAL
	forward MySQL:GH_SQL_GetHandle();
#endif

/*
	E_GHData - одна запись теплицы в оперативной памяти.
	ghUsed - слот занят (1) или свободен (0).
	ghDbId - первичный ключ строки в таблице greenhouses.
	ghOwnerAccount - номер аккаунта владельца (тот же смысл, что owner_id в БД).
	ghX, ghY, ghZ, ghRotZ - позиция и поворот по Z.
	ghPlantTime - метка посадки/цикла из БД (unix).
	ghUpgraded - флаг улучшения (0/1).
	ghCachedProgress - накопленные секунды роста, сохраняемые при выходе.
	ghSessionStartUnix - момент начала текущей "сессии" пересчёта прогресса.
	ghWorldId, ghInteriorId - виртуальный мир и интерьер для стримера.
	ghObjBuilding, ghObjA..E - динамические объекты визуала.
	ghArea - динамическая сфера для входа/выхода игрока.
	ghLastVisualStage - последня отрисованная стадии (чтобы не дергать объекты зря).
*/
enum E_GHData {
	ghUsed,
	ghDbId,
	ghOwnerAccount,
	Float:ghX,
	Float:ghY,
	Float:ghZ,
	Float:ghRotZ,
	ghPlantTime,
	ghUpgraded,
	ghCachedProgress,
	ghSessionStartUnix,
	ghWorldId,
	ghInteriorId,
	STREAMER_TAG_OBJECT:ghObjBuilding,
	STREAMER_TAG_OBJECT:ghObjA,
	STREAMER_TAG_OBJECT:ghObjB,
	STREAMER_TAG_OBJECT:ghObjC,
	STREAMER_TAG_OBJECT:ghObjD,
	STREAMER_TAG_OBJECT:ghObjE,
	STREAMER_TAG_AREA:ghArea,
	ghLastVisualStage
};

new GH_Data[GH_MAX_INSTANCES][E_GHData];

#define MAX_PLAYER_GH_ZONES			(8)
new gh_PlayerNearCount[MAX_PLAYERS];
new gh_PlayerNearSlot[MAX_PLAYERS][MAX_PLAYER_GH_ZONES];
new gh_PlayerVisTimer[MAX_PLAYERS];

new gh_PlayerCreateBusy[MAX_PLAYERS];
new gh_PlayerUpgradePending[MAX_PLAYERS];
new gh_PlayerDestroyPending[MAX_PLAYERS];
new gh_PlayerHarvestPending[MAX_PLAYERS];
new gh_AccountGHLoaded[MAX_PLAYERS];
new gh_SessionAccountId[MAX_PLAYERS];

enum E_GHPendCreate {
	ghpcSlot,
	ghpcAcc,
	ghpcVW,
	ghpcInt,
	Float:ghpcX,
	Float:ghpcY,
	Float:ghpcZ,
	Float:ghpcA
}
new gh_PendCreate[MAX_PLAYERS][E_GHPendCreate];

forward GH_SQL_OnInit();
forward GH_UnloadForPlayer(playerid, acc);
forward GH_LoadForPlayer(playerid);

forward GH_CB_Create_Count(playerid);
forward GH_CB_Create_Insert(playerid);
forward GH_CB_LoadOwner(playerid);
forward GH_CB_UpgradeRead(playerid, slot);
forward GH_CB_UpgradeWrite(playerid, slot, newProgress);
forward GH_CB_Destroy(playerid, slot);
forward GH_CB_HarvestRead(playerid, slot);
forward GH_CB_HarvestWrite(playerid, slot, reward);
forward GH_CB_SyncProgress(slot);
forward GH_CB_TableCreated();

// есть ли другая уже загруженная теплица ближе 5 м (тот же мир и интерьер)
stock GH_IsTooCloseToOtherLoaded(Float:x, Float:y, Float:z, worldid, interiorid) {
	for(new i; i < GH_MAX_INSTANCES; i++) {
		if(!GH_Data[i][ghUsed]) continue;
		if(GH_Data[i][ghWorldId] != worldid || GH_Data[i][ghInteriorId] != interiorid) continue;
		new Float:dx = x - GH_Data[i][ghX];
		new Float:dy = y - GH_Data[i][ghY];
		new Float:dz = z - GH_Data[i][ghZ];
		if(floatsqroot(dx * dx + dy * dy + dz * dz) < GH_CREATE_MIN_SPACING) {
			return 1;
		}
	}
	return 0;
}

// номер аккаунта из PVar; так же  кэшируем в gh_SessionAccountId для надёжного выхода
stock GH_GetAccountID(playerid) {
	if(!IsPlayerConnected(playerid)) return 0;
	new id = GetPVarInt(playerid, GH_ACCOUNT_PVAR);
	if(id > 0) gh_SessionAccountId[playerid] = id;
	return id;
}

stock GH_GetMySQL() {
	#if defined GH_SQL_EXTERNAL
		return GH_SQL_GetHandle();
	#else
		return g_GHMySQL;
	#endif
}

stock GH_IsValidSQL() {
	return (_:GH_GetMySQL() != 0);
}

stock GH_FindFreeSlot() {
	for(new i; i < GH_MAX_INSTANCES; i++) {
		if(!GH_Data[i][ghUsed]) return i;
	}
	return -1;
}

stock GH_GetGrowSeconds(slot) {
	return GH_Data[slot][ghUpgraded] != 0 ? (GH_GROW_SECONDS_UPGR) : (GH_GROW_SECONDS_BASE);
}

stock GH_ComputeElapsed(slot) {
	if(!GH_Data[slot][ghUsed]) return 0;
	new maxdur = GH_GetGrowSeconds(slot);
	new unixnow = gettime();
	new sess = GH_Data[slot][ghSessionStartUnix];
	new base = GH_Data[slot][ghCachedProgress];
	if(sess <= 0) sess = unixnow;
	new add = unixnow - sess;
	if(add < 0) add = 0;
	new el = base + add;
	if(el > maxdur) el = maxdur;
	return el;
}

stock Float:GH_GetProgress01(slot) {
	new maxdur = GH_GetGrowSeconds(slot);
	if(maxdur <= 0) return 0.0;
	return float(GH_ComputeElapsed(slot)) / float(maxdur);
}

stock GH_GetStageFromProgress(Float:p) {
	if(p < 0.25) return 0;
	if(p < 0.50) return 1;
	if(p < 0.75) return 2;
	if(p < 1.00) return 3;
	return 4;
}

stock GH_ClearDynObjects(slot) {
	if(GH_Data[slot][ghObjA]) {
		DestroyDynamicObject(GH_Data[slot][ghObjA]);
		GH_Data[slot][ghObjA] = STREAMER_TAG_OBJECT:0;
	}
	if(GH_Data[slot][ghObjB]) {
		DestroyDynamicObject(GH_Data[slot][ghObjB]);
		GH_Data[slot][ghObjB] = STREAMER_TAG_OBJECT:0;
	}
	if(GH_Data[slot][ghObjC]) {
		DestroyDynamicObject(GH_Data[slot][ghObjC]);
		GH_Data[slot][ghObjC] = STREAMER_TAG_OBJECT:0;
	}
	if(GH_Data[slot][ghObjD]) {
		DestroyDynamicObject(GH_Data[slot][ghObjD]);
		GH_Data[slot][ghObjD] = STREAMER_TAG_OBJECT:0;
	}
	if(GH_Data[slot][ghObjE]) {
		DestroyDynamicObject(GH_Data[slot][ghObjE]);
		GH_Data[slot][ghObjE] = STREAMER_TAG_OBJECT:0;
	}
}

stock Float:GH_OffsetX(Float:ox, Float:oy, Float:rz) {
	return floatcos(rz, degrees) * ox - floatsin(rz, degrees) * oy;
}

stock Float:GH_OffsetY(Float:ox, Float:oy, Float:rz) {
	return floatsin(rz, degrees) * ox + floatcos(rz, degrees) * oy;
}

stock GH_DestroyAreaAndBuilding(slot) {
	if(GH_Data[slot][ghArea]) {
		DestroyDynamicArea(GH_Data[slot][ghArea]);
		GH_Data[slot][ghArea] = STREAMER_TAG_AREA:0;
	}
	if(GH_Data[slot][ghObjBuilding]) {
		DestroyDynamicObject(GH_Data[slot][ghObjBuilding]);
		GH_Data[slot][ghObjBuilding] = STREAMER_TAG_OBJECT:0;
	}
	GH_ClearDynObjects(slot);
}

// визуал по стадии, вызывается только для занятого слота
stock GH_UpdateVisuals(slot) {
	new stage = GH_GetStageFromProgress(GH_GetProgress01(slot));
	if(stage == GH_Data[slot][ghLastVisualStage]) {
		if(stage != 4) return;
	}
	GH_Data[slot][ghLastVisualStage] = stage;

	GH_ClearDynObjects(slot);

	new Float:x = GH_Data[slot][ghX];
	new Float:y = GH_Data[slot][ghY];
	new Float:z = GH_Data[slot][ghZ];
	new Float:rz = GH_Data[slot][ghRotZ];
	new vw = GH_Data[slot][ghWorldId];
	new interior = GH_Data[slot][ghInteriorId];

	new Float:fx, Float:fy;

	switch(stage) {
		case 0: {
			fx = x + GH_OffsetX(0.35, 0.65, rz);
			fy = y + GH_OffsetY(0.35, 0.65, rz);
			GH_Data[slot][ghObjA] = CreateDynamicObject(GH_OBJ_SEEDLING, fx, fy, z - 0.85, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
		}
		case 1: {
			fx = x + GH_OffsetX(0.45, 0.55, rz);
			fy = y + GH_OffsetY(0.45, 0.55, rz);
			GH_Data[slot][ghObjA] = CreateDynamicObject(GH_OBJ_BUSH_S, fx, fy, z - 0.75, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
		}
		case 2: {
			fx = x + GH_OffsetX(0.50, 0.50, rz);
			fy = y + GH_OffsetY(0.50, 0.50, rz);
			GH_Data[slot][ghObjA] = CreateDynamicObject(GH_OBJ_BUSH_M, fx, fy, z - 0.70, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
			fx = x + GH_OffsetX(-0.55, 0.35, rz);
			fy = y + GH_OffsetY(-0.55, 0.35, rz);
			GH_Data[slot][ghObjB] = CreateDynamicObject(GH_OBJ_CRATE, fx, fy, z - 0.95, 0.0, 0.0, rz + 15.0, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
		}
		case 3: {
			fx = x + GH_OffsetX(0.55, 0.45, rz);
			fy = y + GH_OffsetY(0.55, 0.45, rz);
			GH_Data[slot][ghObjA] = CreateDynamicObject(GH_OBJ_BUSH_L, fx, fy, z - 0.65, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
			fx = x + GH_OffsetX(-0.60, 0.30, rz);
			fy = y + GH_OffsetY(-0.60, 0.30, rz);
			GH_Data[slot][ghObjB] = CreateDynamicObject(GH_OBJ_CRATE, fx, fy, z - 0.95, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
			fx = x + GH_OffsetX(0.50, -0.55, rz);
			fy = y + GH_OffsetY(0.50, -0.55, rz);
			GH_Data[slot][ghObjC] = CreateDynamicObject(GH_OBJ_CRATE2, fx, fy, z - 0.95, 0.0, 0.0, rz - 20.0, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
		}
		case 4: {
			fx = x + GH_OffsetX(0.55, 0.45, rz);
			fy = y + GH_OffsetY(0.55, 0.45, rz);
			GH_Data[slot][ghObjA] = CreateDynamicObject(GH_OBJ_BUSH_L, fx, fy, z - 0.65, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);

			fx = x + GH_OffsetX(-0.60, 0.30, rz);
			fy = y + GH_OffsetY(-0.60, 0.30, rz);
			GH_Data[slot][ghObjB] = CreateDynamicObject(GH_OBJ_CRATE, fx, fy, z - 0.95, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
			fx = x + GH_OffsetX(0.50, -0.55, rz);
			fy = y + GH_OffsetY(0.50, -0.55, rz);
			GH_Data[slot][ghObjC] = CreateDynamicObject(GH_OBJ_CRATE2, fx, fy, z - 0.95, 0.0, 0.0, rz - 10.0, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);

			fx = x + GH_OffsetX(0.10, 0.10, rz);
			fy = y + GH_OffsetY(0.10, 0.10, rz);
			GH_Data[slot][ghObjD] = CreateDynamicObject(GH_OBJ_READY_MARKER, fx, fy, z - 0.35, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);

			fx = x + GH_OffsetX(-0.30, -0.40, rz);
			fy = y + GH_OffsetY(-0.30, -0.40, rz);
			GH_Data[slot][ghObjE] = CreateDynamicObject(GH_OBJ_READY_EXTRA, fx, fy, z - 0.85, 0.0, 0.0, rz + 11.0, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);
		}
	}
}

stock GH_CreateWorldEntities(slot) {
	new Float:x = GH_Data[slot][ghX];
	new Float:y = GH_Data[slot][ghY];
	new Float:z = GH_Data[slot][ghZ];
	new Float:rz = GH_Data[slot][ghRotZ];
	new vw = GH_Data[slot][ghWorldId];
	new interior = GH_Data[slot][ghInteriorId];

	GH_Data[slot][ghObjBuilding] = CreateDynamicObject(GH_OBJ_BUILDING, x, y, z - 1.0, 0.0, 0.0, rz, vw, interior, -1, GH_STREAM_DIST, GH_STREAM_DIST);

	GH_Data[slot][ghArea] = CreateDynamicSphere(x, y, z - 0.5, GH_AREA_RADIUS, vw, interior, -1, GH_AREA_PRIORITY);
	Streamer_SetIntData(STREAMER_TYPE_AREA, GH_Data[slot][ghArea], E_STREAMER_EXTRA_ID, slot);

	GH_Data[slot][ghLastVisualStage] = -1;
	GH_UpdateVisuals(slot);
}

stock GH_ResetSlot(slot) {
	GH_DestroyAreaAndBuilding(slot);
	GH_Data[slot][ghUsed] = 0;
	GH_Data[slot][ghDbId] = 0;
	GH_Data[slot][ghOwnerAccount] = 0;
	GH_Data[slot][ghPlantTime] = 0;
	GH_Data[slot][ghUpgraded] = 0;
	GH_Data[slot][ghCachedProgress] = 0;
	GH_Data[slot][ghSessionStartUnix] = 0;
	GH_Data[slot][ghLastVisualStage] = -1;
}

stock GH_RemovePlayerFromNear(playerid, slot) {
	for(new i; i < gh_PlayerNearCount[playerid]; i++) {
		if(gh_PlayerNearSlot[playerid][i] == slot) {
			for(new j = i; j < gh_PlayerNearCount[playerid] - 1; j++) {
				gh_PlayerNearSlot[playerid][j] = gh_PlayerNearSlot[playerid][j + 1];
			}
			gh_PlayerNearCount[playerid]--;
			return;
		}
	}
}

stock GH_AddPlayerNear(playerid, slot) {
	for(new i; i < gh_PlayerNearCount[playerid]; i++) {
		if(gh_PlayerNearSlot[playerid][i] == slot) return;
	}
	if(gh_PlayerNearCount[playerid] >= MAX_PLAYER_GH_ZONES) return;
	gh_PlayerNearSlot[playerid][gh_PlayerNearCount[playerid]++] = slot;
}

// выбор слота из зон рядом; requireOwner - только свои теплицы
stock GH_PlayerPickInteractSlot(playerid, requireOwner, &Float:bestDist) {
	bestDist = 999999.0;
	new best = -1;

	for(new i; i < gh_PlayerNearCount[playerid]; i++) {
		new slot = gh_PlayerNearSlot[playerid][i];
		if(slot < 0 || slot >= GH_MAX_INSTANCES) continue;
		if(!GH_Data[slot][ghUsed]) continue;
		if(requireOwner != 0 && GH_Data[slot][ghOwnerAccount] != GH_GetAccountID(playerid)) continue;

		new Float:dist = GetPlayerDistanceFromPoint(playerid, GH_Data[slot][ghX], GH_Data[slot][ghY], GH_Data[slot][ghZ]);
		if(dist > GH_CMD_DISTANCE) continue;
		if(dist < bestDist) {
			bestDist = dist;
			best = slot;
		}
	}
	return best;
}

stock GH_StartVisTimerIfNeeded(playerid) {
	if(gh_PlayerVisTimer[playerid]) return;
	if(gh_PlayerNearCount[playerid] <= 0) return;
	gh_PlayerVisTimer[playerid] = SetTimerEx("GH_OnVisRefresh", GH_VIS_REFRESH_INTERVAL, true, "i", playerid);
}

stock GH_StopVisTimer(playerid) {
	if(gh_PlayerVisTimer[playerid]) {
		KillTimer(gh_PlayerVisTimer[playerid]);
		gh_PlayerVisTimer[playerid] = 0;
	}
}

forward GH_OnVisRefresh(playerid);
public GH_OnVisRefresh(playerid) {
	if(!IsPlayerConnected(playerid)) {
		GH_StopVisTimer(playerid);
		return 0;
	}
	if(gh_PlayerNearCount[playerid] <= 0) {
		GH_StopVisTimer(playerid);
		return 0;
	}
	for(new i; i < gh_PlayerNearCount[playerid]; i++) {
		new slot = gh_PlayerNearSlot[playerid][i];
		if(GH_Data[slot][ghUsed]) GH_UpdateVisuals(slot);
	}
	return 1;
}

public OnFilterScriptInit() {
	new buf[96];
	format(buf, sizeof(buf), "[теплицы] Запуск фильтра, версия %s.", GH_SCRIPT_VERSION);
	print(buf);
	GH_SQL_OnInit();
	return 1;
}

public OnFilterScriptExit() {
	for(new p; p < MAX_PLAYERS; p++) {
		if(IsPlayerConnected(p)) {
			GH_UnloadForPlayer(p, 0);
		}
		GH_StopVisTimer(p);
	}
	for(new i; i < GH_MAX_INSTANCES; i++) {
		if(GH_Data[i][ghUsed]) GH_ResetSlot(i);
	}
	return 1;
}

public OnPlayerConnect(playerid) {
	gh_PlayerNearCount[playerid] = 0;
	gh_PlayerVisTimer[playerid] = 0;
	gh_PlayerCreateBusy[playerid] = 0;
	gh_SessionAccountId[playerid] = 0;
	gh_AccountGHLoaded[playerid] = 0;
	gh_PlayerUpgradePending[playerid] = -1;
	gh_PlayerDestroyPending[playerid] = -1;
	gh_PlayerHarvestPending[playerid] = -1;
	return 1;
}

public OnPlayerDisconnect(playerid, reason) {
	GH_UnloadForPlayer(playerid, gh_SessionAccountId[playerid]);
	gh_SessionAccountId[playerid] = 0;
	GH_StopVisTimer(playerid);
	gh_PlayerNearCount[playerid] = 0;
	return 1;
}

public OnPlayerSpawn(playerid) {
	if(GH_GetAccountID(playerid) > 0 && gh_AccountGHLoaded[playerid] == 0) {
		GH_LoadForPlayer(playerid);
	}
	return 1;
}

public OnPlayerEnterDynamicArea(playerid, STREAMER_TAG_AREA:areaid) {
	new slot = Streamer_GetIntData(STREAMER_TYPE_AREA, areaid, E_STREAMER_EXTRA_ID);
	if(slot < 0 || slot >= GH_MAX_INSTANCES) return 1;
	if(!GH_Data[slot][ghUsed]) return 1;

	GH_AddPlayerNear(playerid, slot);
	GH_UpdateVisuals(slot);
	GH_StartVisTimerIfNeeded(playerid);
	return 1;
}

public OnPlayerLeaveDynamicArea(playerid, STREAMER_TAG_AREA:areaid) {
	new slot = Streamer_GetIntData(STREAMER_TYPE_AREA, areaid, E_STREAMER_EXTRA_ID);
	if(slot >= 0 && slot < GH_MAX_INSTANCES) {
		GH_RemovePlayerFromNear(playerid, slot);
	}
	if(gh_PlayerNearCount[playerid] <= 0) {
		GH_StopVisTimer(playerid);
	}
	return 1;
}

public OnPlayerKeyStateChange(playerid, newkeys, oldkeys) {
	if(!PRESSED(KEY_HARVEST)) return 1;
	if(!IsPlayerConnected(playerid)) return 1;
	if(GH_GetAccountID(playerid) <= 0) return 1;

	new Float:d;
	new slot = GH_PlayerPickInteractSlot(playerid, 0, d);
	if(slot < 0) return 1;

	if(GH_Data[slot][ghOwnerAccount] != GH_GetAccountID(playerid)) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Эта теплица принадлежит другому игроку.");
		return 1;
	}

	if(gh_PlayerHarvestPending[playerid] != -1) {
		SendClientMessage(playerid, 0xFFFF88FF, "[Теплица] Дождитесь окончания предыдущего действия.");
		return 1;
	}

	gh_PlayerHarvestPending[playerid] = slot;

	new query[256];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"SELECT id, owner_id, upgraded, plant_time, cached_progress FROM greenhouses WHERE id=%d LIMIT 1",
		GH_Data[slot][ghDbId]);
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_HarvestRead", "ii", playerid, slot);
	return 1;
}

CMD:creategreenhouse(playerid, params[]) {
	sscanf(params, " ");
	if(!GH_IsValidSQL()) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] База данных для этого фильтрскрипта не настроена.");
		return 1;
	}
	if(GH_GetAccountID(playerid) <= 0) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Аккаунт ещё не загружен (нет номера в базе).");
		return 1;
	}
	if(gh_PlayerCreateBusy[playerid] != 0) {
		SendClientMessage(playerid, 0xFFFF88FF, "[Теплица] Подождите, создание ещё обрабатывается.");
		return 1;
	}
	if(IsPlayerInAnyVehicle(playerid) || GetPlayerState(playerid) != PLAYER_STATE_ONFOOT) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Встаньте на ноги (выйдите из транспорта), чтобы поставить теплицу.");
		return 1;
	}

	gh_PlayerCreateBusy[playerid] = 1;

	new query[160];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"SELECT COUNT(*) AS c FROM greenhouses WHERE owner_id=%d",
		GH_GetAccountID(playerid));
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_Create_Count", "i", playerid);
	return 1;
}

CMD:upgradegreenhouse(playerid, params[]) {
	sscanf(params, " ");
	if(!GH_IsValidSQL()) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] База данных для этого фильтрскрипта не настроена.");
		return 1;
	}
	if(GH_GetAccountID(playerid) <= 0) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Аккаунт ещё не загружен.");
		return 1;
	}
	if(gh_PlayerUpgradePending[playerid] != -1) {
		SendClientMessage(playerid, 0xFFFF88FF, "[Теплица] Подождите, улучшение ещё обрабатывается.");
		return 1;
	}

	new Float:d;
	new slot = GH_PlayerPickInteractSlot(playerid, 1, d);
	if(slot < 0) {
		new msg[160];
		format(msg, sizeof(msg), "[Теплица] Подойдите к своей теплице ближе (до %.1f м, зона взаимодействия).", GH_CMD_DISTANCE);
		SendClientMessage(playerid, 0xFF8888FF, msg);
		return 1;
	}
	if(GH_Data[slot][ghUpgraded] != 0) {
		SendClientMessage(playerid, 0xFFFF88FF, "[Теплица] Эта теплица уже улучшена.");
		return 1;
	}

	gh_PlayerUpgradePending[playerid] = slot;

	new query[256];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"SELECT id, upgraded, cached_progress, plant_time FROM greenhouses WHERE id=%d AND owner_id=%d LIMIT 1",
		GH_Data[slot][ghDbId], GH_GetAccountID(playerid));
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_UpgradeRead", "ii", playerid, slot);
	return 1;
}

CMD:destroygreenhouse(playerid, params[]) {
	sscanf(params, " ");
	if(!GH_IsValidSQL()) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] База данных для этого фильтрскрипта не настроена.");
		return 1;
	}
	if(GH_GetAccountID(playerid) <= 0) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Аккаунт ещё не загружен.");
		return 1;
	}
	if(gh_PlayerDestroyPending[playerid] != -1) {
		SendClientMessage(playerid, 0xFFFF88FF, "[Теплица] Подождите, удаление ещё обрабатывается.");
		return 1;
	}

	new Float:d;
	new slot = GH_PlayerPickInteractSlot(playerid, 1, d);
	if(slot < 0) {
		new msg[160];
		format(msg, sizeof(msg), "[Теплица] Подойдите к своей теплице ближе (до %.1f м, зона взаимодействия).", GH_CMD_DISTANCE);
		SendClientMessage(playerid, 0xFF8888FF, msg);
		return 1;
	}

	gh_PlayerDestroyPending[playerid] = slot;

	new query[192];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"DELETE FROM greenhouses WHERE id=%d AND owner_id=%d LIMIT 1",
		GH_Data[slot][ghDbId], GH_GetAccountID(playerid));
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_Destroy", "ii", playerid, slot);
	return 1;
}

CMD:greenhouse(playerid, params[]) {
	sscanf(params, " ");
	SendClientMessage(playerid, 0x88CCFF, "[Теплица]  Справка: четыре команды объявлены в этом файле через директиву команды (см. исходник). Сбор урожая — та же клавиша, что «да» в диалогах.");
	return 1;
}

public GH_CB_Create_Count(playerid) {
	if(!IsPlayerConnected(playerid)) {
		gh_PlayerCreateBusy[playerid] = 0;
		return;
	}
	if(gh_PlayerCreateBusy[playerid] == 0) {
		return;
	}

	new rows = cache_num_rows();
	if(!rows) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Ошибка базы при подсчёте теплиц.");
		gh_PlayerCreateBusy[playerid] = 0;
		return;
	}

	new count = cache_get_field_content_int(0, "c");
	if(count >= GH_MAX_PER_PLAYER) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] У вас уже максимум теплиц (" #GH_MAX_PER_PLAYER ").");
		gh_PlayerCreateBusy[playerid] = 0;
		return;
	}

	new slot = GH_FindFreeSlot();
	if(slot < 0) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] На сервере закончились слоты под теплицы, попробуйте позже.");
		gh_PlayerCreateBusy[playerid] = 0;
		return;
	}

	new Float:x, Float:y, Float:z, Float:a;
	GetPlayerPos(playerid, x, y, z);
	GetPlayerFacingAngle(playerid, a);

	new vw = GetPlayerVirtualWorld(playerid);
	new interior = GetPlayerInterior(playerid);

	if(GH_IsTooCloseToOtherLoaded(x, y, z, vw, interior)) {
		SendClientMessage(playerid, 0xFF8888FF, "Слишком близко к другой теплице");
		gh_PlayerCreateBusy[playerid] = 0;
		return;
	}

	new acc = GH_GetAccountID(playerid);
	new unixnow = gettime();

	gh_PendCreate[playerid][ghpcSlot] = slot;
	gh_PendCreate[playerid][ghpcAcc] = acc;
	gh_PendCreate[playerid][ghpcVW] = vw;
	gh_PendCreate[playerid][ghpcInt] = interior;
	gh_PendCreate[playerid][ghpcX] = x;
	gh_PendCreate[playerid][ghpcY] = y;
	gh_PendCreate[playerid][ghpcZ] = z;
	gh_PendCreate[playerid][ghpcA] = a;

	new query[384];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"INSERT INTO greenhouses (owner_id,pos_x,pos_y,pos_z,rot,plant_time,upgraded,cached_progress,world_id,interior_id) VALUES (%d,%f,%f,%f,%f,%d,0,0,%d,%d)",
		acc, x, y, z, a, unixnow, vw, interior);
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_Create_Insert", "i", playerid);
}

public GH_CB_Create_Insert(playerid) {
	if(!IsPlayerConnected(playerid)) {
		gh_PlayerCreateBusy[playerid] = 0;
		return;
	}

	new slot = gh_PendCreate[playerid][ghpcSlot];
	new accid = gh_PendCreate[playerid][ghpcAcc];
	new vw = gh_PendCreate[playerid][ghpcVW];
	new interior = gh_PendCreate[playerid][ghpcInt];
	new Float:x = gh_PendCreate[playerid][ghpcX];
	new Float:y = gh_PendCreate[playerid][ghpcY];
	new Float:z = gh_PendCreate[playerid][ghpcZ];
	new Float:a = gh_PendCreate[playerid][ghpcA];

	gh_PlayerCreateBusy[playerid] = 0;

	if(slot < 0 || slot >= GH_MAX_INSTANCES) return;

	if(accid > 0) gh_SessionAccountId[playerid] = accid;

	new insertid = cache_insert_id();
	if(insertid <= 0) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Не удалось записать теплицу в базу.");
		return;
	}

	GH_Data[slot][ghUsed] = 1;
	GH_Data[slot][ghDbId] = insertid;
	GH_Data[slot][ghOwnerAccount] = accid;
	GH_Data[slot][ghX] = x;
	GH_Data[slot][ghY] = y;
	GH_Data[slot][ghZ] = z;
	GH_Data[slot][ghRotZ] = a;
	GH_Data[slot][ghPlantTime] = gettime();
	GH_Data[slot][ghUpgraded] = 0;
	GH_Data[slot][ghCachedProgress] = 0;
	GH_Data[slot][ghSessionStartUnix] = gettime();
	GH_Data[slot][ghWorldId] = vw;
	GH_Data[slot][ghInteriorId] = interior;

	GH_CreateWorldEntities(slot);

	new msg[180];
	format(msg, sizeof(msg), "[Теплица] Создана теплица номер %d. Урожай будет готов через %d мин. Нажмите клавишу сбора в зоне у теплицы.", insertid, GH_GROW_SECONDS_BASE / 60);
	SendClientMessage(playerid, 0x88FF88FF, msg);
}

public GH_CB_UpgradeRead(playerid, slot) {
	if(!IsPlayerConnected(playerid)) {
		gh_PlayerUpgradePending[playerid] = -1;
		return;
	}
	if(gh_PlayerUpgradePending[playerid] != slot) {
		gh_PlayerUpgradePending[playerid] = -1;
		return;
	}
	gh_PlayerUpgradePending[playerid] = -1;

	if(!cache_num_rows()) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Теплица не найдена или не принадлежит вам.");
		return;
	}

	new upgraded = cache_get_field_content_int(0, "upgraded");
	if(upgraded != 0) {
		SendClientMessage(playerid, 0xFFFF88FF, "[Теплица] Уже улучшена.");
		return;
	}

	if(slot < 0 || slot >= GH_MAX_INSTANCES || !GH_Data[slot][ghUsed]) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Состояние разошлось с базой, перезайдите.");
		return;
	}

	new unixnow = gettime();
	new baseOld = GH_ComputeElapsed(slot);
	new maxOld = GH_GROW_SECONDS_BASE;
	if(baseOld > maxOld) baseOld = maxOld;

	new rem = maxOld - baseOld;
	new newRem = rem / 2;
	new newElapsed = (GH_GROW_SECONDS_UPGR) - newRem;
	if(newElapsed < 0) newElapsed = 0;
	if(newElapsed > GH_GROW_SECONDS_UPGR) newElapsed = GH_GROW_SECONDS_UPGR;

	GH_Data[slot][ghUpgraded] = 1;
	GH_Data[slot][ghCachedProgress] = newElapsed;
	GH_Data[slot][ghSessionStartUnix] = unixnow;

	new query[256];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"UPDATE greenhouses SET upgraded=1, cached_progress=%d WHERE id=%d AND owner_id=%d LIMIT 1",
		newElapsed, GH_Data[slot][ghDbId], GH_GetAccountID(playerid));
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_UpgradeWrite", "iii", playerid, slot, newElapsed);

	GH_UpdateVisuals(slot);

	SendClientMessage(playerid, 0x88FF88, "[Теплица] Улучшение установлено: рост вдвое быстрее (около пяти минут на цикл).");
}

public GH_CB_UpgradeWrite(playerid, slot, newProgress) {
}

public GH_CB_Destroy(playerid, slot) {
	if(!IsPlayerConnected(playerid)) {
		gh_PlayerDestroyPending[playerid] = -1;
		return;
	}
	if(gh_PlayerDestroyPending[playerid] != slot) {
		gh_PlayerDestroyPending[playerid] = -1;
		return;
	}
	gh_PlayerDestroyPending[playerid] = -1;

	if(slot < 0 || slot >= GH_MAX_INSTANCES) return;

	if(cache_affected_rows() <= 0) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Не удалось удалить (нет записи или не ваш объект).");
		return;
	}

	GH_ResetSlot(slot);
	SendClientMessage(playerid, 0x88FF88FF, "[Теплица] Теплица удалена.");
}

public GH_CB_HarvestRead(playerid, slot) {
	if(!IsPlayerConnected(playerid)) {
		gh_PlayerHarvestPending[playerid] = -1;
		return;
	}
	if(gh_PlayerHarvestPending[playerid] != slot) {
		gh_PlayerHarvestPending[playerid] = -1;
		return;
	}

	if(!cache_num_rows()) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Такой записи в базе уже нет.");
		gh_PlayerHarvestPending[playerid] = -1;
		return;
	}

	new ownerdb = cache_get_field_content_int(0, "owner_id");
	if(ownerdb != GH_GetAccountID(playerid)) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Вы не владелец этой теплицы.");
		gh_PlayerHarvestPending[playerid] = -1;
		return;
	}

	new upgraded = cache_get_field_content_int(0, "upgraded");

	if(slot < 0 || slot >= GH_MAX_INSTANCES || !GH_Data[slot][ghUsed]) {
		gh_PlayerHarvestPending[playerid] = -1;
		return;
	}

	GH_Data[slot][ghUpgraded] = upgraded != 0 ? 1 : 0;

	new maxdur = GH_GetGrowSeconds(slot);
	new elapsed = GH_ComputeElapsed(slot);

	if(elapsed < maxdur) {
		new remain = maxdur - elapsed;
		new msg[128];
		format(msg, sizeof(msg), "[Теплица] Ещё рано. Осталось примерно %d сек.", remain);
		SendClientMessage(playerid, 0xFFFF88FF, msg);
		gh_PlayerHarvestPending[playerid] = -1;
		return;
	}

	new reward = 250 + random(150);
	new unixnow = gettime();

	new query[256];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"UPDATE greenhouses SET plant_time=%d, cached_progress=0, upgraded=0 WHERE id=%d AND owner_id=%d LIMIT 1",
		unixnow, GH_Data[slot][ghDbId], GH_GetAccountID(playerid));
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_HarvestWrite", "iii", playerid, slot, reward);
}

public GH_CB_HarvestWrite(playerid, slot, reward) {
	gh_PlayerHarvestPending[playerid] = -1;

	if(!IsPlayerConnected(playerid)) return;
	if(slot < 0 || slot >= GH_MAX_INSTANCES) return;

	if(cache_affected_rows() <= 0) {
		SendClientMessage(playerid, 0xFF8888FF, "[Теплица] Не удалось сохранить сбор, попробуйте снова.");
		return;
	}

	if(!GH_Data[slot][ghUsed]) return;

	new unixnow = gettime();
	GivePlayerMoney(playerid, reward);

	GH_Data[slot][ghPlantTime] = unixnow;
	GH_Data[slot][ghCachedProgress] = 0;
	GH_Data[slot][ghSessionStartUnix] = unixnow;
	GH_Data[slot][ghUpgraded] = 0;
	GH_UpdateVisuals(slot);

	new msg[144];
	format(msg, sizeof(msg), "[Теплица] Урожай продан за $%d ,  посажен новый цикл.", reward);
	SendClientMessage(playerid, 0x88FF88, msg);
}

stock GH_FlushProgressToDB(slot) {
	if(!GH_IsValidSQL()) return;
	if(slot < 0 || slot >= GH_MAX_INSTANCES) return;
	if(!GH_Data[slot][ghUsed]) return;

	new unixnow = gettime();
	new add = unixnow - GH_Data[slot][ghSessionStartUnix];
	if(add < 0) add = 0;
	new merged = GH_Data[slot][ghCachedProgress] + add;
	new maxdur = GH_GetGrowSeconds(slot);
	if(merged > maxdur) merged = maxdur;

	new query[192];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"UPDATE greenhouses SET cached_progress=%d WHERE id=%d AND owner_id=%d LIMIT 1",
		merged, GH_Data[slot][ghDbId], GH_Data[slot][ghOwnerAccount]);
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_SyncProgress", "i", slot);

	GH_Data[slot][ghCachedProgress] = merged;
	GH_Data[slot][ghSessionStartUnix] = unixnow;
}

public GH_CB_SyncProgress(slot) {
}

public GH_UnloadForPlayer(playerid, acc) {
	if(acc <= 0) acc = GH_GetAccountID(playerid);
	if(acc <= 0) acc = gh_SessionAccountId[playerid];
	if(acc <= 0) return;

	for(new i; i < GH_MAX_INSTANCES; i++) {
		if(GH_Data[i][ghUsed] && GH_Data[i][ghOwnerAccount] == acc) {
			GH_FlushProgressToDB(i);
			GH_ResetSlot(i);
		}
	}
	GH_StopVisTimer(playerid);
	gh_PlayerNearCount[playerid] = 0;
	gh_AccountGHLoaded[playerid] = 0;
}

stock GH_ApplyRowToSlot(slot, dbid, ownerid, Float:x, Float:y, Float:z, Float:rot, planttime, upgraded, cachedprogress, vw, interior) {
	GH_Data[slot][ghUsed] = 1;
	GH_Data[slot][ghDbId] = dbid;
	GH_Data[slot][ghOwnerAccount] = ownerid;
	GH_Data[slot][ghX] = x;
	GH_Data[slot][ghY] = y;
	GH_Data[slot][ghZ] = z;
	GH_Data[slot][ghRotZ] = rot;
	GH_Data[slot][ghPlantTime] = planttime;
	GH_Data[slot][ghUpgraded] = upgraded != 0 ? 1 : 0;
	GH_Data[slot][ghCachedProgress] = cachedprogress;
	GH_Data[slot][ghSessionStartUnix] = gettime();
	GH_Data[slot][ghWorldId] = vw;
	GH_Data[slot][ghInteriorId] = interior;
	GH_CreateWorldEntities(slot);
}

public GH_LoadForPlayer(playerid) {
	if(!GH_IsValidSQL()) return;
	new acc = GH_GetAccountID(playerid);
	if(acc <= 0) return;

	GH_UnloadForPlayer(playerid, acc);

	new query[256];
	mysql_format(GH_GetMySQL(), query, sizeof(query),
		"SELECT id, owner_id, pos_x, pos_y, pos_z, rot, plant_time, upgraded, cached_progress, world_id, interior_id FROM greenhouses WHERE owner_id=%d",
		acc);
	mysql_tquery(GH_GetMySQL(), query, "GH_CB_LoadOwner", "i", playerid);
}

public GH_CB_LoadOwner(playerid) {
	if(!IsPlayerConnected(playerid)) return;
	new acc = GH_GetAccountID(playerid);
	if(acc <= 0) return;

	gh_SessionAccountId[playerid] = acc;

	new rows = cache_num_rows();

	for(new r; r < rows; r++) {
		new slot = GH_FindFreeSlot();
		if(slot < 0) {
			print("[теплицы] Внимание: при загрузке превышен лимит слотов под теплицы на сервере.");
			break;
		}

		new dbid = cache_get_field_content_int(r, "id");
		new ownerid = cache_get_field_content_int(r, "owner_id");
		new Float:x = cache_get_field_content_float(r, "pos_x");
		new Float:y = cache_get_field_content_float(r, "pos_y");
		new Float:z = cache_get_field_content_float(r, "pos_z");
		new Float:rot = cache_get_field_content_float(r, "rot");
		new planttime = cache_get_field_content_int(r, "plant_time");
		new upgraded = cache_get_field_content_int(r, "upgraded");
		new cachedprogress = cache_get_field_content_int(r, "cached_progress");
		new vw = cache_get_field_content_int(r, "world_id");
		new interior = cache_get_field_content_int(r, "interior_id");

		GH_ApplyRowToSlot(slot, dbid, ownerid, x, y, z, rot, planttime, upgraded, cachedprogress, vw, interior);
	}

	gh_AccountGHLoaded[playerid] = 1;

	new msg[128];
	format(msg, sizeof(msg), "[теплица] Загружено теплиц: %d. Сбор у своей теплицы — клавиша «да» в диалогах (см. шапку скрипта).", rows);
	SendClientMessage(playerid, 0x88CCFFFF, msg);
}

public GH_SQL_OnInit() {
	if(!GH_IsValidSQL()) {
		print("[теплицы] Внимание: глобальный дескриптор базы нулевой, подключение не задано.");
		return;
	}

	new q[] = "\
CREATE TABLE IF NOT EXISTS greenhouses ( \
id INT AUTO_INCREMENT PRIMARY KEY, \
owner_id INT NOT NULL, \
pos_x FLOAT NOT NULL, \
pos_y FLOAT NOT NULL, \
pos_z FLOAT NOT NULL, \
rot FLOAT NOT NULL DEFAULT 0.0, \
plant_time INT UNSIGNED NOT NULL, \
upgraded TINYINT NOT NULL DEFAULT 0, \
cached_progress INT UNSIGNED NOT NULL DEFAULT 0, \
world_id INT NOT NULL DEFAULT 0, \
interior_id INT NOT NULL DEFAULT 0, \
INDEX(owner_id) \
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4";

	mysql_tquery(GH_GetMySQL(), q, "GH_CB_TableCreated");
}

public GH_CB_TableCreated() {
	print("[теплицы] Таблица создана");
	return;
}

// вызвать из геймода, когда номер аккаунта в базе стал известен позже спавна
stock GH_NotifyAccountReady(playerid) {
	if(!IsPlayerConnected(playerid)) return;
	if(GH_GetAccountID(playerid) <= 0) return;
	gh_AccountGHLoaded[playerid] = 0;
	GH_LoadForPlayer(playerid);
}

// заглушка под будущую связку с предметом «томат»; переменная пока нигде не читается
new gh_scrappedFeatureFlag;
