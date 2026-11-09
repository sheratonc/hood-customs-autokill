# hood-customs-autokill

Autokill script for **Hood Customs Free For All** (Da Hood-style FFA), built on the [LinoriaLib](https://github.com/violin-suzutsuki/LinoriaLib) UI library.

All combat routes through the game's single remote (`ReplicatedStorage.MainEvent:FireServer`). The script fires the gun to down a target (`"Shoot"`), then sends the finisher (`"Stomp"`) once they K.O.

`"Shoot"` hit-reg is client-authoritative but the server validates the shot's origin against your **real replicated position** — a forged origin next to a far target is silently dropped (dealt zero damage in live tests). So long-range and through-wall kills need you to actually be there. **Blink to shoot** handles that: when a target is past the gun's range cap or behind cover, the script saves your spot, blinks point-blank onto a clean firing angle, empties the clip from the real muzzle, and blinks back. The finisher then closes the kill. Live-proven downing a target at 925 studs through geometry.

## Load it

Paste this into your executor:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/sheratonc/hood-customs-autokill/main/HoodCustomsAutokill.lua"))()
```

## Using it

- **RightShift** — open / close the menu
- **K** — toggle autokill (synced to the `Autokill enabled` switch)

### Main tab

| Option | What it does |
|--------|--------------|
| Autokill enabled | Master switch for the kill loop |
| Target player | Pick who to kill (ignored when Nearest is on, or used as priority) |
| Fallback to nearest | Auto-target the closest living player when no dropdown pick is set |
| Shoot to down | Silent-aim the gun at the target until they K.O |
| Blink to shoot | Force hit — if the target is out of range or behind a wall, blink point-blank, empty the clip, blink back |
| Stomp to finish | Blink onto the body and send the finisher once the target is downed |
| Auto-equip gun | Pull a gun from the backpack if none is held |
| Auto-reload | Reload when the clip is empty |
| Max distance | How far out to engage (also the nearest-target range cap) |
| Shot delay (floor) | Minimum spacing between shots; the gun's real server cooldown overrides this upward |

### Stomp farm (right box)

- **Stomp anyone under me** — pure finisher spam; stomps any downed body beneath you.

### Spectate (right box)

- **Spectate player** + **Spectate** — camera-only watch of the selected player; your own position never moves.

## Notes

- Config + theme save under `HoodCustomsAutokill/` via the LinoriaLib SaveManager/ThemeManager addons.
- The repo is public so the raw-URL loadstring works. Flip it private any time in repo settings — the loader just stops resolving for anyone without access.
