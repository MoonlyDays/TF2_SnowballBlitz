#include <sdkhooks>
#include <sdktools>
#include <sourcemod>
#include <tf2>
#include <tf2items>
#include <tf2_stocks>
#include <tf2attributes>
#include <dhooks>

#pragma newdecls required
#pragma semicolon 1

// CONSTS
#define TF_MAX_CLASS_TYPES 9
#define TF_MAX_WEAPON_SLOTS 5

enum
{
	TF_AMMO_DUMMY,
	TF_AMMO_PRIMARY,
	TF_AMMO_SECONDARY,
	TF_AMMO_METAL,

	TF_AMMO_GRENADES1,
	TF_AMMO_GRENADES2,
	TF_AMMO_GRENADES3,

	TF_AMMO_COUNT
}

#define DMG_IGNORE_MAXHEALTH DMG_BULLET
#define DMG_IGNORE_DEBUFFS DMG_SLASH

public Plugin myinfo =
{
	name = "[TF2] Snowball Blitz",
	author = "Moonly Days",
	description = "",
	version = "1.0.0",
	url = "https://github.com/MoonlyDays/TF2_SnowballBlitz"
};

//---------------------------------------------------------------//
// ConVars
//---------------------------------------------------------------//
ConVar sb_respawn_uber_time;
ConVar sb_disable_falldamage;
ConVar sb_player_maxspeed;
ConVar sb_player_maxhealth;
ConVar sb_player_regenerate_health_per_second;
ConVar sb_player_regenerate_safe_time;

//---------------------------------------------------------------//
// NATIVE DHOOKS HOOKS
//---------------------------------------------------------------//
Handle gHook_CTFGameRules_FlPlayerFallDamage;
Handle gHook_CTFPlayer_TakeHealth;
Handle gHook_CTFWeaponBase_PrimaryAttack;

//---------------------------------------------------------------//
// NATIVE SDKCalls
//---------------------------------------------------------------//
Handle gCall_CTFWeaponBase_SendWeaponAnim;

//---------------------------------------------------------------//
// GLOBAL DATA
//---------------------------------------------------------------//
float g_flLastDamageTime[MAXPLAYERS + 1];

public void OnPluginStart()
{
	//
	// ConVars
	//
	sb_respawn_uber_time = 		CreateConVar("sb_respawn_uber_time", 	"3", 	"How much time will players be ubercharged after respawn to prevent spawn camping.");
	sb_disable_falldamage = 	CreateConVar("sb_disable_falldamage", 	"1", 	"If true, fall damage will be fully disabled.");
	sb_player_maxspeed =		CreateConVar("sb_player_maxspeed", 		"300", 	"Speed of all players.");
	sb_player_maxhealth = 		CreateConVar("sb_player_maxhealth",		"300");
	sb_player_regenerate_health_per_second 	= CreateConVar("sb_player_regenerate_health_per_second", "10");
	sb_player_regenerate_safe_time 			= CreateConVar("sb_player_regenerate_safe_time", "5");

	SetupNativeConVars();
	
	//
	// Events
	//
	HookEvent("player_spawn", evPlayerSpawn);
	HookEvent("post_inventory_application", evPostInventoryApplication);

	//
	// DHOOKS & SDKCalls
	//

	Handle hGameData = LoadGameConfigFile("tf2.snowballblitz");
	if(hGameData == INVALID_HANDLE)
	{
		SetFailState("Failed to load the plugin, missing \"gamedata/tf2.snowballblitz.txt\" file.");
		return;
	}

	// CTFGameRules::FlPlayerFallDamage(CBasePlayer*)
	int offset = GameConfGetOffset(hGameData, "CTFGameRules::FlPlayerFallDamage");
	gHook_CTFGameRules_FlPlayerFallDamage = DHookCreate(offset, HookType_GameRules, ReturnType_Float, ThisPointer_Ignore, CTFGameRules_FlPlayerFallDamage);
	DHookAddParam(gHook_CTFGameRules_FlPlayerFallDamage, HookParamType_CBaseEntity);

	// CTFPlayer::TakeHealth
	offset = GameConfGetOffset(hGameData, "CTFPlayer::TakeHealth");
	gHook_CTFPlayer_TakeHealth = DHookCreate(offset, HookType_Entity, ReturnType_Int, ThisPointer_CBaseEntity, CTFPlayer_TakeHealth);
	DHookAddParam(gHook_CTFPlayer_TakeHealth, HookParamType_Float);
	DHookAddParam(gHook_CTFPlayer_TakeHealth, HookParamType_Int);

	// CTFWeaponBase::PrimaryAttack
	offset = GameConfGetOffset(hGameData, "CTFWeaponBase::PrimaryAttack");
	gHook_CTFWeaponBase_PrimaryAttack = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, CTFWeaponBase_PrimaryAttack);

	//
	// SDK Calls
	//
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CTFWeaponBase::SendWeaponAnim");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	gCall_CTFWeaponBase_SendWeaponAnim = EndPrepSDKCall();

	// Late Hook
	SB_HookAllPlayers();
	CreateTimer(1.0, Timer_RegenerateHealth, _, TIMER_REPEAT);
}

public void OnMapStart()
{
	DHookGamerules(gHook_CTFGameRules_FlPlayerFallDamage, false);
}

public void OnClientPutInServer(int client)
{
	SB_HookPlayer(client);
}

public void SetupNativeConVars()
{
	SetConVarInt(FindConVar("mp_respawnwavetime"), 0);
	SetConVarInt(FindConVar("tf_scout_air_dash_count"), 0);
}

//---------------------------------------------------------------//
// GAMEPLAY FUNCTIONS
//---------------------------------------------------------------//

public void SB_HookAllPlayers()
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsValidClient(i))
			continue;

		SB_HookPlayer(i);
	}
}

public void SB_HookPlayer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);
	DHookEntity(gHook_CTFPlayer_TakeHealth, false, client);
}

public void SB_SetupPlayer(int client)
{
	// Reset all global variables
	g_flLastDamageTime[client] = 0.0;

	// Set client's class to random one.
	TF2_SetRandomPlayerClass(client);

	// Regenerate the client so they have all their cosmetics and weapons.
	TF2_RegeneratePlayer(client);
	
	// 3 seconds of ubercharge when we respawn
	TF2_AddCondition(client, TFCond_UberchargedCanteen, sb_respawn_uber_time.FloatValue);
	
	// Update maximum speed of the player to 300 HU
	TFClassType pClass = TF2_GetPlayerClass(client);
	float baseClassSpeed = TF2_GetClassMaxSpeed(pClass);
	float maxSpeedMult = sb_player_maxspeed.FloatValue / baseClassSpeed;
	TF2Attrib_SetByName(client, "move speed bonus", maxSpeedMult);

	// Update maximum health of the player to 300 HP
	int baseClassHealth = TF2_GetClassMaxHealth(pClass);
	int maxHealthBonus = sb_player_maxhealth.IntValue - baseClassHealth;
	TF2Attrib_SetByName(client, "max health additive bonus", float(maxHealthBonus));
	SetEntityHealth(client, sb_player_maxhealth.IntValue);
	PrintToChatAll("SB_SetupPlayer");
}

public void SB_ValidatePlayerWeapons(int client)
{
	int firstAllowedWeapon = -1;

	for(int i = 0; i < TF_MAX_WEAPON_SLOTS; i++)
	{
		int iWeapon = GetPlayerWeaponSlot(client, i);
		if(iWeapon < 0) 
			continue;

		if(SB_IsWeaponAllowed(client, iWeapon, i))
		{
			if(firstAllowedWeapon < 0) firstAllowedWeapon = iWeapon;
			continue;
		}

		TF2_RemoveWeaponSlot(client, i);
	}

	// Switch to the first weapon we're allowed to switch to.
	if(firstAllowedWeapon > 0)
	{
		SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", firstAllowedWeapon);
	}

	SB_GiveClientSnowball(client);
}

public bool SB_IsWeaponAllowed(int client, int weapon, int slot)
{
	// All melees are permitted.
	if(slot == 2)
		return true;

	return false;
}

public int SB_GiveClientSnowball(int client)
{
	Handle itemData = TF2Items_CreateItem( OVERRIDE_ALL );
	TF2Items_SetClassname(itemData, "tf_weapon_jar");
	TF2Items_SetItemIndex(itemData, 1070);

	int weapon = TF2Items_GiveNamedItem(client, itemData);
	CloseHandle(itemData);
	
	EquipPlayerWeapon(client, weapon);
	RequestFrame(RF_SB_GiveClientSnowball, client);
	DHookEntity(gHook_CTFWeaponBase_PrimaryAttack, false, weapon);
	
	return weapon;
}

public void RF_SB_GiveClientSnowball(any client)
{
	SetEntProp(client, Prop_Send, "m_iAmmo", 5, 4, TF_AMMO_GRENADES1);
	SetEntProp(client, Prop_Send, "m_iAmmo", 5, 4, TF_AMMO_GRENADES2);
	SetEntProp(client, Prop_Send, "m_iAmmo", 5, 4, TF_AMMO_GRENADES3);
}

public Action Timer_RegenerateHealth(Handle hTimer, any data)
{
	float curTime = GetGameTime();

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsValidClient(i))
			continue;
			
		float timeSinceDamaged = curTime - g_flLastDamageTime[i];
		if(timeSinceDamaged < sb_player_regenerate_safe_time.FloatValue)
			continue;
			
		int maxHealth = sb_player_maxhealth.IntValue;
		int health = GetClientHealth(i);
		int willRegenerate = maxHealth - health;

		if(willRegenerate < 0) 
			willRegenerate = 0;

		if(willRegenerate > sb_player_regenerate_health_per_second.IntValue) 
			willRegenerate = sb_player_regenerate_health_per_second.IntValue;

		TF2_HealPlayer(i, i, willRegenerate);
	}

	return Plugin_Continue;
}

//---------------------------------------------------------------//
// GAME EVENTS
//---------------------------------------------------------------//

public Action evPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsValidClient(client))
		return Plugin_Continue;

	SB_SetupPlayer(client);

	return Plugin_Continue;
}

public Action evPostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsValidClient(client))
		return Plugin_Continue;

	// Validate that player can wear all weapons.
	SB_ValidatePlayerWeapons(client);
	return Plugin_Continue;
}

//---------------------------------------------------------------//
// DHOOK Callbacks
//---------------------------------------------------------------//

// CTFGameRules::FlPlayerFallDamage(CBasePlayer*)
public MRESReturn CTFGameRules_FlPlayerFallDamage(Handle hParams)
{
	if(!sb_disable_falldamage.BoolValue)
		return MRES_Ignored;
	
	// If we set to disable fall damage, this method should always return 0.
	DHookSetReturn(hParams, 0);
	return MRES_Supercede;
}

// CTFPlayer::TakeHealth(float, int)
public MRESReturn CTFPlayer_TakeHealth(int pThis, Handle hReturn, Handle hParams)
{
	int nFlags = DHookGetParam(hParams, 2);
	if(nFlags & DMG_IGNORE_DEBUFFS)
	{
		PrintToChatAll("Blocked Healing!");
		DHookSetReturn(hReturn, 0);
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

public MRESReturn CTFWeaponBase_PrimaryAttack(int pThis, Handle hReturn, Handle hParams)
{
	PrintToChatAll("%d", pThis);
	CTFWeaponBase_SendWeaponAnim(pThis, 1536);
	return MRES_Ignored;
}
//---------------------------------------------------------------//
// SDK Calls
//---------------------------------------------------------------//

public bool CTFWeaponBase_SendWeaponAnim(int weapon, int anim)
{
	return SDKCall(gCall_CTFWeaponBase_SendWeaponAnim, weapon, anim);
}

//---------------------------------------------------------------//
// SDK Hooks
//---------------------------------------------------------------//

public Action OnClientTakeDamage(int client, int &attacker)
{
	g_flLastDamageTime[client] = GetGameTime();
	return Plugin_Continue;
}

//---------------------------------------------------------------//
// UTIL Functions
//---------------------------------------------------------------//

public bool IsValidClient(int client)
{
	return client >= 1 && client < MaxClients && IsClientInGame(client);
}

public void TF2_SetRandomPlayerClass(int client)
{
	TFClassType pClass = view_as<TFClassType>(GetRandomInt(1, TF_MAX_CLASS_TYPES));
	TF2_SetPlayerClass(client, pClass);
}

public void TF2_HealPlayer(int client, int healer, int amount)
{
	SetEntityHealth(client, GetClientHealth(client) + amount);

	// Send an event
	int userId = GetClientUserId(client);
	int healerId = GetClientUserId(healer);

	Event hEvent = CreateEvent("player_healed", true);
	hEvent.SetBool("sourcemod", true);
	hEvent.SetInt("patient", userId);
	hEvent.SetInt("healer", healerId);
	hEvent.SetInt("amount", amount);
	FireEvent(hEvent);

	hEvent = CreateEvent("player_healonhit", true);
	hEvent.SetBool("sourcemod", true);
	hEvent.SetInt("entindex", client);
	hEvent.SetInt("amount", amount);
	FireEvent(hEvent);
}

public float TF2_GetClassMaxSpeed(TFClassType class)
{
	switch(class)
	{
		case TFClass_Scout:		return 400.0;
		case TFClass_Soldier:	return 240.0;
		case TFClass_Pyro:		return 300.0;
		case TFClass_DemoMan:	return 280.0;
		case TFClass_Heavy:		return 230.0;
		case TFClass_Engineer:	return 300.0;
		case TFClass_Medic:		return 320.0;
		case TFClass_Sniper:	return 300.0;
		case TFClass_Spy:		return 320.0;
		default: 				return 100.0;
	}
}

public int TF2_GetClassMaxHealth(TFClassType class)
{
	switch(class)
	{
		case TFClass_Scout:		return 125;
		case TFClass_Soldier:	return 200;
		case TFClass_Pyro:		return 175;
		case TFClass_DemoMan:	return 175;
		case TFClass_Heavy:		return 300;
		case TFClass_Engineer:	return 125;
		case TFClass_Medic:		return 150;
		case TFClass_Sniper:	return 125;
		case TFClass_Spy:		return 125;
		default: 				return 100;
	}
}