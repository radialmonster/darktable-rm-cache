# darktable cache helper

A darktable Lua helper plugin for inspecting and managing darktable thumbnail/cache behavior.

The first target is Windows, where darktable may resolve its cache directory to a path like:

```text
C:\Users\Owner\AppData\Local\Microsoft\Windows\INetCache\darktable
```

This project is meant to make that visible inside darktable and provide practical helper actions around thumbnail generation. It cannot change the active cache directory of an already-running darktable process; darktable initializes that path before Lua plugins load.

## Behavior

The UI lives under **settings → Lua options** (registered as a `lua`-type
preference whose widget is the panel); there is no separate lighttable lib
panel. Open Lua options to see the status and action buttons alongside the
plugin's configuration preferences.

- Show the active cache directory from `darktable.configuration.cache_dir`.
- Store a desired cache directory in Lua preferences.
- Warn when the desired cache directory differs from the active one.
- Build thumbnails for the whole library into the active cache using darktable's
  own in-process generator (`image:generate_cache`): runs in the background,
  works while darktable is open, and resumes/skips images already cached. A
  plain-language dropdown picks the largest thumbnail size to cache.
- Open the active or desired cache folder in Explorer (creating the desired folder if missing).
- Copy the exact darktable `--cachedir` startup command to the clipboard.
- Install a launcher (no typing required): a double-clickable **Desktop** icon plus
  a **Start Menu** entry named `darktable-dtrmcache`, both starting darktable with
  the desired `--cachedir`.
- Optionally move existing cache files from the active folder into the desired
  one, from an explicit **move active → desired** button behind a Yes/No
  confirmation. This is the only destructive action, is never automatic, and
  (because the running darktable keeps the active cache open) is cleanest with
  darktable closed.

## Important Constraint

darktable's cache location is a startup/core option:

```text
--cachedir <path>
```

The plugin can make this easier to see and use, but Lua cannot reinitialize the live cache root after darktable has started.

## Install

The plugin is a single self-contained file, `dtrmcache.lua` — no sibling files
are needed.

darktable 5.6 includes the Lua script manager, so no separate lua-scripts
install is needed.

In darktable's `scripts` widget:

1. Set `action` to `install/update scripts`.
2. Under `add more scripts`, paste this into `URL to download additional scripts from`:

   ```text
   https://github.com/radialmonster/darktable-rm-cache
   ```

3. Enter this in `new folder to place scripts in`:

   ```text
   dtrmcache
   ```

4. Click `install additional scripts`.
5. Change back to `start/stop scripts`, select the `dtrmcache` category, and
   click the power button next to `dtrmcache` to enable it.

The plugin's UI appears under **settings → Lua options → dtrmcache** after the
script is enabled. If the preferences window was already open, close and reopen
it (or restart darktable) after enabling.

### Manual install

To install one file by hand, download this script into darktable's Lua folder:

```text
https://raw.githubusercontent.com/radialmonster/darktable-rm-cache/main/dtrmcache.lua
```

A per-plugin subfolder matches the convention used by other scripts:

```text
C:\Users\Owner\AppData\Local\darktable\lua\dtrmcache\dtrmcache.lua
```

```text
# C:\Users\Owner\AppData\Local\darktable\luarc
require "dtrmcache/dtrmcache"
```

Targets darktable 5.6 (Lua API 9.x).

## Development

This repository contains only the built plugin for end users. The source code,
tests, build tooling, and roadmap live in the development repository:

```text
https://github.com/radialmonster/darktable-rm-cache-dev
```

`dtrmcache.lua` is generated there from the split sources and published here.
