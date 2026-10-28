# Co-op Event Battles (Total War: WARHAMMER III)

[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3824814352) · [Releases](https://github.com/Agus224/twwh3-coop-event-battles/releases)

**Español** | [English](#english)

En la campaña cooperativa, cuando un jugador se teletransporta a una batalla de misión o de evento, su aliado puede sumar su **ejército real** (lord, héroes, objetos, habilidades) a esa misma batalla. El aliado controla su ejército; las bajas y la experiencia las aplica el juego.

Es ideal para las **batallas finales de la campaña**, como las de Archaon o Nagash, donde los dos jugadores pueden pelear juntos con sus ejércitos.

Este repositorio publica **todo el código fuente** del mod, incluido el componente nativo `ceb_native_bridge.dll`, para que cualquiera pueda revisar qué hace y comprobar que la DLL publicada es la que sale de este código. Todos los derechos reservados: ver [Derechos](#derechos).

## Por qué hay una DLL

El juego arma la lista de participantes de una batalla de misión una sola vez y no la vuelve a calcular. Ninguna función de script, tabla ni contexto de la interfaz permite sumar un ejército a una batalla de misión ya creada. La DLL usa las funciones internas del propio juego que arman los participantes de una batalla para agregar el ejército del aliado, igual que el juego hace con un aliado en una batalla normal.

## Qué hace y qué no hace la DLL

**Hace:**
- Se carga desde el script del mod con `package.loadlib` (la función de Lua que el juego deja disponible).
- Antes de hacer nada, comprueba que el ejecutable sea **exactamente** el analizado:
  - SHA-256 de `Warhammer3.exe` = `9bd58c63bd7fc5c9909b3d3d9b6b7a6ae4eac784369bf91a9e53c3e9f42be496`;
  - tamaño de imagen y fecha del ejecutable;
  - 14 firmas de 24 bytes de las funciones que usa ([`native_profile.json`](native_bridge/native_profile.json)).

  Si algo no coincide (por ejemplo, después de una actualización del juego), se desactiva y el mod solo informa que no está disponible.
- Lee las estructuras de la batalla pendiente, valida el ejército elegido y, si todo es correcto, llama a las funciones del juego que crean un participante. Después pide al juego que actualice la batalla pendiente.
- Toda lectura de memoria pasa antes por `VirtualQuery`, y las llamadas están protegidas con manejo de excepciones (SEH).

**No hace:**
- No modifica el código del juego: no parchea instrucciones ni instala hooks. El código del mod no llama a `VirtualProtect`; aparece en las importaciones solo porque lo usa el runtime de C estático.
- No se inyecta en otros procesos ni usa APIs de inyección (`WriteProcessMemory`, `CreateRemoteThread`...).
- No usa red y no toca el anti-copia. Los únicos archivos que abre son `Warhammer3.exe` (para calcular su SHA-256) y su propio log, `coop_event_battles_native_log.txt`.
- Solo importa `KERNEL32.dll` y `bcrypt.dll` (para el SHA-256).

Exporta tres funciones: `luaopen_ceb_native_bridge`, `ceb_bridge_abi_version` y `ceb_bridge_host_supported`. Desde Lua expone `status()`, `inspect()` (solo lectura) y `join()`.

### Funciones del juego que usa

| Nombre | RVA | Para qué |
|---|---|---|
| `allocate` / `release` | `0x4d3da0` / `0x4e98d4` | Reservar y liberar memoria con el asignador del juego |
| `construct_cohort` / `destroy_cohort` | `0x26687b4` / `0x2676658` | Crear el participante de la facción aliada |
| `append_cohort` | `0x2642468` | Agregarlo al bando del anfitrión |
| `initialize_cohort` | `0x269af00` | Calcular su despliegue o llegada como refuerzo |
| `prepare_character` / `observe_force` | `0x26b5c78` / `0x1c3adf0` | Registrar al general y al ejército en la batalla |
| `lookup_force` / `at_war` | `0x1c6a30c` / `0x26ba60c` | Buscar el ejército por su ID y verificar que no estén en guerra |
| `reinforcement_direction` | `0x2692774` | Dirección de llegada del ejército |
| `make_force_data` / `push_force_data` / `destroy_force_data` | `0x2669900` / `0x263f6b0` / `0x2676720` | Ejército adicional de la misma facción (solo en la prueba de un jugador, desactivada) |

## Cómo llega la DLL a tu PC

La Workshop solo distribuye archivos `.pack`, así que la DLL viaja dentro del pack como texto Lua (`script/campaign/mod/coop_event_battles_native_blob.lua`, generado por [`build_pack.cjs`](native_bridge/build_pack.cjs)). Al cargar una campaña multijugador, el script ([`network.inc.lua`](native_bridge/network.inc.lua)) hace esto:
1. Comprueba que la versión de la DLL incluida coincida con la del script.
2. Si `ceb_native_bridge.dll` no existe al lado de `Warhammer3.exe` o es distinta, la escribe y la vuelve a leer para verificarla.
3. La carga con `package.loadlib`.

En partidas de un jugador el mod no hace nada.

## Verificar la DLL

Después de cargar una campaña cooperativa con el mod, en PowerShell:

```powershell
Get-FileHash "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\ceb_native_bridge.dll" -Algorithm SHA256
```

El resultado tiene que coincidir con el SHA-256 de la DLL publicado en la [release](https://github.com/Agus224/twwh3-coop-event-battles/releases) de esa versión. Para la versión 1.1.2:

| Archivo | SHA-256 |
|---|---|
| `ceb_native_bridge.dll` | `167e24e406b9462738c555aa14d1838beb900dea6a80c28f70f56799f74fe95e` |
| `coop_event_battles.pack` | `15d3ae3e59a5fa674ff5d67bec162eb1c6f9afb05fbb8772771a19427eccb214` |

[`release/1.1.2/native_build.json`](release/1.1.2/native_build.json) registra el hash de los archivos fuente con los que se compiló esa DLL. El workflow de GitHub Actions compila la DLL desde este código en cada cambio y muestra su hash.

Los antivirus pueden marcar la DLL porque no está firmada digitalmente.

## Compilar (para verificar)

Podés compilar el código en tu PC para comprobar que coincide con lo publicado.

Requisitos: Windows, Visual Studio 2022 Build Tools (C++), Python 3 con `pefile` y `lupa`, Node.js.

```bat
cd native_bridge
compilar_y_validar.cmd
```

El script genera el código Lua, compila la DLL (`cl /O2 /MT`, enlazado reproducible `/Brepro`) y corre las pruebas:
- el núcleo C contra un motor simulado ([`test_bridge_core.c`](native_bridge/test_bridge_core.c));
- la validación del binario, que necesita `Warhammer3.exe` en la carpeta del juego;
- la lógica Lua ([`test_companion.py`](native_bridge/test_companion.py)).

Después arma el pack y verifica la DLL incluida.

Para armar el `.pack` hace falta además una copia del layout `ui/campaign ui/mp_pending_action_blocking_msg.twui.xml` del juego (está en `data/ui3.pack`; se puede extraer con [RPFM](https://github.com/Frodo45127/rpfm)). No se incluye aquí porque es un archivo de Creative Assembly. Copialo a `ui_src/` y aplicá el cambio del mod con:

```bat
python tools\patch_blocker_layout.py ui_src\mp_pending_action_blocking_msg.twui.xml
```

## Aviso

Mod no oficial, sin relación con Creative Assembly ni SEGA. El componente nativo se basa en el análisis del ejecutable del juego. Usalo bajo tu propia responsabilidad y en partidas de prueba primero. Si no querés código nativo en tu PC, no lo instales.

## Derechos

**Todos los derechos reservados.** Podés jugar el mod y revisar el código. No está permitido modificarlo, volver a subirlo, reutilizar su código ni venderlo sin permiso del autor.

---

## English

In co-op campaigns, when a player teleports to a mission or event battle, their ally can add their **real army** (lord, heroes, items, skills) to that same battle. The ally controls their army; casualties and experience are applied by the game.

It is perfect for **end-game battles**, such as the Archaon or Nagash ones, where both players can fight together with their own armies.

This repository publishes **all the source code** of the mod, including the native component `ceb_native_bridge.dll`, so anyone can review what it does and check that the published DLL comes from this code. All rights reserved: see [Rights](#rights).

### Why a DLL

The game builds the participant list of a mission battle once and never recalculates it. No script function, database table or UI context can add an army to a mission battle that already exists. The DLL calls the game's own functions that build battle participants to add the ally's army, the same way the game handles an allied army in a normal battle.

### What the DLL does and does not do

**It does:**
- It is loaded from the mod's script with `package.loadlib` (the Lua function the game leaves available).
- Before doing anything, it checks that the executable is **exactly** the analyzed one:
  - SHA-256 of `Warhammer3.exe` = `9bd58c63bd7fc5c9909b3d3d9b6b7a6ae4eac784369bf91a9e53c3e9f42be496`;
  - image size and timestamp of the executable;
  - 14 signatures of 24 bytes for the functions it uses ([`native_profile.json`](native_bridge/native_profile.json)).

  If anything differs (for example after a game update), it disables itself and the mod only reports that it is unavailable.
- It reads the pending battle structures, validates the chosen army and, if everything is correct, calls the game functions that create a participant. Then it asks the game to refresh the pending battle.
- Every memory read is checked first with `VirtualQuery`, and the calls are guarded with structured exception handling (SEH).

**It does not:**
- It does not modify game code: no instruction patches and no hooks. Mod code never calls `VirtualProtect`; it appears in the imports only because the static C runtime uses it.
- It does not inject into other processes or use injection APIs (`WriteProcessMemory`, `CreateRemoteThread`...).
- It does not use the network or touch copy protection. The only files it opens are `Warhammer3.exe` (to compute its SHA-256) and its own log, `coop_event_battles_native_log.txt`.
- It only imports `KERNEL32.dll` and `bcrypt.dll` (for SHA-256).

It exports three functions: `luaopen_ceb_native_bridge`, `ceb_bridge_abi_version` and `ceb_bridge_host_supported`. To Lua it exposes `status()`, `inspect()` (read-only) and `join()`.

#### Game functions it uses

| Name | RVA | Purpose |
|---|---|---|
| `allocate` / `release` | `0x4d3da0` / `0x4e98d4` | Allocate and free memory with the game's allocator |
| `construct_cohort` / `destroy_cohort` | `0x26687b4` / `0x2676658` | Create the participant for the allied faction |
| `append_cohort` | `0x2642468` | Add it to the host's side |
| `initialize_cohort` | `0x269af00` | Compute its deployment or arrival as reinforcements |
| `prepare_character` / `observe_force` | `0x26b5c78` / `0x1c3adf0` | Register the general and the army in the battle |
| `lookup_force` / `at_war` | `0x1c6a30c` / `0x26ba60c` | Find the army by its ID and check the factions are not at war |
| `reinforcement_direction` | `0x2692774` | Direction the army arrives from |
| `make_force_data` / `push_force_data` / `destroy_force_data` | `0x2669900` / `0x263f6b0` / `0x2676720` | Extra army of the same faction (single-player test only, disabled) |

### How the DLL reaches your PC

The Steam Workshop only distributes `.pack` files, so the DLL travels inside the pack as Lua text (`script/campaign/mod/coop_event_battles_native_blob.lua`, generated by [`build_pack.cjs`](native_bridge/build_pack.cjs)). When a multiplayer campaign loads, the script ([`network.inc.lua`](native_bridge/network.inc.lua)) does this:
1. Checks that the embedded DLL version matches the script version.
2. If `ceb_native_bridge.dll` is missing next to `Warhammer3.exe` or is different, writes it and reads it back to verify it.
3. Loads it with `package.loadlib`.

In single-player games the mod does nothing.

### Verify the DLL

After loading a co-op campaign with the mod, in PowerShell:

```powershell
Get-FileHash "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\ceb_native_bridge.dll" -Algorithm SHA256
```

The result must match the DLL SHA-256 published in the [release](https://github.com/Agus224/twwh3-coop-event-battles/releases) for that version. For version 1.1.2:

| File | SHA-256 |
|---|---|
| `ceb_native_bridge.dll` | `167e24e406b9462738c555aa14d1838beb900dea6a80c28f70f56799f74fe95e` |
| `coop_event_battles.pack` | `15d3ae3e59a5fa674ff5d67bec162eb1c6f9afb05fbb8772771a19427eccb214` |

[`release/1.1.2/native_build.json`](release/1.1.2/native_build.json) records the hash of the source files that DLL was built from. The GitHub Actions workflow builds the DLL from this code on every change and shows its hash.

Antivirus software may flag the DLL because it is not digitally signed.

### Build (to verify)

You can build the code on your own PC to check that it matches the published files.

Requirements: Windows, Visual Studio 2022 Build Tools (C++), Python 3 with `pefile` and `lupa`, Node.js.

```bat
cd native_bridge
compilar_y_validar.cmd
```

The script generates the Lua code, builds the DLL (`cl /O2 /MT`, reproducible linking with `/Brepro`) and runs the tests:
- the C core against a simulated engine ([`test_bridge_core.c`](native_bridge/test_bridge_core.c));
- the binary validation, which needs `Warhammer3.exe` in the game folder;
- the Lua logic ([`test_companion.py`](native_bridge/test_companion.py)).

Then it builds the pack and verifies the embedded DLL.

Building the `.pack` also needs a copy of the game's layout `ui/campaign ui/mp_pending_action_blocking_msg.twui.xml` (in `data/ui3.pack`; it can be extracted with [RPFM](https://github.com/Frodo45127/rpfm)). It is not included here because it is a Creative Assembly file. Copy it to `ui_src/` and apply the mod's change with:

```bat
python tools\patch_blocker_layout.py ui_src\mp_pending_action_blocking_msg.twui.xml
```

### Disclaimer

Unofficial mod, not affiliated with Creative Assembly or SEGA. The native component is based on analysis of the game executable. Use it at your own risk and try it on test saves first. If you do not want native code on your PC, do not install it.

### Rights

**All rights reserved.** You may play the mod and review the code. Do not modify, reupload, reuse or sell it without the author's permission.
