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
#define PLAYER_FREEZE_SOUND "weapons/icicle_freeze_victim_01.wav"

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

enum 
{
	LIFE_ALIVE,
	LIFE_DYING,
	LIFE_DEAD
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
ConVar sb_player_maxspeed;
ConVar sb_player_maxhealth;
ConVar sb_player_regenerate_health_per_second;
ConVar sb_player_regenerate_safe_time;
ConVar sb_projectile_ammo_count;
ConVar sb_projectile_speed;
ConVar sb_projectile_damage;

//---------------------------------------------------------------//
// NATIVE DHOOKS HOOKS
//---------------------------------------------------------------//
Handle gHook_CTFPlayer_TakeHealth;
Handle gHook_CTFWeaponBaseGrenadeProj_InitGrenade;
Handle gHook_CTFStunBall_ApplyBallImpactEffectOnVictim;

//---------------------------------------------------------------//
// GLOBAL DATA
//---------------------------------------------------------------//
float g_flLastDamageTime[MAXPLAYERS + 1];
bool g_bIsFrozen[MAXPLAYERS + 1];
int g_iFrozenParticle[MAXPLAYERS + 1];
Handle g_hUnfreezeTimer[MAXPLAYERS + 1];

public void OnPluginStart()
{
	//
	// ConVars
	//
	sb_respawn_uber_time = 		CreateConVar("sb_respawn_uber_time", 	"3", 	"How much time will players be ubercharged after respawn to prevent spawn camping.");
	sb_player_maxspeed =		CreateConVar("sb_player_maxspeed", 		"300", 	"Speed of all players.");
	sb_player_maxhealth = 		CreateConVar("sb_player_maxhealth",		"300");
	sb_projectile_speed =		CreateConVar("sb_projectile_speed",		"1000");
	sb_projectile_damage =		CreateConVar("sb_projectile_damage",	"100");
	sb_projectile_ammo_count = 	CreateConVar("sb_projectile_ammo_count","5");
	sb_player_regenerate_health_per_second 	= CreateConVar("sb_player_regenerate_health_per_second", "10");
	sb_player_regenerate_safe_time 			= CreateConVar("sb_player_regenerate_safe_time", "5");

	SetupNativeConVars();
	
	//
	// Events
	//
	HookEvent("player_spawn", evPlayerSpawn);
	HookEvent("player_death", evPlayerDeath);
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

	// CTFPlayer::TakeHealth
	int offset = GameConfGetOffset(hGameData, "CTFPlayer::TakeHealth");
	gHook_CTFPlayer_TakeHealth = DHookCreate(offset, HookType_Entity, ReturnType_Int, ThisPointer_CBaseEntity, CTFPlayer_TakeHealth);
	DHookAddParam(gHook_CTFPlayer_TakeHealth, HookParamType_Float);
	DHookAddParam(gHook_CTFPlayer_TakeHealth, HookParamType_Int);

	// CTFWeaponBaseGrenadeProj::InitGrenade
	offset = GameConfGetOffset(hGameData, "CTFWeaponBaseGrenadeProj::InitGrenade");
	gHook_CTFWeaponBaseGrenadeProj_InitGrenade = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, CTFWeaponBaseGrenadeProj_InitGrenade);
	DHookAddParam(gHook_CTFWeaponBaseGrenadeProj_InitGrenade, HookParamType_VectorPtr);
	DHookAddParam(gHook_CTFWeaponBaseGrenadeProj_InitGrenade, HookParamType_VectorPtr);
	DHookAddParam(gHook_CTFWeaponBaseGrenadeProj_InitGrenade, HookParamType_CBaseEntity);
	DHookAddParam(gHook_CTFWeaponBaseGrenadeProj_InitGrenade, HookParamType_Int);
	DHookAddParam(gHook_CTFWeaponBaseGrenadeProj_InitGrenade, HookParamType_Float);

	// CTFStunBall::ApplyBallImpactEffectOnVictim
	offset = GameConfGetOffset(hGameData, "CTFStunBall::ApplyBallImpactEffectOnVictim");
	gHook_CTFStunBall_ApplyBallImpactEffectOnVictim = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, CTFStunBall_ApplyBallImpactEffectOnVictim);
	DHookAddParam(gHook_CTFStunBall_ApplyBallImpactEffectOnVictim, HookParamType_CBaseEntity);

	// Late Hook
	SB_HookAllPlayers();
	CreateTimer(1.0, Timer_RegenerateHealth, _, TIMER_REPEAT);

	AddNormalSoundHook(SB_SoundHook);
}

public void OnMapStart()
{
	char szSound[PLATFORM_MAX_PATH];

	for(int i = 1; i <= 4; i++)
	{
		SB_GetSnowImpactSound(szSound, sizeof(szSound), i);
		PrecacheSound(szSound);
	}

	PrecacheSound(PLAYER_FREEZE_SOUND);
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

public void OnEntityCreated(int entity, const char[] classname)
{
	if(StrEqual(classname, "tf_projectile_jar"))
	{
		DHookEntity(gHook_CTFWeaponBaseGrenadeProj_InitGrenade, true, entity);
		return;
	}
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

public void SB_CreateProjectileFromClient(int client)
{
	static float vecOffset[] = {23.5, 12.0, -3.0};

	int snowball = CreateEntityByName("tf_projectile_stun_ball");
	if(snowball > 0)
	{
		float vecOrigin[3], vecAng[3], vecVel[3];
		float vecFwd[3], vecRight[3], vecUp[3];

		GetClientEyePosition(client, vecOrigin);
		GetClientEyeAngles(client, vecAng);
		GetAngleVectors(vecAng, vecFwd, vecRight, vecUp);

		for(int i = 0; i < 3; i++)
		{
			float vecDir[3];
			switch(i)
			{
				case 0: vecDir = vecFwd;
				case 1: vecDir = vecRight;
				case 2: vecDir = vecUp;
			}

			ScaleVector(vecDir, vecOffset[i]);
			AddVectors(vecOrigin, vecDir, vecOrigin);
		}

		vecVel = vecFwd;
		ScaleVector(vecVel, sb_projectile_speed.FloatValue);

		DispatchSpawn(snowball);
		ActivateEntity(snowball);

		// Setup all the snowball properies
		int teamNum = GetEntProp(client, Prop_Send, "m_iTeamNum");
		
		SetEntProp(snowball, Prop_Send, "m_iTeamNum", teamNum);
		SetEntPropEnt(snowball, Prop_Send, "m_hOwnerEntity", client);

		TeleportEntity(snowball, vecOrigin, vecAng, vecVel);
		DHookEntity(gHook_CTFStunBall_ApplyBallImpactEffectOnVictim, false, snowball);
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
	g_bIsFrozen[client] = false;

	// Set client's class to random one.
	TF2_SetRandomPlayerClass(client);

	// 3 seconds of ubercharge when we respawn
	TF2_AddCondition(client, TFCond_UberchargedCanteen, sb_respawn_uber_time.FloatValue);
	
	SB_RegeneratePlayer(client);
}

public void SB_RegeneratePlayer(int client)
{
	TF2_RegeneratePlayer(client);
	
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
	
	return weapon;
}

public void RF_SB_GiveClientSnowball(any client)
{
	int ammoCount = sb_projectile_ammo_count.IntValue;
	SetEntProp(client, Prop_Send, "m_iAmmo", ammoCount, 4, TF_AMMO_GRENADES1);
	SetEntProp(client, Prop_Send, "m_iAmmo", ammoCount, 4, TF_AMMO_GRENADES2);
	SetEntProp(client, Prop_Send, "m_iAmmo", ammoCount, 4, TF_AMMO_GRENADES3);
}

public Action SB_SoundHook(int clients[64], int &numClients, char sound[PLATFORM_MAX_PATH], int &ent, int &channel, float &volume, int &level, int &pitch, int &flags)
{    
	if (StrContains(sound, "baseball_hitworld") != -1)
	{
		SB_GetSnowImpactSound(sound, PLATFORM_MAX_PATH);
		return Plugin_Changed;
	}

	return Plugin_Continue;
} 

public void SB_SnowballExplode(int snowball)
{
	char szSound[PLATFORM_MAX_PATH];
	SB_GetSnowImpactSound(szSound, sizeof(szSound));

	float vecPos[3];
	GetEntPropVector(snowball, Prop_Send, "m_vecOrigin", vecPos);

	EmitSoundToAll(szSound, _, _, _, _, _, _, _, _, vecPos);

	CreateParticleAtEntity(snowball, "snow_steppuff01");
	AcceptEntityInput(snowball, "Kill");
}

public void SB_FreezePlayer(int player)
{
	if(g_bIsFrozen[player])
		return;

	// Turn them into a freezing statue.
	SetEntityHealth(player, -1);
	SetEntityFlags(player, GetEntityFlags(player) | FL_FROZEN);
	EmitSoundToAll(PLAYER_FREEZE_SOUND, player);
	
	SetVariantInt(1);
	AcceptEntityInput(player, "SetForcedTauntCam");

	g_bIsFrozen[player] = true;
	g_iFrozenParticle[player] = CreateParticleAtEntity(player, "utaunt_snowring_space_parent", -1.0, true);

	g_hUnfreezeTimer[player] = CreateTimer(5.0, Timer_ReviveFreeze, player);
}

stock void SB_UnfreezePlayer(int player, bool deleteTimer = true)
{
	if(!g_bIsFrozen[player])
		return;

	// Turn them into a freezing statue.
	g_bIsFrozen[player] = false;
	SetEntityFlags(player, GetEntityFlags(player) & ~FL_FROZEN);
	
	int frozenParticle = g_iFrozenParticle[player];
	if(frozenParticle > 0) AcceptEntityInput(frozenParticle, "Kill");
	g_iFrozenParticle[player] = -1;
	
	SetVariantInt(0);
	AcceptEntityInput(player, "SetForcedTauntCam");
}

public void SB_RevivePlayer(int player)
{
	if(!g_bIsFrozen[player])
		return;

	SB_UnfreezePlayer(player);
	SetEntityHealth(player, sb_player_maxhealth.IntValue / 2);
}

public Action Timer_ReviveFreeze(Handle hTimer, any player)
{
	if(!g_bIsFrozen[player])
		return Plugin_Continue;

	SB_RevivePlayer(player);
	return Plugin_Continue;
}

public Action Timer_RegenerateHealth(Handle hTimer, any data)
{
	float curTime = GetGameTime();

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsValidClient(i))
			continue;

		if(!IsPlayerAlive(i))
			continue;

		if(g_bIsFrozen[i])
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

stock void SB_GetSnowImpactSound(char[] buffer, int size, int index = -1)
{
	if(index < 0) index = GetRandomInt(1, 4);
	Format(buffer, size, "player/footsteps/snow%d.wav", index);
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

public Action evPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsValidClient(client))
		return Plugin_Continue;

	SB_UnfreezePlayer(client);

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

// CTFPlayer::TakeHealth(float, int)
public MRESReturn CTFPlayer_TakeHealth(int pThis, Handle hReturn, Handle hParams)
{
	int nFlags = DHookGetParam(hParams, 2);
	if(nFlags & DMG_IGNORE_DEBUFFS)
	{
		DHookSetReturn(hReturn, 0);
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

public MRESReturn CTFWeaponBaseGrenadeProj_InitGrenade(int pThis, Handle hReturn, Handle hParams)
{
	// Get the thrower 
	int owner = GetEntPropEnt(pThis, Prop_Send, "m_hThrower");
	if(IsValidClient(owner))
	{
		SB_CreateProjectileFromClient(owner);
	}

	// Immediately yeet us.
	AcceptEntityInput(pThis, "Kill");
	return MRES_Ignored;
}

public MRESReturn CTFStunBall_ApplyBallImpactEffectOnVictim(int pThis, Handle hParams)
{
	int pOther = DHookGetParam(hParams, 1);
	int owner = GetEntPropEnt(pThis, Prop_Send, "m_hOwnerEntity");

	if(IsValidClient(pOther) && IsValidClient(owner))
	{
		if(g_bIsFrozen[pOther])
			return MRES_Supercede;

		float vecThisPos[3], vecOtherPos[3];
		GetEntPropVector(pThis, Prop_Send, "m_vecOrigin", vecThisPos);
		GetEntPropVector(pOther, Prop_Send, "m_vecOrigin", vecOtherPos);

		float flDamage = sb_projectile_damage.FloatValue;
		float curHealth = float(GetClientHealth(pOther));
		bool lethalAttack = false;
		if((curHealth - flDamage) <= 0)
		{
			// We are going to hill them if we damage them right now.
			flDamage = curHealth - 1;
			lethalAttack = true;
		}

		SDKHooks_TakeDamage(pOther, pThis, owner, flDamage, DMG_PARALYZE, _, NULL_VECTOR, vecThisPos);
		SB_SnowballExplode(pThis);

		if(lethalAttack)
		{
			SB_FreezePlayer(pOther);
		}
	}

	return MRES_Supercede;
}

//---------------------------------------------------------------//
// SDK Hooks
//---------------------------------------------------------------//

public Action OnClientTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
	if(g_bIsFrozen[victim])
	{
		damage = 1000.0;
		return Plugin_Changed;
	}

	// Normal means of damage do not hurt us!
	return Plugin_Handled;
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
	if(amount <= 0)
		return;

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

stock int CreateParticleAtEntity(int atEntity, char[] system, float time = 5.0, bool followEntity = false)
{
	float vecPos[3];
	GetEntPropVector(atEntity, Prop_Send, "m_vecOrigin", vecPos);
	int particle = CreateParticleAtPosition(vecPos, system, time);
	
	if(followEntity)
	{
		SetVariantString("!activator");
		AcceptEntityInput(particle, "SetParent", atEntity);
	}

	return particle;
}

stock int CreateParticleAtPosition(float vecPos[3], char[] system, float time = 5.0)
{
	int particle = CreateEntityByName("info_particle_system");

	if (IsValidEdict(particle))
	{
		TeleportEntity(particle, vecPos, NULL_VECTOR, NULL_VECTOR);

		DispatchKeyValue(particle, "effect_name", system);
		DispatchSpawn(particle);
		ActivateEntity(particle);
		AcceptEntityInput(particle, "Start");

		if(time > 0)
		{
			char szAddOutput[64];
			Format(szAddOutput, sizeof(szAddOutput), "OnUser1 !self:kill::%i:1", time);
			SetVariantString(szAddOutput);
		}
    }

	return particle;
}