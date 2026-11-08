# hood-customs-autokill

Autokill script for **Hood Customs Free For All** (Da Hood-style FFA), built on the [LinoriaLib](https://github.com/violin-suzutsuki/LinoriaLib) UI library.

All combat routes through the game's single remote (`ReplicatedStorage.MainEvent:FireServer`). The script fires the gun to down a target (`"Shoot"`), then sends the finisher (`"Stomp"`) once they K.O. Teleport-to-target is on by default so the server's shooter→victim distance check always passes.

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
| Target player | Pick who to kill (ignored when Nearest is on) |
| Target nearest instead | Auto-pick the closest living player |
| Shoot to down | Fire the gun at the target until they K.O |
| Stomp to finish | Send the finisher once the target is downed |
| Auto-equip gun | Pull a gun from the backpack if none is held |
| Auto-reload | Reload when the clip is empty |
| Teleport to target | Blink onto the target for range + stomp alignment |
| Return after kill | Teleport back to your original spot after each finish |
| Max distance | Range cap for nearest-target selection |
| Action delay | Pacing between actions |

### Stomp farm (right box)

- **Stomp anyone under me** — pure finisher spam; stomps any downed body beneath you.

## Notes

- Config + theme save under `HoodCustomsAutokill/` via the LinoriaLib SaveManager/ThemeManager addons.
- The repo is public so the raw-URL loadstring works. Flip it private any time in repo settings — the loader just stops resolving for anyone without access.
