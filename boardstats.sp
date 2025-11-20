#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#undef REQUIRE_PLUGIN
#include <momsurffix2>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.4.1"

public Plugin myinfo =
{
	name = "boardstats",
	author = "jtooler",
	description = "shows per-board ramp feedback using MomSurfFix2 state and clip data.",
	version = PLUGIN_VERSION,
	url = "https://github.com/followingthefasciaplane/MomSurfFix-API"
};

const float HUD_TIME_MIN = 0.2;
const float HUD_TIME_MAX = 5.0;

const float DEFAULT_PERFECT_MAX_LOSS = 20.0;
const float DEFAULT_OKAY_MAX_LOSS = 50.0;
const float DEFAULT_PERFECT_MIN_ANGLE = 80.0;
const float DEFAULT_OKAY_MIN_ANGLE = 70.0;

enum struct BoardSample
{
	bool hasResult;
	float plane[3];
	float inSpeed;
	float outSpeed;
	float loss;
	float lossPct;
	float normalIntoPlane;
	float angleToPlane;
	float rampAngle;
	float timestamp;
}

enum struct HudPrefs
{
	bool hudEnabled;
	bool showGrade;
	bool showLoss;
	bool showLossPct;
	bool showAngles;
	bool showIntoPlane;
	bool showRampAngle;
	bool showSpeeds;
	bool compact;
	float posX;
	float posY;
	float displayTime;
}

enum struct BoardCategory
{
	char name[64];
	float maxLoss;
	float minAngle;
	float maxLossPct;
	float minSpeed;
	int r;
	int g;
	int b;
}

BoardSample g_Board[MAXPLAYERS + 1];
HudPrefs g_Prefs[MAXPLAYERS + 1];
bool g_LibraryReady;
bool g_BoardLocked[MAXPLAYERS + 1];

#define MAX_BOARD_CATEGORIES 16
BoardCategory g_Categories[MAX_BOARD_CATEGORIES];
int g_CategoryCount;
char g_CategoryConfigPath[PLATFORM_MAX_PATH];

ConVar gCvarEnable;
ConVar gCvarDisplayTime;
ConVar gCvarRampMinZ;
ConVar gCvarRampMaxZ;
ConVar gCvarMinSpeed;
ConVar gCvarHudPosX;
ConVar gCvarHudPosY;
ConVar gCvarDefaultCompact;
ConVar gCvarDefaultLossPct;
ConVar gCvarDefaultIntoPlane;
ConVar gCvarDefaultRampAngle;

Handle g_hHudSync;
Cookie g_hPrefsCookie;

public void OnPluginStart()
{
	gCvarEnable = CreateConVar("sm_boardcoach_enable", "1", "Enable the MomSurfFix2 board coach HUD.");
	gCvarDisplayTime = CreateConVar("sm_boardcoach_display_time", "3.0", "Seconds to keep the board HUD visible.", 0, true, HUD_TIME_MIN, true, HUD_TIME_MAX);
	gCvarRampMinZ = CreateConVar("sm_boardcoach_ramp_min_normal_z", "0.1", "Min plane normal Z to consider a ramp clip (rejects walls).", 0, true, -1.0, true, 1.0);
	gCvarRampMaxZ = CreateConVar("sm_boardcoach_ramp_max_normal_z", "0.75", "Max plane normal Z to consider a ramp clip (rejects floors).", 0, true, -1.0, true, 1.0);
	gCvarMinSpeed = CreateConVar("sm_boardcoach_min_speed", "100.0", "Ignore boards slower than this speed.", 0, true, 0.0, true, 4000.0);
	gCvarHudPosX = CreateConVar("sm_boardcoach_hud_x", "-1.0", "Default HUD X position (0.0-1.0).", 0, true, 0.0, true, 1.0);
	gCvarHudPosY = CreateConVar("sm_boardcoach_hud_y", "-1.0", "Default HUD Y position (0.0-1.0).", 0, true, 0.0, true, 1.0);
	gCvarDefaultCompact = CreateConVar("sm_boardcoach_default_compact", "0", "Use compact HUD layout by default.", 0, true, 0.0, true, 1.0);
	gCvarDefaultLossPct = CreateConVar("sm_boardcoach_default_show_loss_pct", "1", "Show loss percent alongside loss units by default.", 0, true, 0.0, true, 1.0);
	gCvarDefaultIntoPlane = CreateConVar("sm_boardcoach_default_show_into_plane", "1", "Show the into-plane velocity component by default.", 0, true, 0.0, true, 1.0);
	gCvarDefaultRampAngle = CreateConVar("sm_boardcoach_default_show_ramp_angle", "1", "Show ramp angle in the angle line by default.", 0, true, 0.0, true, 1.0);
	AutoExecConfig(true, "mom_boardcoach");

	g_hHudSync = CreateHudSynchronizer();
	g_hPrefsCookie = RegClientCookie("boardcoach_prefs", "BoardCoach HUD preferences", CookieAccess_Private);

	g_LibraryReady = LibraryExists("momsurffix2");
	if (!g_LibraryReady)
	{
		LogMessage("[BoardCoach] Waiting for momsurffix2 library to load.");
	}

	RegConsoleCmd("sm_boardhud", Command_ToggleHud, "Toggle board coach HUD for yourself.");
	RegConsoleCmd("sm_boardstats", Command_OpenMenu, "Open the board coach settings menu.");
	RegConsoleCmd("sm_bst", Command_OpenMenu, "Open the board coach settings menu.");
	RegConsoleCmd("sm_boardhud_pos", Command_SetHudPos, "Set the board HUD position. Usage: sm_boardhud_pos <x> <y>");
	RegConsoleCmd("sm_boardhud_time", Command_SetHudTime, "Set HUD display time in seconds. Usage: sm_boardhud_time <seconds>");
	RegAdminCmd("sm_boardcoach_reload", Command_ReloadConfig, ADMFLAG_CONFIG, "Reload the board coach category config.");

	BuildPath(Path_SM, g_CategoryConfigPath, sizeof(g_CategoryConfigPath), "configs/mom_boardcoach_categories.cfg");
	LoadBoardCategories();

	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClient(i);
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "momsurffix2"))
	{
		g_LibraryReady = true;
		LogMessage("[BoardCoach] momsurffix2 library detected, ramp forwards active.");
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "momsurffix2"))
	{
		g_LibraryReady = false;
		LogMessage("[BoardCoach] momsurffix2 library removed; forwards paused.");
	}
}

public void OnClientPutInServer(int client)
{
	ResetClient(client);
	if (AreClientCookiesCached(client))
		LoadClientPrefs(client);
}

public void OnClientDisconnect(int client)
{
	ResetClient(client);
}

public void OnClientCookiesCached(int client)
{
	LoadClientPrefs(client);
}

void ResetClient(int client)
{
	ResetPrefs(client);
	g_Board[client].hasResult = false;
	g_BoardLocked[client] = false;
}

bool ValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}

void ResetPrefs(int client)
{
	g_Prefs[client].hudEnabled = true;
	g_Prefs[client].showGrade = true;
	g_Prefs[client].showLoss = true;
	g_Prefs[client].showLossPct = gCvarDefaultLossPct.BoolValue;
	g_Prefs[client].showAngles = true;
	g_Prefs[client].showIntoPlane = gCvarDefaultIntoPlane.BoolValue;
	g_Prefs[client].showRampAngle = gCvarDefaultRampAngle.BoolValue;
	g_Prefs[client].showSpeeds = true;
	g_Prefs[client].compact = gCvarDefaultCompact.BoolValue;
	g_Prefs[client].posX = gCvarHudPosX.FloatValue;
	g_Prefs[client].posY = gCvarHudPosY.FloatValue;
	g_Prefs[client].displayTime = ClampFloat(gCvarDisplayTime.FloatValue, HUD_TIME_MIN, HUD_TIME_MAX);
}

void LoadClientPrefs(int client)
{
	ResetPrefs(client);

	if (g_hPrefsCookie == INVALID_HANDLE)
		return;

	char raw[256];
	GetClientCookie(client, g_hPrefsCookie, raw, sizeof(raw));
	if (raw[0] == '\0')
		return;

	char parts[24][16];
	int count = ExplodeString(raw, "|", parts, sizeof(parts), sizeof(parts[]));

	// Legacy format (20 fields) from older builds is still accepted and collapsed onto the new preferences.
	if (count >= 20)
	{
		g_Prefs[client].hudEnabled = StringToInt(parts[0]) != 0;
		g_Prefs[client].showGrade = StringToInt(parts[1]) != 0;
		g_Prefs[client].showLoss = StringToInt(parts[2]) != 0;
		g_Prefs[client].showAngles = StringToInt(parts[3]) != 0;
		g_Prefs[client].showSpeeds = StringToInt(parts[4]) != 0;
		g_Prefs[client].compact = StringToInt(parts[5]) != 0;
		g_Prefs[client].posX = ClampFloat(StringToFloat(parts[7]), 0.0, 1.0);
		g_Prefs[client].posY = ClampFloat(StringToFloat(parts[8]), 0.0, 1.0);

		float scale = ClampFloat(StringToFloat(parts[9]), 0.25, 3.0);
		g_Prefs[client].displayTime = ClampFloat(gCvarDisplayTime.FloatValue * scale, HUD_TIME_MIN, HUD_TIME_MAX);

		g_Prefs[client].showLossPct = StringToInt(parts[13]) != 0;
		g_Prefs[client].showIntoPlane = StringToInt(parts[14]) != 0;
		g_Prefs[client].showRampAngle = StringToInt(parts[15]) != 0;
		return;
	}

	if (count >= 12)
	{
		g_Prefs[client].hudEnabled = StringToInt(parts[0]) != 0;
		g_Prefs[client].showGrade = StringToInt(parts[1]) != 0;
		g_Prefs[client].showLoss = StringToInt(parts[2]) != 0;
		g_Prefs[client].showAngles = StringToInt(parts[3]) != 0;
		g_Prefs[client].showSpeeds = StringToInt(parts[4]) != 0;
		g_Prefs[client].compact = StringToInt(parts[5]) != 0;
		g_Prefs[client].showLossPct = StringToInt(parts[6]) != 0;
		g_Prefs[client].showIntoPlane = StringToInt(parts[7]) != 0;
		g_Prefs[client].showRampAngle = StringToInt(parts[8]) != 0;
		g_Prefs[client].posX = ClampFloat(StringToFloat(parts[9]), 0.0, 1.0);
		g_Prefs[client].posY = ClampFloat(StringToFloat(parts[10]), 0.0, 1.0);
		g_Prefs[client].displayTime = ClampFloat(StringToFloat(parts[11]), HUD_TIME_MIN, HUD_TIME_MAX);
	}
}

void SaveClientPrefs(int client)
{
	if (g_hPrefsCookie == INVALID_HANDLE || !IsClientInGame(client))
		return;

	char buffer[256];
	Format(buffer, sizeof(buffer), "%d|%d|%d|%d|%d|%d|%d|%d|%d|%.3f|%.3f|%.2f",
		g_Prefs[client].hudEnabled,
		g_Prefs[client].showGrade,
		g_Prefs[client].showLoss,
		g_Prefs[client].showAngles,
		g_Prefs[client].showSpeeds,
		g_Prefs[client].compact,
		g_Prefs[client].showLossPct,
		g_Prefs[client].showIntoPlane,
		g_Prefs[client].showRampAngle,
		g_Prefs[client].posX,
		g_Prefs[client].posY,
		g_Prefs[client].displayTime);

	SetClientCookie(client, g_hPrefsCookie, buffer);
}

public Action Command_ToggleHud(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[BoardCoach] Run this command in-game.");
		return Plugin_Handled;
	}

	g_Prefs[client].hudEnabled = !g_Prefs[client].hudEnabled;
	SaveClientPrefs(client);
	PrintToChat(client, "[BoardCoach] Board HUD %s.", g_Prefs[client].hudEnabled ? "enabled" : "disabled");
	return Plugin_Handled;
}

public Action Command_OpenMenu(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[BoardCoach] Run this command in-game.");
		return Plugin_Handled;
	}

	ShowSettingsMenu(client, 0);
	return Plugin_Handled;
}

public Action Command_SetHudPos(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[BoardCoach] Run this command in-game.");
		return Plugin_Handled;
	}

	if (args == 1)
	{
		char arg[32];
		GetCmdArg(1, arg, sizeof(arg));
		if (StrEqual(arg, "reset", false) || StrEqual(arg, "default", false))
		{
			g_Prefs[client].posX = gCvarHudPosX.FloatValue;
			g_Prefs[client].posY = gCvarHudPosY.FloatValue;
			SaveClientPrefs(client);
			PrintToChat(client, "[BoardCoach] HUD position reset to defaults (X %.2f | Y %.2f).", g_Prefs[client].posX, g_Prefs[client].posY);
			return Plugin_Handled;
		}
	}

	if (args < 2)
	{
		ReplyToCommand(client, "[BoardCoach] Usage: sm_boardhud_pos <x 0.0-1.0> <y 0.0-1.0> or sm_boardhud_pos reset");
		return Plugin_Handled;
	}

	char arg[32];
	GetCmdArg(1, arg, sizeof(arg));
	float x = StringToFloat(arg);
	GetCmdArg(2, arg, sizeof(arg));
	float y = StringToFloat(arg);

	g_Prefs[client].posX = ClampFloat(x, 0.0, 1.0);
	g_Prefs[client].posY = ClampFloat(y, 0.0, 1.0);
	SaveClientPrefs(client);

	PrintToChat(client, "[BoardCoach] HUD position set to X %.2f | Y %.2f.", g_Prefs[client].posX, g_Prefs[client].posY);
	return Plugin_Handled;
}

public Action Command_SetHudTime(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[BoardCoach] Run this command in-game.");
		return Plugin_Handled;
	}

	if (args == 1)
	{
		char arg[32];
		GetCmdArg(1, arg, sizeof(arg));
		if (StrEqual(arg, "reset", false) || StrEqual(arg, "default", false))
		{
			g_Prefs[client].displayTime = ClampFloat(gCvarDisplayTime.FloatValue, HUD_TIME_MIN, HUD_TIME_MAX);
			SaveClientPrefs(client);
			PrintToChat(client, "[BoardCoach] HUD display time reset to %.2fs.", g_Prefs[client].displayTime);
			return Plugin_Handled;
		}
	}

	if (args < 1)
	{
		ReplyToCommand(client, "[BoardCoach] Usage: sm_boardhud_time <seconds 0.2-5.0> or sm_boardhud_time reset");
		return Plugin_Handled;
	}

	char arg[32];
	GetCmdArg(1, arg, sizeof(arg));
	float time = ClampFloat(StringToFloat(arg), HUD_TIME_MIN, HUD_TIME_MAX);

	g_Prefs[client].displayTime = time;
	SaveClientPrefs(client);

	PrintToChat(client, "[BoardCoach] HUD display time set to %.2fs.", g_Prefs[client].displayTime);
	return Plugin_Handled;
}

public Action Command_ReloadConfig(int client, int args)
{
	LoadBoardCategories();
	ReplyToCommand(client, "[BoardCoach] Reloaded %d board categories.", g_CategoryCount);
	return Plugin_Handled;
}

void ShowSettingsMenu(int client, int startItem = 0)
{
	Menu menu = new Menu(SettingsMenuHandler);
	menu.SetTitle("Board Coach - HUD & Stats");

	char line[96];
	FormatEx(line, sizeof(line), "HUD: %s", g_Prefs[client].hudEnabled ? "Enabled" : "Disabled");
	menu.AddItem("toggle_hud", line);

	FormatEx(line, sizeof(line), "Layout: %s", g_Prefs[client].compact ? "Compact" : "Detailed");
	menu.AddItem("toggle_compact", line);

	FormatEx(line, sizeof(line), "Grade line: %s", g_Prefs[client].showGrade ? "Shown" : "Hidden");
	menu.AddItem("toggle_grade", line);

	FormatEx(line, sizeof(line), "Loss line: %s", g_Prefs[client].showLoss ? "Shown" : "Hidden");
	menu.AddItem("toggle_loss", line);

	FormatEx(line, sizeof(line), "Loss percent: %s", g_Prefs[client].showLossPct ? "Shown" : "Hidden");
	menu.AddItem("toggle_losspct", line);

	FormatEx(line, sizeof(line), "Angle line: %s", g_Prefs[client].showAngles ? "Shown" : "Hidden");
	menu.AddItem("toggle_angles", line);

	FormatEx(line, sizeof(line), "Into-plane stat: %s", g_Prefs[client].showIntoPlane ? "Shown" : "Hidden");
	menu.AddItem("toggle_into", line);

	FormatEx(line, sizeof(line), "Ramp slope stat: %s", g_Prefs[client].showRampAngle ? "Shown" : "Hidden");
	menu.AddItem("toggle_ramp", line);

	FormatEx(line, sizeof(line), "Speed line: %s", g_Prefs[client].showSpeeds ? "Shown" : "Hidden");
	menu.AddItem("toggle_speeds", line);

	menu.AddItem("prefs_reset", "Reset HUD settings to defaults");

	menu.ExitButton = true;
	menu.DisplayAt(client, startItem, MENU_TIME_FOREVER);
}

public int SettingsMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
		return 0;
	}

	if (action != MenuAction_Select)
		return 0;

	char info[32];
	menu.GetItem(param2, info, sizeof(info));

	if (StrEqual(info, "toggle_hud")) g_Prefs[client].hudEnabled = !g_Prefs[client].hudEnabled;
	else if (StrEqual(info, "toggle_compact")) g_Prefs[client].compact = !g_Prefs[client].compact;
	else if (StrEqual(info, "toggle_grade")) g_Prefs[client].showGrade = !g_Prefs[client].showGrade;
	else if (StrEqual(info, "toggle_loss")) g_Prefs[client].showLoss = !g_Prefs[client].showLoss;
	else if (StrEqual(info, "toggle_losspct")) g_Prefs[client].showLossPct = !g_Prefs[client].showLossPct;
	else if (StrEqual(info, "toggle_angles")) g_Prefs[client].showAngles = !g_Prefs[client].showAngles;
	else if (StrEqual(info, "toggle_into")) g_Prefs[client].showIntoPlane = !g_Prefs[client].showIntoPlane;
	else if (StrEqual(info, "toggle_ramp")) g_Prefs[client].showRampAngle = !g_Prefs[client].showRampAngle;
	else if (StrEqual(info, "toggle_speeds")) g_Prefs[client].showSpeeds = !g_Prefs[client].showSpeeds;
	else if (StrEqual(info, "prefs_reset")) ResetPrefs(client);

	SaveClientPrefs(client);

	if (IsClientInGame(client))
	{
		int itemsPerPage = 6;
		int startPageItem = (param2 / itemsPerPage) * itemsPerPage;
		ShowSettingsMenu(client, startPageItem);
	}

	return 0;
}

public void MomSurfFix_OnClipVelocity(int client, const float inVel[3], const float planeNormal[3], const float outVel[3], float overbounce)
{
	if (!gCvarEnable.BoolValue || !ValidClient(client) || !g_LibraryReady)
		return;

	if (g_BoardLocked[client]) return;

	float maxZ = ClampFloat(gCvarRampMaxZ.FloatValue, 0.0, 1.0);
	float minZ = ClampFloat(gCvarRampMinZ.FloatValue, 0.0, 1.0);

	if (minZ > maxZ)
	{
		float swap = minZ;
		minZ = maxZ;
		maxZ = swap;
	}

	float normalZ = FloatAbs(planeNormal[2]);
	if (normalZ > maxZ || normalZ < minZ) return;

	float nPlane[3];
	NormalizeSafe(planeNormal, nPlane);

	float inSpeed = GetVectorLength(inVel);
	if (inSpeed < gCvarMinSpeed.FloatValue) return;

	float outSpeed = GetVectorLength(outVel);
	float loss = inSpeed - outSpeed;
	if (loss < 0.0) loss = 0.0;
	float lossPct = (inSpeed > 0.0) ? loss / inSpeed : 0.0;

	if (loss < 1.0 && GetVectorDistance(inVel, outVel) < 20.0) return;

	float nVel[3];
	NormalizeSafe(inVel, nVel);

	float dot = GetVectorDotProduct(nVel, nPlane);
	float normalIntoPlane = FloatAbs(dot) * inSpeed;
	float angleToPlane = RadToDeg(ArcCosine(ClampFloat(FloatAbs(dot), -1.0, 1.0)));
	float rampAngle = RadToDeg(ArcCosine(ClampFloat(nPlane[2], -1.0, 1.0)));

	BoardSample sample;
	sample.hasResult = true;
	CopyVector(planeNormal, sample.plane);
	sample.inSpeed = inSpeed;
	sample.outSpeed = outSpeed;
	sample.loss = loss;
	sample.lossPct = lossPct;
	sample.normalIntoPlane = normalIntoPlane;
	sample.angleToPlane = angleToPlane;
	sample.rampAngle = rampAngle;
	sample.timestamp = GetGameTime();
	g_Board[client] = sample;

	g_BoardLocked[client] = true;
}

public void MomSurfFix_OnTryPlayerMovePost(int client, int blockedMask, int lastIteration, int maxIterations,
	const float finalVelocity[3], const float finalOrigin[3], bool stuckOnRamp, bool hasValidPlane, const float finalPlane[3], float totalFraction)
{
	if (!gCvarEnable.BoolValue || !ValidClient(client) || !g_LibraryReady) return;

	if (!g_BoardLocked[client]) return;

	if (!RampBelowPlayer(client))
		g_BoardLocked[client] = false;
}

public void OnGameFrame()
{
	if (!gCvarEnable.BoolValue || g_hHudSync == INVALID_HANDLE || !g_LibraryReady)
		return;

	float now = GetGameTime();

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!ValidClient(client) || !g_Prefs[client].hudEnabled)
			continue;

		if (!g_Board[client].hasResult)
			continue;

		float displayTime = ClampFloat(g_Prefs[client].displayTime, HUD_TIME_MIN, HUD_TIME_MAX);
		float age = now - g_Board[client].timestamp;
		if (age > displayTime)
			continue;

		char grade[64];
		int gradeR, gradeG, gradeB;
		GetBoardGrade(g_Board[client], grade, sizeof(grade), gradeR, gradeG, gradeB);

		int finalR = ClampInt(gradeR, 0, 255);
		int finalG = ClampInt(gradeG, 0, 255);
		int finalB = ClampInt(gradeB, 0, 255);

		int hudColor[4];
		hudColor[0] = finalR;
		hudColor[1] = finalG;
		hudColor[2] = finalB;
		hudColor[3] = 255;

		char hud[256];
		BuildHudString(g_Board[client], g_Prefs[client], grade, hud, sizeof(hud));

		float remain = displayTime - age;
		if (remain < 0.1) remain = 0.1;

		// Use the category color for both HUD channels to avoid flickering or mismatched hues.
		SetHudTextParamsEx(g_Prefs[client].posX, g_Prefs[client].posY, remain, hudColor, hudColor, 0, 0.0, 0.0, 0.0);
		ShowSyncHudText(client, g_hHudSync, hud);
	}
}

void GetBoardGrade(const BoardSample sample, char[] buffer, int maxlen, int &r, int &g, int &b)
{
	if (g_CategoryCount == 0) AddDefaultCategories();

	int found = -1;
	for (int i = 0; i < g_CategoryCount; i++)
	{
		bool withinLoss = (sample.loss <= g_Categories[i].maxLoss);
		bool withinAngle = (sample.angleToPlane >= g_Categories[i].minAngle);
		bool withinLossPct = (sample.lossPct <= g_Categories[i].maxLossPct);
		bool withinSpeed = (sample.inSpeed >= g_Categories[i].minSpeed);

		if (withinLoss && withinAngle && withinLossPct && withinSpeed)
		{
			found = i;
			break;
		}
	}

	if (found == -1 && g_CategoryCount > 0)
		found = g_CategoryCount - 1;

	if (found == -1)
	{
		r = 255; g = 64; b = 64;
		Format(buffer, maxlen, "Board");
		return;
	}

	BoardCategory cat;
	cat = g_Categories[found];
	r = cat.r;
	g = cat.g;
	b = cat.b;
	Format(buffer, maxlen, "%s", cat.name);
}

void AppendHudLine(char[] buffer, int maxlen, const char[] line)
{
	if (buffer[0] != '\0')
		StrCat(buffer, maxlen, "\n");
	StrCat(buffer, maxlen, line);
}

void BuildHudString(const BoardSample sample, const HudPrefs prefs, const char[] grade, char[] buffer, int maxlen)
{
	buffer[0] = '\0';

	if (prefs.compact)
	{
		char line[192];
		FormatEx(line, sizeof(line), "%s", prefs.showGrade ? grade : "Board HUD");

		if (prefs.showLoss)
		{
			char temp[64];
			if (prefs.showLossPct)
				FormatEx(temp, sizeof(temp), " | Loss %.1f (%.1f%%)", sample.loss, sample.lossPct * 100.0);
			else
				FormatEx(temp, sizeof(temp), " | Loss %.1f", sample.loss);
			StrCat(line, sizeof(line), temp);
		}

		if (prefs.showAngles)
		{
			char temp[64];
			FormatEx(temp, sizeof(temp), " | Angle %.1f", sample.angleToPlane);

			if (prefs.showRampAngle)
			{
				char extra[32];
				FormatEx(extra, sizeof(extra), " | Ramp %.1f", sample.rampAngle);
				StrCat(temp, sizeof(temp), extra);
			}

			if (prefs.showIntoPlane)
			{
				char extra[32];
				FormatEx(extra, sizeof(extra), " | Into %.1f", sample.normalIntoPlane);
				StrCat(temp, sizeof(temp), extra);
			}
			StrCat(line, sizeof(line), temp);
		}

		if (prefs.showSpeeds)
		{
			char temp[64];
			FormatEx(temp, sizeof(temp), " | Speed %.1f->%.1f", sample.inSpeed, sample.outSpeed);
			StrCat(line, sizeof(line), temp);
		}

		if (!prefs.showLoss && !prefs.showAngles && !prefs.showSpeeds && !prefs.showGrade)
			StrCat(line, sizeof(line), " | (no fields selected)");

		FormatEx(buffer, maxlen, "%s", line);
		return;
	}

	if (prefs.showGrade)
		AppendHudLine(buffer, maxlen, grade);

	if (prefs.showLoss)
	{
		char line[96];
		if (prefs.showLossPct)
			FormatEx(line, sizeof(line), "Loss: %.1f u/s (%.1f%%)", sample.loss, sample.lossPct * 100.0);
		else
			FormatEx(line, sizeof(line), "Loss: %.1f u/s", sample.loss);
		AppendHudLine(buffer, maxlen, line);
	}

	if (prefs.showAngles)
	{
		char line[128];
		line[0] = '\0';

		if (prefs.showIntoPlane)
		{
			char temp[48];
			FormatEx(temp, sizeof(temp), "Into plane: %.1f u/s", sample.normalIntoPlane);
			StrCat(line, sizeof(line), temp);
		}

		{
			char temp[48];
			if (line[0] != '\0') StrCat(line, sizeof(line), " | ");
			FormatEx(temp, sizeof(temp), "Angle: %.1f deg", sample.angleToPlane);
			StrCat(line, sizeof(line), temp);
		}

		if (prefs.showRampAngle)
		{
			char temp[48];
			if (line[0] != '\0') StrCat(line, sizeof(line), " | ");
			FormatEx(temp, sizeof(temp), "Ramp: %.1f deg", sample.rampAngle);
			StrCat(line, sizeof(line), temp);
		}
		
		if (line[0] == '\0')
			FormatEx(line, sizeof(line), "Angle: %.1f deg", sample.angleToPlane);

		AppendHudLine(buffer, maxlen, line);
	}

	if (prefs.showSpeeds)
	{
		char line[96];
		FormatEx(line, sizeof(line), "In: %.1f -> Out: %.1f u/s", sample.inSpeed, sample.outSpeed);
		AppendHudLine(buffer, maxlen, line);
	}

	if (buffer[0] == '\0')
		FormatEx(buffer, maxlen, "Board HUD (no fields selected)");
}

bool AddCategory(const char[] name, float maxLoss, float minAngle, float maxLossPct, float minSpeed, int r, int g, int b)
{
	if (g_CategoryCount >= MAX_BOARD_CATEGORIES)
		return false;

	BoardCategory cat;
	strcopy(cat.name, sizeof(cat.name), name);
	cat.maxLoss = (maxLoss < 0.0) ? 0.0 : maxLoss;
	cat.minAngle = minAngle;
	cat.maxLossPct = (maxLossPct < 0.0) ? 0.0 : maxLossPct;
	cat.minSpeed = ClampFloat(minSpeed, 0.0, 20000.0);
	cat.r = ClampInt(r, 0, 255);
	cat.g = ClampInt(g, 0, 255);
	cat.b = ClampInt(b, 0, 255);

	g_Categories[g_CategoryCount] = cat;
	g_CategoryCount++;
	return true;
}

void AddDefaultCategories()
{
	g_CategoryCount = 0;
	AddCategory("Perfect board", DEFAULT_PERFECT_MAX_LOSS, DEFAULT_PERFECT_MIN_ANGLE, 99999.0, 0.0, 80, 255, 120);
	AddCategory("Okay board", DEFAULT_OKAY_MAX_LOSS, DEFAULT_OKAY_MIN_ANGLE, 99999.0, 0.0, 255, 210, 64);
	AddCategory("Scuffed board", 99999.0, -180.0, 99999.0, 0.0, 255, 64, 64);
}

void ParseColorString(const char[] input, int &r, int &g, int &b)
{
	char clean[64];
	strcopy(clean, sizeof(clean), input);
	ReplaceString(clean, sizeof(clean), ",", " ");
	
	while (ReplaceString(clean, sizeof(clean), "  ", " ") > 0) {}
	
	char parts[3][8];
	int count = ExplodeString(clean, " ", parts, sizeof(parts), sizeof(parts[]));
	
	if (count >= 3)
	{
		r = ClampInt(StringToInt(parts[0]), 0, 255);
		g = ClampInt(StringToInt(parts[1]), 0, 255);
		b = ClampInt(StringToInt(parts[2]), 0, 255);
	}
}

void WriteDefaultCategoryConfig()
{
	File file = OpenFile(g_CategoryConfigPath, "w");
	if (file == null)
	{
		LogError("[BoardCoach] Failed to create %s", g_CategoryConfigPath);
		return;
	}

	file.WriteLine("\"Categories\"");
	file.WriteLine("{");
	file.WriteLine("\t\"Perfect\"");
	file.WriteLine("\t{");
	file.WriteLine("\t\t\"max_loss\" \"%.1f\"", DEFAULT_PERFECT_MAX_LOSS);
	file.WriteLine("\t\t\"min_angle\" \"%.1f\"", DEFAULT_PERFECT_MIN_ANGLE);
	file.WriteLine("\t\t\"color\" \"80 255 120\"");
	file.WriteLine("\t}");
	file.WriteLine("\t\"Okay\"");
	file.WriteLine("\t{");
	file.WriteLine("\t\t\"max_loss\" \"%.1f\"", DEFAULT_OKAY_MAX_LOSS);
	file.WriteLine("\t\t\"min_angle\" \"%.1f\"", DEFAULT_OKAY_MIN_ANGLE);
	file.WriteLine("\t\t\"color\" \"255 210 64\"");
	file.WriteLine("\t}");
	file.WriteLine("\t\"Scuffed\"");
	file.WriteLine("\t{");
	file.WriteLine("\t\t\"max_loss\" \"99999\"");
	file.WriteLine("\t\t\"min_angle\" \"-180.0\"");
	file.WriteLine("\t\t\"color\" \"255 64 64\"");
	file.WriteLine("\t}");
	file.WriteLine("}");
	delete file;
}

void LoadBoardCategories()
{
	g_CategoryCount = 0;

	if (!FileExists(g_CategoryConfigPath))
		WriteDefaultCategoryConfig();

	KeyValues kv = new KeyValues("Categories");
	if (kv == null)
	{
		AddDefaultCategories();
		return;
	}

	if (!kv.ImportFromFile(g_CategoryConfigPath))
	{
		LogError("[BoardCoach] Could not read %s; using default categories.", g_CategoryConfigPath);
		delete kv;
		AddDefaultCategories();
		return;
	}

	if (kv.GotoFirstSubKey(false))
	{
		do
		{
			char section[64];
			kv.GetSectionName(section, sizeof(section));

			char name[64];
			kv.GetString("label", name, sizeof(name), section);

			float maxLoss = kv.GetFloat("max_loss", 99999.0);
			float minAngle = kv.GetFloat("min_angle", -180.0);
			float maxLossPct = kv.GetFloat("max_loss_pct", 99999.0);
			float minSpeed = kv.GetFloat("min_speed", 0.0);

			if (maxLossPct > 1.0)
				maxLossPct = maxLossPct / 100.0;

			int r = 255, g = 64, b = 64;
			char colorStr[32];
			kv.GetString("color", colorStr, sizeof(colorStr), "255 64 64");
			ParseColorString(colorStr, r, g, b);

			if (!AddCategory(name, maxLoss, minAngle, maxLossPct, minSpeed, r, g, b))
			{
				LogError("[BoardCoach] Category limit reached (%d); ignoring \"%s\".", MAX_BOARD_CATEGORIES, name);
				break;
			}
		}
		while (kv.GotoNextKey(false));
	}

	delete kv;

	if (g_CategoryCount == 0)
	{
		AddDefaultCategories();
	}
	else
	{
		LogMessage("[BoardCoach] Loaded %d board categories.", g_CategoryCount);
	}
}

void CopyVector(const float src[3], float dest[3])
{
	dest[0] = src[0]; dest[1] = src[1]; dest[2] = src[2];
}

void NormalizeSafe(const float input[3], float output[3])
{
	float length = SquareRoot(input[0] * input[0] + input[1] * input[1] + input[2] * input[2]);
	if (length > 0.0001)
	{
		output[0] = input[0] / length;
		output[1] = input[1] / length;
		output[2] = input[2] / length;
	}
	else
	{
		output[0] = 0.0; output[1] = 0.0; output[2] = 0.0;
	}
}

float ClampFloat(float value, float min, float max)
{
	if (value < min) return min;
	if (value > max) return max;
	return value;
}

int ClampInt(int value, int min, int max)
{
	if (value < min) return min;
	if (value > max) return max;
	return value;
}

bool RampBelowPlayer(int client)
{
	float mins[3], maxs[3];
	GetClientMins(client, mins);
	GetClientMaxs(client, maxs);

	float start[3], end[3];
	GetClientAbsOrigin(client, start);
	end[0] = start[0];
	end[1] = start[1];
	end[2] = start[2] - 256.0;

	Handle trace = TR_TraceHullFilterEx(start, end, mins, maxs, MASK_PLAYERSOLID, TraceIgnorePlayers, client);
	bool rampBelow = false;

	if (TR_DidHit(trace))
	{
		float normal[3];
		TR_GetPlaneNormal(trace, normal);
		if (FloatAbs(normal[2]) < 0.7)
			rampBelow = true;
	}

	CloseHandle(trace);
	return rampBelow;
}

public bool TraceIgnorePlayers(int entity, int contentsMask, any data)
{
	#pragma unused contentsMask
	int client = data;
	return (entity != client && (entity == 0 || entity > MaxClients));
}
