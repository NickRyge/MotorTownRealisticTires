# Motor Town Tire Fix

Makes the tires in Motor Town grip like real tires instead of feeling floaty.

In the stock game the tires only reach full cornering grip at about a **45° slip angle**, so cars feel vague and slide around before they bite. Real tires reach it at around 5–12°. This mod changes the tire settings so the grip comes in at about **10–12°**. Cars turn in when you steer, and trucks feel planted.

The mod changes tire values only. It doesn't change cars, the map, money or your save.

---

## Download

1. Go to the **[Releases](../../releases/latest)** page.
2. Under **Assets**, download **`MTTireFix_P.pak`**.

(Don't use the green "Code" button. That's the source code, not the mod.)

## Install

1. **Close Motor Town.**
2. Open the game folder: in Steam, right-click **Motor Town** → **Manage** → **Browse local files**.
3. Go into `MotorTown` → `Content` → `Paks`.
   You should see a big file called `MotorTown-Windows.pak`. You're in the right place.
4. In that `Paks` folder, create a new folder named exactly **`~mods`** (tilde, then mods).
5. Put **`MTTireFix_P.pak`** into the `~mods` folder.
6. Start the game.

The finished layout:

```
Motor Town/
└── MotorTown/
    └── Content/
        └── Paks/
            ├── MotorTown-Windows.pak     (the game, don't touch)
            └── ~mods/
                └── MTTireFix_P.pak       (the mod)
```

## Update

Close the game, download the new `MTTireFix_P.pak`, and replace the old one in `~mods`.

## Uninstall

Close the game and delete `MTTireFix_P.pak` from `~mods`. The game goes back to stock tires.

## Troubleshooting

- **No difference in game?** Check that the folder is named `~mods` (not `mods` or `~mods (1)`), that it's inside `Paks`, and that the file ends in `.pak` and not `.pak.txt`. In Windows Explorer, turn on **View → File name extensions** to check.
- **Game won't start or crashes after an update?** Delete the mod and wait for a new release. Game updates can change tire files.
- **Multiplayer:** the mod changes physics on your own PC only. It hasn't been tested on servers.

---

## Optional: WheelDebugger (advanced)

A separate, optional add-on for people who want to tweak things further. It needs [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (a script loader for Unreal games). **You don't need it for the tire fix.**

It adds:
- stronger brakes (×1.8), because stock brakes run out before the tires do
- smoother ABS
- the game's friction circle (on by default), so slides hold and recover better
- force feedback presets for steering wheels
- live tire and brake telemetry overlays and a 30-second data recorder

**Install:**
1. Install UE4SS (experimental build) into `MotorTown/Binaries/Win64/`, following its own instructions.
2. Download `WheelDebugger.zip` from the release and extract it into `MotorTown/Binaries/Win64/ue4ss/Mods/`, so you get `ue4ss/Mods/WheelDebugger/Scripts/...`.
3. Open `ue4ss/Mods/mods.txt` and add the line `WheelDebugger : 1` above the `Keybinds : 1` line.

**Keys:**

| Key | What it does |
|---|---|
| F8 | Text overlay (tires, car) |
| F7 | Wheel view and G-meter |
| F6 | Brake panel with an automatic brake test |
| F9 | Reset max values |
| F10 | Record 30 seconds of telemetry |
| Ctrl+F6 | Brake boost on / off |
| Ctrl+F5 | ABS preset: stock / fast / smooth (default) / firm |
| Ctrl+F1 | Force feedback preset: stock / detail (default) / raw |
| Ctrl+F7 | Steering assist for keyboard/gamepad (off by default) |
| Ctrl+F8 | Friction circle on (default) / off |

**Uninstall:** delete `dwmapi.dll` and the `ue4ss` folder from `MotorTown/Binaries/Win64/`.

---

## For developers

See [BUILDING.md](BUILDING.md) for how the pak is built, how the tire data is decoded, and the tools used.

## License

[MIT](LICENSE). Motor Town belongs to its developers. This project contains no game files, only the modified tire values in the release pak.
