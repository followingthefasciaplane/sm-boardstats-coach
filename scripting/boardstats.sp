#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#undef REQUIRE_PLUGIN
#include <momsurffix2>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.5.0"

public Plugin myinfo =
{
    name = "Board Stats",
    author = "jtooler",
    description = "Surf ramp boarding trainer. Provides a HUD that shows detailed information about your boards.",
    version = PLUGIN_VERSION,
    url = "https://github.com/followingthefasciaplane/MomSurfFix-API"
};

// constants
const float HUD_TIME_MIN = 0.2;
const float HUD_TIME_MAX = 5.0;

// board detection
const float DEFAULT_MIN_INTO_PLANE = 25.0;    // minimum velocity into plane to count as board
const float DEFAULT_BOARD_COOLDOWN = 0.25;    // seconds between board detections
const float DEFAULT_MIN_SPEED = 100.0;        // ignore boards below this speed
const float BASE_SPEED_REFERENCE = 1500.0;     // reference speed for threshold scaling
const int CLIP_GAP_TICKS = 100;                // ticks without clip callbacks required to allow next board. TODO, better version of ramp detection

// ramp normal Z bounds
const float DEFAULT_RAMP_MIN_Z = 0.1;
const float DEFAULT_RAMP_MAX_Z = 0.7;

// enums
enum BoardGrade
{
    Grade_Perfect = 0,
    Grade_Good,
    Grade_Okay,
    Grade_Bad,
    Grade_Terrible,
    Grade_COUNT
}

// structs
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
    BoardGrade grade;
}

enum struct HudPrefs
{
    bool hudEnabled;
    bool showGrade;
    bool showLossUnits;
    bool showLossPct;
    bool showAngle;
    bool showIntoPlane;
    bool showRampAngle;
    bool showSpeeds;
    bool compactMode;
    float posX;
    float posY;
    float displayTime;
}

enum struct GradeThresholds
{
    float baseLossPct;
    float minAngle;
    char name[32];
    int r;
    int g;
    int b;
}

// globals
BoardSample g_BoardData[MAXPLAYERS + 1];
HudPrefs g_Prefs[MAXPLAYERS + 1];
float g_LastBoardTime[MAXPLAYERS + 1];
int g_LastClipTick[MAXPLAYERS + 1];
bool g_WasOnRamp[MAXPLAYERS + 1];
bool g_IsSurfingRamp[MAXPLAYERS + 1];
bool g_LibraryReady;

GradeThresholds g_Grades[Grade_COUNT];
char g_ConfigPath[PLATFORM_MAX_PATH];

// cvars
ConVar g_cvEnable;
ConVar g_cvDisplayTime;
ConVar g_cvRampMinZ;
ConVar g_cvRampMaxZ;
ConVar g_cvMinSpeed;
ConVar g_cvMinIntoPlane;
ConVar g_cvBoardCooldown;
ConVar g_cvHudPosX;
ConVar g_cvHudPosY;
ConVar g_cvDebug;

Handle g_hHudSync;
Cookie g_hPrefsCookie;

public void OnPluginStart()
{
    // cvars
    g_cvEnable = CreateConVar("sm_boardstats_enable", "1", "Enable board stats HUD.");
    g_cvDisplayTime = CreateConVar("sm_boardstats_display_time", "5.0", "Default HUD display duration.", 0, true, HUD_TIME_MIN, true, HUD_TIME_MAX);
    g_cvRampMinZ = CreateConVar("sm_boardstats_ramp_min_z", "0.1", "Min plane normal Z for ramps (rejects walls).", 0, true, 0.0, true, 1.0);
    g_cvRampMaxZ = CreateConVar("sm_boardstats_ramp_max_z", "0.7", "Max plane normal Z for ramps (rejects floors).", 0, true, 0.0, true, 1.0);
    g_cvMinSpeed = CreateConVar("sm_boardstats_min_speed", "100.0", "Minimum speed to register a board.", 0, true, 0.0, true, 4000.0);
    g_cvMinIntoPlane = CreateConVar("sm_boardstats_min_into_plane", "25.0", "Minimum velocity into plane to count as board (filters continuous surfing).", 0, true, 5.0, true, 200.0);
    g_cvBoardCooldown = CreateConVar("sm_boardstats_cooldown", "0.25", "Cooldown between board detections per player.", 0, true, 0.05, true, 2.0);
    g_cvHudPosX = CreateConVar("sm_boardstats_hud_x", "-1.0", "Default HUD X position.", 0, true, -1.0, true, 1.0);
    g_cvHudPosY = CreateConVar("sm_boardstats_hud_y", "0.35", "Default HUD Y position.", 0, true, -1.0, true, 1.0);
    g_cvDebug = CreateConVar("sm_boardstats_debug", "0", "Enable debug output to chat.", 0, true, 0.0, true, 1.0);
    
    AutoExecConfig(true, "boardstats");

    // HUD synchronizer
    g_hHudSync = CreateHudSynchronizer();
    
    // client cookies
    g_hPrefsCookie = RegClientCookie("boardstats_prefs_v2", "Board Stats HUD preferences", CookieAccess_Private);

    // commands
    RegConsoleCmd("sm_boardstats", Cmd_MainMenu, "Open board stats settings menu.");
    RegConsoleCmd("sm_bst", Cmd_MainMenu, "Open board stats settings menu.");
    RegConsoleCmd("sm_boardhud", Cmd_ToggleHud, "Toggle board stats HUD.");
    RegConsoleCmd("sm_boardhud_pos", Cmd_SetPosition, "Set HUD position. Usage: sm_boardhud_pos <x> <y>");
    RegAdminCmd("sm_boardstats_reload", Cmd_ReloadConfig, ADMFLAG_CONFIG, "Reload board stats configuration.");

    // lib check
    g_LibraryReady = LibraryExists("momsurffix2");
    if (!g_LibraryReady)
    {
        LogMessage("[BoardStats] Waiting for momsurffix2 library.");
    }

    // categories config
    BuildPath(Path_SM, g_ConfigPath, sizeof(g_ConfigPath), "configs/boardstats.cfg");
    LoadConfiguration();

    // init clients
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientData(i);
    }
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "momsurffix2"))
    {
        g_LibraryReady = true;
        LogMessage("[BoardStats] momsurffix2 library loaded.");
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "momsurffix2"))
    {
        g_LibraryReady = false;
        LogMessage("[BoardStats] momsurffix2 library unloaded.");
    }
}

public void OnClientPutInServer(int client)
{
    ResetClientData(client);
    if (AreClientCookiesCached(client))
    {
        LoadClientPrefs(client);
    }
}

public void OnClientDisconnect(int client)
{
    ResetClientData(client);
}

public void OnClientCookiesCached(int client)
{
    LoadClientPrefs(client);
}

void ResetClientData(int client)
{
    g_BoardData[client].hasResult = false;
    g_LastBoardTime[client] = 0.0;
    g_LastClipTick[client] = 0;
    g_WasOnRamp[client] = false;
    g_IsSurfingRamp[client] = false;
    InitializeDefaultPrefs(client);
}

void InitializeDefaultPrefs(int client)
{
    g_Prefs[client].hudEnabled = true;
    g_Prefs[client].showGrade = true;
    g_Prefs[client].showLossUnits = true;     // default: show loss units only
    g_Prefs[client].showLossPct = false;      // off by default
    g_Prefs[client].showAngle = false;        // off by default
    g_Prefs[client].showIntoPlane = false;    // off by default
    g_Prefs[client].showRampAngle = false;    // off by default
    g_Prefs[client].showSpeeds = false;       // off by default
    g_Prefs[client].compactMode = false;
    g_Prefs[client].posX = g_cvHudPosX.FloatValue;
    g_Prefs[client].posY = g_cvHudPosY.FloatValue;
    g_Prefs[client].displayTime = g_cvDisplayTime.FloatValue;
}

// config
void LoadConfiguration()
{
    SetDefaultGrades();

    if (!FileExists(g_ConfigPath))
    {
        WriteDefaultConfig();
    }

    KeyValues kv = new KeyValues("BoardStats");
    if (kv == null || !kv.ImportFromFile(g_ConfigPath))
    {
        LogError("[BoardStats] Failed to load config from %s, using defaults.", g_ConfigPath);
        delete kv;
        return;
    }

    // load grade thresholds
    if (kv.JumpToKey("Grades"))
    {
        if (kv.GotoFirstSubKey())
        {
            do
            {
                char section[32];
                kv.GetSectionName(section, sizeof(section));

                BoardGrade grade = GetGradeFromName(section);
                if (grade == Grade_COUNT) continue;

                float lossPctConfig = kv.GetFloat("loss_pct", g_Grades[grade].baseLossPct * 100.0);
                g_Grades[grade].baseLossPct = lossPctConfig / 100.0;
                g_Grades[grade].minAngle = kv.GetFloat("min_angle", g_Grades[grade].minAngle);
                kv.GetString("name", g_Grades[grade].name, sizeof(g_Grades[].name), g_Grades[grade].name);
                
                char colorStr[32];
                kv.GetString("color", colorStr, sizeof(colorStr), "");
                if (colorStr[0] != '\0')
                {
                    ParseColorString(colorStr, g_Grades[grade].r, g_Grades[grade].g, g_Grades[grade].b);
                }
            }
            while (kv.GotoNextKey());
            kv.GoBack();
        }
        kv.GoBack();
    }

    delete kv;
    LogMessage("[BoardStats] Configuration loaded.");
}

void SetDefaultGrades()
{
    // Perfect - Blue (loss < 0.5%, angle >= 85)
    g_Grades[Grade_Perfect].baseLossPct = 0.005;
    g_Grades[Grade_Perfect].minAngle = 85.0;
    strcopy(g_Grades[Grade_Perfect].name, sizeof(g_Grades[].name), "Perfect");
    g_Grades[Grade_Perfect].r = 64;
    g_Grades[Grade_Perfect].g = 180;
    g_Grades[Grade_Perfect].b = 255;

    // Good - Green (loss < 1.5%, angle >= 80)
    g_Grades[Grade_Good].baseLossPct = 0.015;
    g_Grades[Grade_Good].minAngle = 80.0;
    strcopy(g_Grades[Grade_Good].name, sizeof(g_Grades[].name), "Good");
    g_Grades[Grade_Good].r = 64;
    g_Grades[Grade_Good].g = 255;
    g_Grades[Grade_Good].b = 96;

    // Okay - White (loss < 3%, angle >= 75)
    g_Grades[Grade_Okay].baseLossPct = 0.03;
    g_Grades[Grade_Okay].minAngle = 75.0;
    strcopy(g_Grades[Grade_Okay].name, sizeof(g_Grades[].name), "Okay");
    g_Grades[Grade_Okay].r = 255;
    g_Grades[Grade_Okay].g = 255;
    g_Grades[Grade_Okay].b = 255;

    // Bad - Yellow (loss < 5%, angle >= 60)
    g_Grades[Grade_Bad].baseLossPct = 0.05;
    g_Grades[Grade_Bad].minAngle = 60.0;
    strcopy(g_Grades[Grade_Bad].name, sizeof(g_Grades[].name), "Bad");
    g_Grades[Grade_Bad].r = 255;
    g_Grades[Grade_Bad].g = 200;
    g_Grades[Grade_Bad].b = 32;

    // Terrible - Red (everything else)
    g_Grades[Grade_Terrible].baseLossPct = 1.0;  // 100%
    g_Grades[Grade_Terrible].minAngle = 0.0;
    strcopy(g_Grades[Grade_Terrible].name, sizeof(g_Grades[].name), "Terrible");
    g_Grades[Grade_Terrible].r = 255;
    g_Grades[Grade_Terrible].g = 64;
    g_Grades[Grade_Terrible].b = 64;
}

BoardGrade GetGradeFromName(const char[] name)
{
    if (StrContains(name, "Perfect", false) != -1) return Grade_Perfect;
    if (StrContains(name, "Good", false) != -1) return Grade_Good;
    if (StrContains(name, "Okay", false) != -1) return Grade_Okay;
    if (StrContains(name, "Bad", false) != -1) return Grade_Bad;
    if (StrContains(name, "Terrible", false) != -1) return Grade_Terrible;
    return Grade_COUNT;
}

void WriteDefaultConfig()
{
    File file = OpenFile(g_ConfigPath, "w");
    if (file == null)
    {
        LogError("[BoardStats] Failed to create config file: %s", g_ConfigPath);
        return;
    }

    file.WriteLine("// Board Stats Configuration");
    file.WriteLine("// Loss percentages are scaled based on player speed - higher speeds allow more loss");
    file.WriteLine("// Angles: Higher = better (90 means velocity parallel to ramp surface)");
    file.WriteLine("//");
    file.WriteLine("\"BoardStats\"");
    file.WriteLine("{");
    file.WriteLine("    // Grade thresholds - evaluated in order (Perfect first)");
    file.WriteLine("    // A board qualifies for a grade if it meets BOTH the loss% AND angle threshold");
    file.WriteLine("    \"Grades\"");
    file.WriteLine("    {");
    file.WriteLine("        \"Perfect\"");
    file.WriteLine("        {");
    file.WriteLine("            \"name\"      \"Perfect\"");
    file.WriteLine("            \"loss_pct\"  \"0.5\"      // Base loss%% threshold (scales with speed)");
    file.WriteLine("            \"min_angle\" \"85.0\"     // Minimum approach angle (90 = parallel to surface)");
    file.WriteLine("            \"color\"     \"64 180 255\"  // Blue");
    file.WriteLine("        }");
    file.WriteLine("        \"Good\"");
    file.WriteLine("        {");
    file.WriteLine("            \"name\"      \"Good\"");
    file.WriteLine("            \"loss_pct\"  \"1.5\"");
    file.WriteLine("            \"min_angle\" \"80.0\"");
    file.WriteLine("            \"color\"     \"64 255 96\"   // Green");
    file.WriteLine("        }");
    file.WriteLine("        \"Okay\"");
    file.WriteLine("        {");
    file.WriteLine("            \"name\"      \"Okay\"");
    file.WriteLine("            \"loss_pct\"  \"3.0\"");
    file.WriteLine("            \"min_angle\" \"75.0\"");
    file.WriteLine("            \"color\"     \"255 255 255\" // White");
    file.WriteLine("        }");
    file.WriteLine("        \"Bad\"");
    file.WriteLine("        {");
    file.WriteLine("            \"name\"      \"Bad\"");
    file.WriteLine("            \"loss_pct\"  \"5.0\"");
    file.WriteLine("            \"min_angle\" \"60.0\"");
    file.WriteLine("            \"color\"     \"255 200 32\"  // Yellow");
    file.WriteLine("        }");
    file.WriteLine("        \"Terrible\"");
    file.WriteLine("        {");
    file.WriteLine("            \"name\"      \"Terrible\"");
    file.WriteLine("            \"loss_pct\"  \"100.0\"");
    file.WriteLine("            \"min_angle\" \"0.0\"");
    file.WriteLine("            \"color\"     \"255 64 64\"   // Red");
    file.WriteLine("        }");
    file.WriteLine("    }");
    file.WriteLine("}");
    
    delete file;
    LogMessage("[BoardStats] Created default config: %s", g_ConfigPath);
}

// see momsurffix2.inc
public void MomSurfFix_OnClipVelocity(int client, int tickCount, int callSerial, MomSurfFixStepPhase stepPhase, 
    const float inVel[3], const float planeNormal[3], const float outVel[3], float overbounce)
{
    #pragma unused callSerial, stepPhase, overbounce

    if (!g_cvEnable.BoolValue || !g_LibraryReady || !IsValidClient(client))
        return;

    // if we have been without clip callbacks for a while, unlock the detector
    int lastTick = g_LastClipTick[client];
    int tickGap = (lastTick == 0) ? (CLIP_GAP_TICKS + 1) : (tickCount - lastTick);
    if (tickGap > CLIP_GAP_TICKS)
    {
        g_IsSurfingRamp[client] = false;
    }

    // always record the most recent clip tick for gap tracking
    g_LastClipTick[client] = tickCount;

    // only record the very first clip on a ramp; ignore subsequent clips until we leave it
    if (g_IsSurfingRamp[client])
        return;

    // check ramp normal bounds
    float normalZ = FloatAbsD(planeNormal[2]);
    float minZ = g_cvRampMinZ.FloatValue;
    float maxZ = g_cvRampMaxZ.FloatValue;
    
    if (normalZ < minZ || normalZ > maxZ)
        return;

    // calculate basic metrics
    float inSpeed = GetVectorLength(inVel);
    if (inSpeed < g_cvMinSpeed.FloatValue)
        return;

    float outSpeed = GetVectorLength(outVel);
    float loss = inSpeed - outSpeed;
    if (loss < 0.0) loss = 0.0;

    // normalize vectors for angle calculations
    float nVel[3], nPlane[3];
    NormalizeVectorD(inVel, nVel);
    NormalizeVectorD(planeNormal, nPlane);

    // calculate velocity component going INTO the plane
    float dot = GetVectorDotProduct(nVel, nPlane);
    float normalIntoPlane = FloatAbsD(dot) * inSpeed;

    // CRITICAL: filter out continuous surfing
    // when surfing, velocity is parallel to ramp, so normalIntoPlane is very low
    // a board has significant velocity into the plane
    // this is not a good solution. we need to find a better way to use the amount of ticks with no clip callbacks instead.
    if (normalIntoPlane < g_cvMinIntoPlane.FloatValue)
        return;

    // cooldown check - prevent rapid-fire detections from same board event
    float now = GetGameTime();
    if ((now - g_LastBoardTime[client]) < g_cvBoardCooldown.FloatValue)
        return;

    // lock to this ramp; HUD will not update again until player leaves the ramp
    g_IsSurfingRamp[client] = true;

    // calculate derived metrics
    float lossPct = (inSpeed > 0.0) ? (loss / inSpeed) : 0.0;
    float angleToPlane = RadToDeg(ArcCosine(ClampFloat(FloatAbsD(dot), 0.0, 1.0)));
    float rampAngle = RadToDeg(ArcCosine(ClampFloat(FloatAbsD(nPlane[2]), 0.0, 1.0)));

    // determine grade with speed-adjusted thresholds
    BoardGrade grade = CalculateGrade(lossPct, angleToPlane, inSpeed);

    // store the board data
    g_BoardData[client].hasResult = true;
    g_BoardData[client].plane[0] = planeNormal[0];
    g_BoardData[client].plane[1] = planeNormal[1];
    g_BoardData[client].plane[2] = planeNormal[2];
    g_BoardData[client].inSpeed = inSpeed;
    g_BoardData[client].outSpeed = outSpeed;
    g_BoardData[client].loss = loss;
    g_BoardData[client].lossPct = lossPct;
    g_BoardData[client].normalIntoPlane = normalIntoPlane;
    g_BoardData[client].angleToPlane = angleToPlane;
    g_BoardData[client].rampAngle = rampAngle;
    g_BoardData[client].timestamp = now;
    g_BoardData[client].grade = grade;

    g_LastBoardTime[client] = now;

    if (g_Prefs[client].hudEnabled)
    {
        RenderBoardHud(client, g_Prefs[client].displayTime);
    }

    // debug output
    if (g_cvDebug.BoolValue)
    {
        PrintToChat(client, "[BST Debug] Loss: %.1f (%.1f%%) | Angle: %.1f° | Into: %.1f | Grade: %s",
            loss, lossPct * 100.0, angleToPlane, normalIntoPlane, g_Grades[grade].name);
    }
}

BoardGrade CalculateGrade(float lossPct, float angle, float speed)
{
    // calculate speed scaling factor
    // at 1500 u/s: factor = 1.0
    // at 3000 u/s: factor = 1.41 (sqrt(2))
    // etc
    float speedFactor = SquareRoot(speed / BASE_SPEED_REFERENCE);
    if (speedFactor < 1.0) speedFactor = 1.0;

    // check each grade from best to worst
    for (int i = 0; i < view_as<int>(Grade_COUNT); i++)
    {
        BoardGrade grade = view_as<BoardGrade>(i);
        
        // scale the loss threshold based on speed
        float adjustedLossThreshold = g_Grades[grade].baseLossPct * speedFactor;
        
        // qualify if both loss% is low enough AND angle is high enough
        bool meetsLoss = (lossPct <= adjustedLossThreshold);
        bool meetsAngle = (angle >= g_Grades[grade].minAngle);
        
        if (meetsLoss && meetsAngle)
        {
            return grade;
        }
    }

    return Grade_Terrible;
}

// HUD rendering
void RenderBoardHud(int client, float holdTime)
{
    BoardGrade grade = g_BoardData[client].grade;
    
    int color[4];
    color[0] = g_Grades[grade].r;
    color[1] = g_Grades[grade].g;
    color[2] = g_Grades[grade].b;
    color[3] = 255;

    char hudText[512];
    BuildHudText(client, hudText, sizeof(hudText));

    holdTime = ClampFloat(holdTime, HUD_TIME_MIN, HUD_TIME_MAX);

    SetHudTextParamsEx(g_Prefs[client].posX, g_Prefs[client].posY, holdTime, color, color, 0, 0.0, 0.0, 0.0);
    ShowSyncHudText(client, g_hHudSync, hudText);
}

void BuildHudText(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    
    HudPrefs prefs;
    prefs = g_Prefs[client];
    
    BoardSample data;
    data = g_BoardData[client];
    
    BoardGrade grade = data.grade;

    if (prefs.compactMode)
    {
        // compact: single line
        char parts[128];
        bool needsSep = false;
        
        if (prefs.showGrade)
        {
            Format(buffer, maxlen, "%s", g_Grades[grade].name);
            needsSep = true;
        }
        
        if (prefs.showLossUnits || prefs.showLossPct)
        {
            char lossText[64];
            
            if (prefs.showLossUnits && prefs.showLossPct)
            {
                Format(lossText, sizeof(lossText), "Loss: %.1f (%.1f%%)", data.loss, data.lossPct * 100.0);
            }
            else if (prefs.showLossUnits)
            {
                Format(lossText, sizeof(lossText), "Loss: %.1f", data.loss);
            }
            else
            {
                Format(lossText, sizeof(lossText), "Loss: %.1f%%", data.lossPct * 100.0);
            }
            
            Format(parts, sizeof(parts), "%s%s", needsSep ? " | " : "", lossText);
            StrCat(buffer, maxlen, parts);
            needsSep = true;
        }
        
        if (prefs.showAngle)
        {
            Format(parts, sizeof(parts), "%sAngle: %.1f°", needsSep ? " | " : "", data.angleToPlane);
            StrCat(buffer, maxlen, parts);
            needsSep = true;
        }
        
        if (prefs.showSpeeds)
        {
            Format(parts, sizeof(parts), "%s%.0f→%.0f", needsSep ? " | " : "", data.inSpeed, data.outSpeed);
            StrCat(buffer, maxlen, parts);
        }

        return;
    }

    // detailed mode: multiple lines
    if (prefs.showGrade)
    {
        Format(buffer, maxlen, "%s", g_Grades[grade].name);
    }

    if (prefs.showLossUnits || prefs.showLossPct)
    {
        char line[64];
        
        if (prefs.showLossUnits && prefs.showLossPct)
        {
            Format(line, sizeof(line), "Loss: %.1f u/s (%.1f%%)", data.loss, data.lossPct * 100.0);
        }
        else if (prefs.showLossUnits)
        {
            Format(line, sizeof(line), "Loss: %.1f u/s", data.loss);
        }
        else
        {
            Format(line, sizeof(line), "Loss: %.1f%%", data.lossPct * 100.0);
        }
        
        AppendLine(buffer, maxlen, line);
    }

    if (prefs.showAngle || prefs.showRampAngle || prefs.showIntoPlane)
    {
        char line[128];
        line[0] = '\0';
        
        if (prefs.showAngle)
        {
            Format(line, sizeof(line), "Angle: %.1f°", data.angleToPlane);
        }
        
        if (prefs.showRampAngle)
        {
            char temp[32];
            Format(temp, sizeof(temp), "%sRamp: %.1f°", line[0] != '\0' ? " | " : "", data.rampAngle);
            StrCat(line, sizeof(line), temp);
        }
        
        if (prefs.showIntoPlane)
        {
            char temp[32];
            Format(temp, sizeof(temp), "%sInto: %.1f", line[0] != '\0' ? " | " : "", data.normalIntoPlane);
            StrCat(line, sizeof(line), temp);
        }
        
        AppendLine(buffer, maxlen, line);
    }

    if (prefs.showSpeeds)
    {
        char line[64];
        Format(line, sizeof(line), "Speed: %.0f → %.0f u/s", data.inSpeed, data.outSpeed);
        AppendLine(buffer, maxlen, line);
    }

    if (buffer[0] == '\0')
    {
        Format(buffer, maxlen, "Board (no display options selected)");
    }
}

void AppendLine(char[] buffer, int maxlen, const char[] line)
{
    if (buffer[0] != '\0')
    {
        StrCat(buffer, maxlen, "\n");
    }
    StrCat(buffer, maxlen, line);
}


/* obsolete but maybe useful later.. alternative ramp detection using trace. dont really wanna do this either. 

bool IsPlayerOnSurfRamp(int client)
{
    float origin[3];
    GetClientAbsOrigin(client, origin);
    origin[2] += 12.0; // trace slightly above feet

    float end[3];
    end[0] = origin[0];
    end[1] = origin[1];
    end[2] = origin[2] - 64.0;

    TR_TraceRayFilter(origin, end, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_NoPlayers, client);

    if (!TR_DidHit())
        return false;

    float normal[3];
    TR_GetPlaneNormal(INVALID_HANDLE, normal);

    float normalZ = FloatAbsD(normal[2]);
    float minZ = g_cvRampMinZ.FloatValue;
    float maxZ = g_cvRampMaxZ.FloatValue;

    // Avoid locking while airborne well above a ramp surface
    float hitPos[3];
    TR_GetEndPosition(hitPos);
    if ((origin[2] - hitPos[2]) > 60.0)
        return false;

    return (normalZ >= minZ && normalZ <= maxZ);
}
*/

public bool TraceFilter_NoPlayers(int entity, int contentsMask, any data)
{
    #pragma unused contentsMask, data
    // ignore players; let world + brush entities through
    return (entity == 0 || entity > MaxClients);
}

// cmds
public Action Cmd_MainMenu(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[BoardStats] This command must be used in-game.");
        return Plugin_Handled;
    }

    ShowMainMenu(client);
    return Plugin_Handled;
}

public Action Cmd_ToggleHud(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[BoardStats] This command must be used in-game.");
        return Plugin_Handled;
    }

    g_Prefs[client].hudEnabled = !g_Prefs[client].hudEnabled;
    SaveClientPrefs(client);
    PrintToChat(client, "[BoardStats] HUD %s.", g_Prefs[client].hudEnabled ? "enabled" : "disabled");
    return Plugin_Handled;
}

public Action Cmd_SetPosition(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[BoardStats] This command must be used in-game.");
        return Plugin_Handled;
    }

    if (args >= 1)
    {
        char arg[32];
        GetCmdArg(1, arg, sizeof(arg));
        
        if (StrEqual(arg, "reset", false) || StrEqual(arg, "default", false))
        {
            g_Prefs[client].posX = g_cvHudPosX.FloatValue;
            g_Prefs[client].posY = g_cvHudPosY.FloatValue;
            SaveClientPrefs(client);
            PrintToChat(client, "[BoardStats] HUD position reset to defaults.");
            return Plugin_Handled;
        }
    }

    if (args < 2)
    {
        ReplyToCommand(client, "[BoardStats] Usage: sm_boardhud_pos <x> <y> | sm_boardhud_pos reset");
        return Plugin_Handled;
    }

    char arg[32];
    GetCmdArg(1, arg, sizeof(arg));
    float x = ClampFloat(StringToFloat(arg), -1.0, 1.0);
    
    GetCmdArg(2, arg, sizeof(arg));
    float y = ClampFloat(StringToFloat(arg), -1.0, 1.0);

    g_Prefs[client].posX = x;
    g_Prefs[client].posY = y;
    SaveClientPrefs(client);
    
    PrintToChat(client, "[BoardStats] HUD position set to (%.2f, %.2f).", x, y);
    return Plugin_Handled;
}

public Action Cmd_ReloadConfig(int client, int args)
{
    LoadConfiguration();
    ReplyToCommand(client, "[BoardStats] Configuration reloaded.");
    return Plugin_Handled;
}

// menu system
void ShowMainMenu(int client)
{
    Menu menu = new Menu(MainMenuHandler);
    menu.SetTitle("Board Stats Settings");

    char buffer[64];
    
    Format(buffer, sizeof(buffer), "HUD: %s", g_Prefs[client].hudEnabled ? "ON" : "OFF");
    menu.AddItem("toggle_hud", buffer);
    
    Format(buffer, sizeof(buffer), "Mode: %s", g_Prefs[client].compactMode ? "Compact" : "Detailed");
    menu.AddItem("toggle_mode", buffer);
    
    menu.AddItem("display_options", "Display Options →");
    menu.AddItem("position_settings", "Position & Timing →");
    menu.AddItem("reset_defaults", "Reset to Defaults");

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MainMenuHandler(Menu menu, MenuAction action, int client, int param2)
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

    if (StrEqual(info, "toggle_hud"))
    {
        g_Prefs[client].hudEnabled = !g_Prefs[client].hudEnabled;
        SaveClientPrefs(client);
        ShowMainMenu(client);
    }
    else if (StrEqual(info, "toggle_mode"))
    {
        g_Prefs[client].compactMode = !g_Prefs[client].compactMode;
        SaveClientPrefs(client);
        ShowMainMenu(client);
    }
    else if (StrEqual(info, "display_options"))
    {
        ShowDisplayOptionsMenu(client);
    }
    else if (StrEqual(info, "position_settings"))
    {
        ShowPositionMenu(client);
    }
    else if (StrEqual(info, "reset_defaults"))
    {
        InitializeDefaultPrefs(client);
        SaveClientPrefs(client);
        PrintToChat(client, "[BoardStats] Settings reset to defaults.");
        ShowMainMenu(client);
    }

    return 0;
}

void ShowDisplayOptionsMenu(int client)
{
    Menu menu = new Menu(DisplayOptionsHandler);
    menu.SetTitle("Display Options");

    char buffer[64];

    Format(buffer, sizeof(buffer), "Grade Label: %s", g_Prefs[client].showGrade ? "ON" : "OFF");
    menu.AddItem("grade", buffer);
    
    Format(buffer, sizeof(buffer), "Loss (units): %s", g_Prefs[client].showLossUnits ? "ON" : "OFF");
    menu.AddItem("loss_units", buffer);
    
    Format(buffer, sizeof(buffer), "Loss (percent): %s", g_Prefs[client].showLossPct ? "ON" : "OFF");
    menu.AddItem("loss_pct", buffer);
    
    Format(buffer, sizeof(buffer), "Approach Angle: %s", g_Prefs[client].showAngle ? "ON" : "OFF");
    menu.AddItem("angle", buffer);
    
    Format(buffer, sizeof(buffer), "Ramp Angle: %s", g_Prefs[client].showRampAngle ? "ON" : "OFF");
    menu.AddItem("ramp_angle", buffer);
    
    Format(buffer, sizeof(buffer), "Into-Plane Velocity: %s", g_Prefs[client].showIntoPlane ? "ON" : "OFF");
    menu.AddItem("into_plane", buffer);
    
    Format(buffer, sizeof(buffer), "Speed In/Out: %s", g_Prefs[client].showSpeeds ? "ON" : "OFF");
    menu.AddItem("speeds", buffer);

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int DisplayOptionsHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
    {
        ShowMainMenu(client);
        return 0;
    }

    if (action != MenuAction_Select)
        return 0;

    char info[32];
    menu.GetItem(param2, info, sizeof(info));

    if (StrEqual(info, "grade")) g_Prefs[client].showGrade = !g_Prefs[client].showGrade;
    else if (StrEqual(info, "loss_units")) g_Prefs[client].showLossUnits = !g_Prefs[client].showLossUnits;
    else if (StrEqual(info, "loss_pct")) g_Prefs[client].showLossPct = !g_Prefs[client].showLossPct;
    else if (StrEqual(info, "angle")) g_Prefs[client].showAngle = !g_Prefs[client].showAngle;
    else if (StrEqual(info, "ramp_angle")) g_Prefs[client].showRampAngle = !g_Prefs[client].showRampAngle;
    else if (StrEqual(info, "into_plane")) g_Prefs[client].showIntoPlane = !g_Prefs[client].showIntoPlane;
    else if (StrEqual(info, "speeds")) g_Prefs[client].showSpeeds = !g_Prefs[client].showSpeeds;

    SaveClientPrefs(client);
    ShowDisplayOptionsMenu(client);
    return 0;
}

void ShowPositionMenu(int client)
{
    Menu menu = new Menu(PositionMenuHandler);
    menu.SetTitle("Position & Timing\nCurrent: X=%.2f Y=%.2f Time=%.1fs", 
        g_Prefs[client].posX, g_Prefs[client].posY, g_Prefs[client].displayTime);

    menu.AddItem("pos_center", "Center HUD");
    menu.AddItem("pos_top", "Top Center");
    menu.AddItem("pos_left", "Left Side");
    menu.AddItem("pos_right", "Right Side");
    menu.AddItem("time_up", "Display Time +0.5s");
    menu.AddItem("time_down", "Display Time -0.5s");
    menu.AddItem("reset_pos", "Reset Position");

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int PositionMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
    {
        ShowMainMenu(client);
        return 0;
    }

    if (action != MenuAction_Select)
        return 0;

    char info[32];
    menu.GetItem(param2, info, sizeof(info));

    if (StrEqual(info, "pos_center"))
    {
        g_Prefs[client].posX = -1.0;
        g_Prefs[client].posY = -1.0;
    }
    else if (StrEqual(info, "pos_top"))
    {
        g_Prefs[client].posX = -1.0;
        g_Prefs[client].posY = 0.1;
    }
    else if (StrEqual(info, "pos_left"))
    {
        g_Prefs[client].posX = 0.02;
        g_Prefs[client].posY = 0.35;
    }
    else if (StrEqual(info, "pos_right"))
    {
        g_Prefs[client].posX = 0.75;
        g_Prefs[client].posY = 0.35;
    }
    else if (StrEqual(info, "time_up"))
    {
        g_Prefs[client].displayTime = ClampFloat(g_Prefs[client].displayTime + 0.5, HUD_TIME_MIN, HUD_TIME_MAX);
    }
    else if (StrEqual(info, "time_down"))
    {
        g_Prefs[client].displayTime = ClampFloat(g_Prefs[client].displayTime - 0.5, HUD_TIME_MIN, HUD_TIME_MAX);
    }
    else if (StrEqual(info, "reset_pos"))
    {
        g_Prefs[client].posX = g_cvHudPosX.FloatValue;
        g_Prefs[client].posY = g_cvHudPosY.FloatValue;
        g_Prefs[client].displayTime = g_cvDisplayTime.FloatValue;
    }

    SaveClientPrefs(client);
    ShowPositionMenu(client);
    return 0;
}

// clientprefs
void LoadClientPrefs(int client)
{
    InitializeDefaultPrefs(client);

    if (g_hPrefsCookie == INVALID_HANDLE)
        return;

    char raw[256];
    GetClientCookie(client, g_hPrefsCookie, raw, sizeof(raw));
    
    if (raw[0] == '\0')
        return;

    char parts[16][16];
    int count = ExplodeString(raw, "|", parts, sizeof(parts), sizeof(parts[]));

    if (count >= 12)
    {
        g_Prefs[client].hudEnabled = StringToInt(parts[0]) != 0;
        g_Prefs[client].showGrade = StringToInt(parts[1]) != 0;
        g_Prefs[client].showLossUnits = StringToInt(parts[2]) != 0;
        g_Prefs[client].showLossPct = StringToInt(parts[3]) != 0;
        g_Prefs[client].showAngle = StringToInt(parts[4]) != 0;
        g_Prefs[client].showIntoPlane = StringToInt(parts[5]) != 0;
        g_Prefs[client].showRampAngle = StringToInt(parts[6]) != 0;
        g_Prefs[client].showSpeeds = StringToInt(parts[7]) != 0;
        g_Prefs[client].compactMode = StringToInt(parts[8]) != 0;
        g_Prefs[client].posX = ClampFloat(StringToFloat(parts[9]), -1.0, 1.0);
        g_Prefs[client].posY = ClampFloat(StringToFloat(parts[10]), -1.0, 1.0);
        g_Prefs[client].displayTime = ClampFloat(StringToFloat(parts[11]), HUD_TIME_MIN, HUD_TIME_MAX);
    }
}

void SaveClientPrefs(int client)
{
    if (g_hPrefsCookie == INVALID_HANDLE || !IsClientInGame(client) || !AreClientCookiesCached(client))
        return;

    char buffer[256];
    Format(buffer, sizeof(buffer), "%d|%d|%d|%d|%d|%d|%d|%d|%d|%.3f|%.3f|%.2f",
        g_Prefs[client].hudEnabled,
        g_Prefs[client].showGrade,
        g_Prefs[client].showLossUnits,
        g_Prefs[client].showLossPct,
        g_Prefs[client].showAngle,
        g_Prefs[client].showIntoPlane,
        g_Prefs[client].showRampAngle,
        g_Prefs[client].showSpeeds,
        g_Prefs[client].compactMode,
        g_Prefs[client].posX,
        g_Prefs[client].posY,
        g_Prefs[client].displayTime);

    SetClientCookie(client, g_hPrefsCookie, buffer);
}

// utils
bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}

float ClampFloat(float value, float min, float max)
{
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

// i need my own
void NormalizeVectorD(const float vec[3], float out[3])
{
    float length = SquareRoot(vec[0] * vec[0] + vec[1] * vec[1] + vec[2] * vec[2]);
    if (length > 0.0001)
    {
        out[0] = vec[0] / length;
        out[1] = vec[1] / length;
        out[2] = vec[2] / length;
    }
    else
    {
        out[0] = 0.0;
        out[1] = 0.0;
        out[2] = 0.0;
    }
}

void ParseColorString(const char[] input, int &r, int &g, int &b)
{
    char clean[64];
    strcopy(clean, sizeof(clean), input);
    ReplaceString(clean, sizeof(clean), ",", " ");
    TrimString(clean);
    
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

int ClampInt(int value, int min, int max)
{
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

// again, i feel safer this way
stock float FloatAbsD(float value)
{
    return value < 0.0 ? -value : value;
}
