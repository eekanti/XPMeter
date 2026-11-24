# XPMeter

A small session XP and gold tracker for WoW Forever. It counts every point of XP
and every copper you earn, and shows where they came from.

## What it shows

- Session XP, XP per hour and active session time
- Level bar with your rested pool shaded, time to level and kills to level
- Breakdown by source, with share of the total:
  - **Kills**: mob XP without the rested part
  - **Rested bonus**: the extra XP rested gave you on kills
  - **Quests**: quest turn-in XP
  - **Exploration**: XP for discovering areas
  - **Other**: anything else the XP bar gained, so nothing goes uncounted
- Gold made and gold per hour, by source:
  - **Coin looted**: gold, silver and copper from mobs, chests and your share of group loot
  - **Items (AH)**: looted items valued at Auctionator's AH price when you looted them
  - **Items (vendor)**: items with no AH price (or an AH price below vendor), and soulbound items, at vendor price
  - **Quest rewards**: quest money plus the value of reward items
  - Hover an item row to see its most valuable items
- Selling to vendors or the AH, mail and trades are not counted: those items were already counted
  when looted, so counting the sale too would count them twice

## Controls

- **Start / Stop**: one toggle. Start begins a session from zero; Stop ends it,
  keeps its numbers on screen and saves it to the history.
- **Pause / Resume**: while paused, no XP, gold or time is counted.
- **Reset**: zeroes time, XP and gold. A running or paused session carries on from zero.

**Mini mode**: click the XP or gold headline (or its +/- box) to fold away that section's source breakdown
(the level bar stays); the box in the title bar folds both. The window remembers what's folded.

A running session survives `/reload` and logging out; offline time is never counted.

## Slash commands

`/xpm` (or `/xpmeter`) shows or hides the window.
`/xpm start | pause | resume | stop | reset | history | mini`

## Look

Uses EllesmereUI's skinning API when EllesmereUI is installed (theme, font,
accent and bar fill); a plain flat dark window otherwise. Item values come from
Auctionator when it's installed; without it every item counts at vendor price.

## Changelog

### 1.1.0 (2026-11-24 01:50 EST)
- Gold tracking: coin looted, looted items at AH or vendor value, quest money and reward items.
- Gold per hour, item lists on hover, gold in /xpm history.
- Collapsible XP and gold sections, and a mini mode that folds both (title bar box or /xpm mini).

### 1.0.0 (2026-11-17 23:03 EST)
- First release.

## License

MIT, see LICENSE.
