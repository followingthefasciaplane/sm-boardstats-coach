# board stats  
  
a sourcemod plugin for surf servers that helps players learn how to board ramps better. shows you a hud with detailed info every time you board a ramp, so you can see what you did right or wrong and improve over time.  
  
requires my [momsurffix2](https://github.com/followingthefasciaplane/MomSurfFix-API) fork to work. we are reading the direct engine clipping math to be able to do this, so it won't work with your regular momsurffix2. that might be bad news for some owners because i would not recommend putting my API on your public server. if nothing breaks online, then the performance probably will. still working on that.  
  
i have included a compiled smx and the include file from my momsurffix2 fork in this repository, however, feel free to go recompile it yourself over there too. you will need to **replace your existing one**.  
  
SUPER IMPORTANT: **TO REITERATE, PLAY WITH THIS AND MY FORK ON YOUR OWN LOCAL SERVER. DO NOT PUT THIS ON YOUR PUBLIC SERVER YET** unless you know its gonna be aight cuz i sure dont. ill probably get it there at some point though, or make a standalone version.  
    
## what it does  
  
when you hit a surf ramp at an angle (boarding), the plugin detects it and shows you stats about how clean your board was. it grades your boards from perfect down to terrible based on how much speed you lost and how perpendicular your velocity was to the ramp when you slammed into it. you can also customize the grades and make your own, as well as adjusting the conditions and colours for each grade.  
  
the idea is that if you can see exactly what went wrong with a board, you can fix it. most people just kinda guess whether a board was good or not, but this gives you 100% accurate numbers, not just estimates from a lot of tracing and math.  
  
## what the hud shows  
  
you can toggle each of these on or off in the settings menu:  
  
- **grade** - a simple rating from perfect to terrible, color coded  
- **loss (units)** - how much raw speed you lost in units per second  
- **loss (percent)** - speed loss as a percentage of your incoming speed  
- **approach angle** - the angle your velocity made with the ramp surface (90 would be completely parallel, which is ideal)  
- **ramp angle** - the steepness of the ramp itself  
- **into-plane velocity** - how hard you hit into the ramp (lower is better)  
- **speed in/out** - your speed before and after the board  
  
by default it just shows the grade and loss in units, but you can turn on more stuff if you want the full breakdown.  
  
## player commands  
  
there's a few more than this but these are the ones that are useful right now  
  
| command | what it does |
|---------|--------------|
| `sm_boardstats` or `sm_bst` | opens the settings menu |
| `sm_boardhud` | toggles the hud on or off |
| `sm_boardhud_pos <x> <y>` | sets the hud position manually (0.0 to 1.0, -1.0 for centered) |
| `sm_boardhud_pos reset` | resets position to default |
  
all your settings get saved automatically so they persist between sessions. or they should.  
  
## settings menu  
  
the menu lets you configure:  
  
- hud on/off  
- compact mode vs detailed mode (single line vs multiple lines)  
- which stats to show  
- preset positions (center, top, left side, right side)  
- how long the hud stays on screen  
  
there is a lot i still need to add to this  
  
## server cvars  
  
these go in `cstrike/cfg/sourcemod/boardstats.cfg` which gets created automatically on first run.  
  
| cvar | default | description |
|------|---------|-------------|
| `sm_boardstats_enable` | 1 | master toggle for the whole plugin |
| `sm_boardstats_display_time` | 5.0 | how long the hud shows by default, can be changed by users in menu (0.2 to 5.0 seconds) |
| `sm_boardstats_ramp_min_z` | 0.1 | minimum surface normal z to count as a ramp (filters out walls) |
| `sm_boardstats_ramp_max_z` | 0.7 | maximum surface normal z to count as a ramp (filters out floors) |
| `sm_boardstats_min_speed` | 100.0 | ignores boards below this speed |
| `sm_boardstats_min_into_plane` | 25.0 | minimum velocity perpendicular to the ramp to count as a board (filters out non-board clips) |
| `sm_boardstats_cooldown` | 0.25 | seconds between board detections per player |
| `sm_boardstats_hud_x` | -1.0 | default hud x position (-1 for centered) |
| `sm_boardstats_hud_y` | 0.35 | default hud y position |
| `sm_boardstats_debug` | 0 | prints debug info to chat if enabled |
  
the ramp z values might need tweaking depending on your setup. the defaults work for most standard surf maps but if you have weird ramp angles or high tick you might need to adjust. additionally, if you are getting hud updates on the middle of the ramp you can try to raise the minimum into plane, but this ramp detection is a bad solution and i will eventually use consecutive clip-per-tick heuristics and remove this.  
  
## grade configuration  
  
grades are configured in `cstrike/addons/sourcemod/configs/boardstats.cfg`. the plugin creates a default one if it doesnt exist.  
  
each grade has:  
- a loss percentage threshold, basically the percentage of your total units you lost on the board (scales with speed, so faster players get more leeway)  
- a minimum approach angle (90 = perfect)  
- a display name  
- a color (rgb)  
  
a board needs to meet both the loss percentage and angle requirements to get a grade. they're checked in order from perfect to terrible.  
  
the default thresholds are:
  
| grade | loss % | min angle | color |
|-------|--------|-----------|-------|
| perfect | 0.5% | 85 | blue |
| good | 1.5% | 80 | green |
| okay | 3.0% | 75 | white |
| bad | 5.0% | 60 | yellow |
| terrible | everything else | 0 | red |
  
the loss thresholds scale with speed using a square root function, so at 3000 u/s you get about 1.4x the threshold compared to 1500 u/s. this is because some speed loss is basically unavoidable at high speeds.  
  
| command | flag | what it does |
|---------|------|--------------|
| `sm_boardstats_reload` | config | reloads the grade config file |
  
this is an admin command that will reload your grades config file without restarting the plugin.  
  
## how it detects boards  

the plugin hooks into momsurffix2's clip velocity callback, which fires whenever the game clips a player's velocity against a surface. if you want to learn more, read [here](https://github.com/followingthefasciaplane/MomSurfFix-API/blob/master/surf-physics.md). it filters these events to only care about:  
  
- surfaces that are actually ramps (not walls or floors, based on the z normal)
- the very first clip of a ramp (clip velocity is called every tick you are touching the surface, which will just spam your hud with nonsense)  
  
once it detects a board, it locks onto that ramp until the player leaves it, so you dont get spammed with multiple detections from the same board. but there's a better way i want to do this in the future.  
  
## notes  
  
- the plugin does nothing if momsurffix2 api isnt loaded, it just waits for it  
- player preferences are stored in cookies so they work across map changes and reconnects  
- the hud uses the game's built-in hud text system so it should work on any csgo too, and tf2 if you add an api to their fork of momsurffix2    
- if you're seeing weird detections or missing boards, try adjusting the min_into_plane and ramp z cvars, otherwise theres more stuff to tweak in the source if you recompile  
  