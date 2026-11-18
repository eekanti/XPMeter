# XPMeter

A small session XP tracker for WoW Forever. It counts every point of XP you earn
and shows where it came from.

## What it shows

- Session XP, XP per hour and active session time
- Level bar with your rested pool shaded, time to level and kills to level
- Breakdown by source, with share of the total:
  - **Kills**: mob XP without the rested part
  - **Rested bonus**: the extra XP rested gave you on kills
  - **Quests**: quest turn-in XP
  - **Exploration**: XP for discovering areas
  - **Other**: anything else the XP bar gained, so nothing goes uncounted

## Controls

- **Start / Stop**: one toggle. Start begins a session from zero; Stop ends it,
  keeps its numbers on screen and saves it to the history.
- **Pause / Resume**: while paused, no XP or time is counted.
- **Reset**: zeroes time and XP. A running or paused session carries on from zero.

A running session survives `/reload` and logging out; offline time is never counted.

## Slash commands

`/xpm` (or `/xpmeter`) shows or hides the window.
`/xpm start | pause | resume | stop | reset | history`

## Look

Uses EllesmereUI's skinning API when EllesmereUI is installed (theme, font,
accent and bar fill); a plain flat dark window otherwise.

## Changelog

### 1.0.0 (2026-11-17 23:03 EST)
- First release.

## License

MIT, see LICENSE.
