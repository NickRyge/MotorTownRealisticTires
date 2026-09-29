# Building from source

The pak is built with `MTPak` (.NET 10, [CUE4Parse](https://github.com/FabianFG/CUE4Parse)) from a values file such as `mod_step5.json`:

```
dotnet run --project MTPak -c Release -- findkey
dotnet run --project MTPak -c Release -- mkmod mod_step5.json build/MTTireFix_P.pak
dotnet run --project MTPak -c Release -- verifymod build/MTTireFix_P.pak
```

Reading the base pak needs an Oodle DLL (`oodle-data-shared.dll`) next to the project. It isn't included here. Building the mod doesn't need it.

## MTPak

Helpers for reading Motor Town's game data (Unreal Engine 5.5, a single `MotorTown-Windows.pak` with an AES-encrypted index and Oodle compression).

Run from this folder:

```
dotnet run --project MTPak -c Release -- findkey
dotnet run --project MTPak -c Release -- extract Cars/Parts/Tire/
dotnet run --project MTPak -c Release -- tires
```

Add `--game "<install dir>"` if the game isn't at `D:\Steam\steamapps\common\Motor Town`.

| Command | What it does |
|---|---|
| `findkey` | Finds the pak AES key in `MotorTown-Win64-Shipping.exe`, checks it against the pak index, and saves it to `aes.txt`. Run it again after a game update. |
| `extract <filter> [outDir]` | Writes every pak file whose path contains `<filter>` to `extracted/` (raw `.uasset` / `.uexp`). |
| `mkmod <values.json> [out.pak]` | Patches tire fields in place (only fields the asset already stores) and writes an override pak, `build/MTTireFix_P.pak` by default. Values file: `{ "BasicTire_45": { "SpringY": 51500, "DampingY": 220 }, ... }`. |
| `verifymod <pak>` | Mounts a mod pak on its own and prints the decoded tire values. |
| `tires [out.json]` | Decodes `FMTTirePhysicsParams` from every tire part and writes `tires.json`, with C++ defaults filled in for omitted fields. |

## How the key is found

UE registers the pak key via `UE_REGISTER_ENCRYPTION_KEY`, which compiles to a small callback that writes the 32 key bytes to the stack as eight `mov dword [rbp+disp], imm32` instructions, then copies them out. In this build the compiler interleaves other instructions between those stores, so simple contiguous-pattern scanners miss it. `findkey` collects the stores inside a sliding window instead, and validates every candidate by decrypting the first block of the pak index (it must start with the `../../../` mount point).

If that ever fails after an update, the manual route that found it the first time:

1. Find the UTF-16 string `Failed to find requested encryption key %s` and the function that references it (the key lookup).
2. When the key GUID is zero, that function calls a getter for `FCoreDelegates::GetPakEncryptionKeyDelegate()` and executes the delegate.
3. Callers of that getter include `RegisterEncryptionKeyCallback`, which allocates the delegate and stores the callback pointer. Its only caller is a static initializer: `lea rcx, [callback]; jmp RegisterEncryptionKeyCallback`.
4. The callback holds the key as immediates.

## Oodle

`oodle-data-shared.dll` is the Oodle build CUE4Parse downloads. VirusTotal: 1/70 engines flagged it (SHA-256 `cba19529d0a3b5ec9c630e95652af01e123ae29a34a8a5f7507f5bcf23d9e82b`). Accepted after checking. None of the installed games ship a standalone Oodle DLL. Replace it with a trusted `oo2core_9_win64.dll` renamed to this name if one turns up.

## Tire asset notes (game build of 2026-08-30)

- Assets use unversioned serialization. `FMTTirePhysicsParams` field order and offsets come from the exe's reflection data: PatchLengthCoefficient 0x00, StaticMu 0x04, SlidingMu 0x08, SpringX 0x0C, SpringY 0x10, DampingX 0x14, DampingY 0x18, CoolDownSpeed 0x1C, WarmUpSpeed 0x20, WearRate 0x24, SmokeRate 0x28, MaxWeightKg 0x2C, BrushCount 0x30 (int), OffroadFriction 0x34, RollingResistanceCoeff 0x38, RollingResistanceCoeffV1 0x3C.
- The params struct sits at offset 0x30 in `UMTTirePhysicsDataAsset`. Wheel config: `TirePhysicsData` at 0x638, `BrushTirePhysics` at 0x640 (its `ContactPatchLength` at +0x54, `ContactPatchStaticLength` at +0x58).
- C++ defaults (read from the constructor): PatchLengthCoefficient 20000, StaticMu 1.0, SlidingMu 0.8, SpringX 30000, SpringY 8000, DampingX 100, DampingY 20, CoolDownSpeed 0.5, WarmUpSpeed 100, WearRate 1.0, SmokeRate 1.0, MaxWeightKg 1000, BrushCount 180.
- The brush force function itself has not been located or disassembled yet.
