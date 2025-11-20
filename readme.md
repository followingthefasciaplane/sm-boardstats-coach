# boardstats coach

boardstats is a sourcemod plugin for surf servers that provides instant feedback on board surfs. it uses the momsurffix2 api to analyze clip velocity, calculating speed loss, angles, and ramp efficiency.
this plugin requires my **momsurffix2** API to function. it can be found here: https://github.com/followingthefasciaplane/MomSurfFix-API  

it is heavily beta, work in progress, and needs a lot more in terms of basic formatting and colours, but the actual data is accurate for determining boards.  

## features

- **instant feedback:** shows a hud overlay immediately after surfing a board (ramp).
- **detailed stats:** displays speed loss, loss percentage, approach angle, into-plane velocity, and ramp slope.
- **grading system:** categorizes boards (e.g., "perfect", "okay", "scuffed") based on configurable thresholds.
- **customizable hud:** players can toggle specific stats, switch between compact/detailed modes, and move the hud position.
- **settings menu:** easy in-game menu to configure personal preferences.

## dependencies

- sourcemod 1.11+
- momsurffix2 api (must be installed and running)

## config

a configuration file will be automatically generated at `cfg/sourcemod/mom_boardcoach.cfg` for global settings, and you can make your own grading categories in `configs/mom_boardcoach_categories.cfg`.

## commands

### player commands

- `sm_boardhud` - toggle the board coach hud on or off.
- `sm_boardstats` or `sm_bst` - open the settings menu to customize hud elements (compact mode, show/hide speed, angles, grades, etc).
- `sm_boardhud_pos <x> <y>` - manually set the hud position (0.0 to 1.0). use `reset` to restore defaults.
- `sm_boardhud_time <seconds>` - set how long the hud remains on screen (0.2 to 5.0 seconds).

### admin commands

- `sm_boardcoach_reload` - reloads the board grading categories from the config file (requires config flag).

## convars

generated `cfg/sourcemod/mom_boardcoach.cfg`.

- `sm_boardcoach_enable` (default: 1) - enable or disable the plugin.
- `sm_boardcoach_display_time` (default: 3.0) - default duration the hud stays on screen.
- `sm_boardcoach_min_speed` (default: 100.0) - minimum speed required to trigger a board stat.
- `sm_boardcoach_ramp_min_normal_z` (default: 0.1) - minimum plane normal z to count as a ramp (filters out walls).
- `sm_boardcoach_ramp_max_normal_z` (default: 0.75) - maximum plane normal z to count as a ramp (filters out flat floors).
- `sm_boardcoach_hud_x` (default: 0.50) - default x position.
- `sm_boardcoach_hud_y` (default: 0.05) - default y position.
- some more

## configuration (grading categories)

you can customize how boards are graded by editing `addons/sourcemod/configs/mom_boardcoach_categories.cfg`.

the plugin evaluates categories from top to bottom. the first category that matches the criteria is applied.

example format:

```keyvalues
"Categories"
{
    "Perfect"
    {
        "label"         "Perfect board"
        "max_loss"      "20.0"
        "min_angle"     "80.0"
        "color"         "80 255 120"
    }
    "Okay"
    {
        "label"         "Okay board"
        "max_loss"      "50.0"
        "min_angle"     "70.0"
        "color"         "255 210 64"
    }
    // add more categories as needed
}
```

- `max_loss`: maximum speed loss allowed for this grade.
- `min_angle`: minimum approach angle allowed.
- `max_loss_pct`: (optional) maximum loss percentage (0.0 - 1.0).
- `min_speed`: (optional) minimum entry speed required.
- `color`: rgb color for the hud text.

