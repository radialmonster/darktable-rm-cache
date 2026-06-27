--[[ GENERATED FILE - do not edit by hand.
     Built from plugins/dev/src/dtcache/{dtcache.lua,dtcache_core.lua}
     by tools/build-single-file.ps1. Edit the sources and rebuild. ]]

-- ===== embedded module: dtcache_core =====
package.preload["dtcache_core"] = function()
--[[
  dtcache_core.lua

  Pure helper logic for the darktable cache helper plugin.

  This module has NO dependency on the darktable Lua API, so it can be
  required directly from offline unit tests. All darktable interaction
  (widgets, preferences, command execution) lives in dtcache.lua.

  Everything here is string/path manipulation and command construction.
  Keep it side-effect free: no file IO, no os.execute, no darktable calls.
]]

local core = {}

-- ------------------------------------------------------------------
-- platform / path helpers
-- ------------------------------------------------------------------

-- darktable.configuration.running_os returns one of:
-- "windows", "macos", "linux", "unix"
function core.is_windows(os_name)
  return os_name == "windows"
end

-- Trim surrounding whitespace. Returns "" for nil. Also strips a leading
-- UTF-8 BOM (EF BB BF): Windows PowerShell's `Set-Content -Encoding UTF8`
-- prepends one, and if it rides into a path it corrupts the value (darktable
-- then treats the cache dir as relative). Defensive cleanup for any value
-- already saved before the helpers were switched to BOM-less output.
function core.trim(s)
  if s == nil then return "" end
  s = s:gsub("^\239\187\191", "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Sanitize a stored path value: trim, strip a BOM (via trim) and treat the
-- literal "(NULL)" as empty. darktable's GTK folder/file chooser returns the
-- string "(NULL)" when it cannot represent the stored path, and that string
-- can get saved back into the preference; this maps it back to "".
function core.sanitize_path(s)
  local p = core.trim(s)
  -- whole value is "(NULL)", or a path whose final segment is "(NULL)"
  -- (the chooser resolves "(NULL)" against the working dir before saving).
  if p:upper() == "(NULL)" then return "" end
  if p:upper():find("[/\\]%(NULL%)$") then return "" end
  return p
end

-- Normalize a path for comparison/use:
--   * trim whitespace
--   * drop a single trailing separator (but keep a bare root like "C:\")
function core.normalize(path)
  local p = core.trim(path)
  if p == "" then return "" end
  -- strip one trailing slash/backslash, but keep a bare drive root ("C:\"):
  -- stripping it would yield "C:", a drive-relative path, not the root.
  if #p > 1 and not p:match("^%a:[/\\]?$") then
    p = p:gsub("[/\\]$", "")
  end
  return p
end

-- True when two paths refer to different locations.
-- On Windows comparison is case-insensitive and separator-insensitive.
function core.paths_differ(active, desired, os_name)
  local a = core.normalize(active)
  local d = core.normalize(desired)
  if core.is_windows(os_name) then
    a = a:lower():gsub("/", "\\")
    d = d:lower():gsub("/", "\\")
  end
  return a ~= d
end

-- Double-quote a path for use as a shell argument.
-- Returns "" for an empty/nil path so callers can detect "no value".
-- An embedded double-quote is escaped (\") so the argument stays well-formed;
-- this never fires on Windows (" is illegal in paths) but guards POSIX names.
function core.quote(path)
  local p = core.trim(path)
  if p == "" then return "" end
  return '"' .. p:gsub('"', '\\"') .. '"'
end

-- ------------------------------------------------------------------
-- darktable executable auto-detection
-- ------------------------------------------------------------------

-- Likely install locations of darktable.exe, most-standard first. The caller
-- checks each for existence (this module stays IO-free).
function core.darktable_exe_candidates(os_name)
  if not core.is_windows(os_name) then
    return { "darktable" }  -- assume on PATH on macOS/Linux
  end
  return {
    "C:\\Program Files\\darktable\\bin\\darktable.exe",
    "C:\\Program Files (x86)\\darktable\\bin\\darktable.exe",
  }
end

-- PowerShell helper that locates darktable.exe via the installer's registry
-- entries (App Paths) and the common fixed locations, then writes the first
-- existing path to $OutFile (BOM-less). Used only when the fixed-location
-- probes in Lua come up empty (handles non-standard install drives).
function core.detect_script_contents()
  return [==[
param([string]$OutFile = "")
$paths = @()
foreach ($k in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\darktable.exe',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\darktable.exe')) {
  try { $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).'(default)'; if ($v) { $paths += $v } }
  catch { }
}
$paths += 'C:\Program Files\darktable\bin\darktable.exe'
$paths += 'C:\Program Files (x86)\darktable\bin\darktable.exe'
$found = $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($found -and $OutFile) {
  [System.IO.File]::WriteAllText($OutFile, $found, (New-Object System.Text.UTF8Encoding($false)))
}
]==]
end

-- Build the powershell invocation that runs the detect helper.
function core.detect_command(script_path, out_file)
  local sp = core.quote(script_path)
  local of = core.quote(out_file)
  if sp == "" or of == "" then return nil, "script and output paths are required" end
  return table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", sp, of,
  }, " ")
end

-- ------------------------------------------------------------------
-- thumbnail-size presets (friendly wrapper over generate-cache mip levels)
-- ------------------------------------------------------------------

-- darktable caches thumbnails at a range of "mipmap" sizes (mip 0 = ~180px up
-- to mip 10 = full size; see src/common/mipmap_cache.c). generate-cache takes
-- --min-mip/--max-mip to choose which sizes to pre-render. Those numbers mean
-- nothing to a normal user, so we expose a single plain-language choice of the
-- largest size to cache; min-mip is always 0 (generate every size up to it).
-- Labels lead with the actual pixel size of the largest cached thumbnail
-- (from the mipsizes table in src/common/mipmap_cache.c).
core.THUMB_PRESETS = {
  { label = "720 × 450 — lighttable grid (fastest, least disk)", max_mip = 2 },
  { label = "1440 × 900 — laptop / 720p",                        max_mip = 3 },
  { label = "1920 × 1200 — Full HD / 1080p",                     max_mip = 4 },
  { label = "2560 × 1600 — QHD / 1440p",                         max_mip = 5 },
  { label = "4096 × 2560 — 4K (sharpest, most disk)",            max_mip = 6 },
}

function core.preset_labels()
  local t = {}
  for i, p in ipairs(core.THUMB_PRESETS) do t[i] = p.label end
  return t
end

-- Largest mip level for a preset label (defaults to the first preset).
function core.max_mip_for_label(label)
  local l = core.trim(label)
  for _, p in ipairs(core.THUMB_PRESETS) do
    if p.label == l then return p.max_mip end
  end
  return core.THUMB_PRESETS[1].max_mip
end

-- 1-based index of a preset by its label (defaults to 1). Used to select the
-- combobox entry, since a non-editable combobox is selected by index, not text.
function core.preset_index_for_label(label)
  local l = core.trim(label)
  for i, p in ipairs(core.THUMB_PRESETS) do
    if p.label == l then return i end
  end
  return 1
end

-- ------------------------------------------------------------------
-- darktable startup / launcher construction
-- ------------------------------------------------------------------

-- The exact command a user should run to start darktable using the
-- desired cache directory.
function core.startup_command(darktable_exe, cachedir)
  local exe = core.trim(darktable_exe)
  local dir = core.trim(cachedir)
  if exe == "" then return nil, "darktable executable path is not set" end
  if dir == "" then return nil, "desired cache directory is not set" end
  return core.quote(exe) .. " --cachedir " .. core.quote(dir)
end

-- PowerShell helper that installs a launcher in two friendly, easy-to-find
-- places for a non-technical user:
--   1. a double-clickable .cmd on the Desktop
--   2. a Start Menu shortcut (so it appears in Start-menu search by name)
-- Both start darktable with the desired --cachedir. The created paths are
-- written to $OutFile so the caller can show them to the user.
function core.launcher_script_contents()
  return [==[
param([Parameter(Mandatory=$true)][string]$Exe,
      [Parameter(Mandatory=$true)][string]$CacheDir,
      [string]$Name = "darktable-dtrmcache",
      [string]$OutFile = "")

$desktop  = [Environment]::GetFolderPath('Desktop')
$programs = [Environment]::GetFolderPath('Programs')
$created  = @()

# 1) Double-clickable .cmd launcher on the Desktop.
$cmdPath = Join-Path $desktop ($Name + '.cmd')
$body = @(
  '@echo off',
  'rem Generated by dtrmcache - starts darktable with a specific cache directory.',
  ('start "" "' + $Exe + '" --cachedir "' + $CacheDir + '"')
)
Set-Content -LiteralPath $cmdPath -Value $body -Encoding Default
$created += $cmdPath

# 2) Start Menu shortcut (searchable by $Name, like the stock darktable entry).
$lnkPath = Join-Path $programs ($Name + '.lnk')
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath       = $Exe
$lnk.Arguments        = '--cachedir "' + $CacheDir + '"'
$lnk.WorkingDirectory = Split-Path -Parent $Exe
$lnk.IconLocation     = "$Exe,0"
$lnk.Description       = "darktable using cache dir $CacheDir"
$lnk.Save()
$created += $lnkPath

if ($OutFile) {
  [System.IO.File]::WriteAllText($OutFile, ($created -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
}
]==]
end

-- Build the powershell invocation that runs the launcher helper script.
-- Param order matches the script: Exe, CacheDir, Name, OutFile.
function core.launcher_install_command(script_path, exe, cachedir, name, out_file)
  local sp = core.quote(script_path)
  local ex = core.trim(exe)
  local cd = core.trim(cachedir)
  if sp == "" then return nil, "launcher script path is required" end
  if ex == "" then return nil, "darktable executable path is not set" end
  if cd == "" then return nil, "desired cache directory is not set" end
  local nm = core.trim(name)
  if nm == "" then nm = "darktable-dtrmcache" end
  local parts = {
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", sp,
    core.quote(ex), core.quote(cd), core.quote(nm),
  }
  local of = core.trim(out_file)
  if of ~= "" then parts[#parts + 1] = core.quote(of) end
  return table.concat(parts, " ")
end

-- ------------------------------------------------------------------
-- native Windows folder picker (PowerShell)
-- ------------------------------------------------------------------

-- The PowerShell script body that shows the modern Windows folder picker
-- (the big Explorer-style IFileOpenDialog with an address/path bar you can
-- type or paste into, plus a "New folder" button) and writes the chosen path
-- to out_file. Used instead of WinForms FolderBrowserDialog, which under
-- Windows PowerShell renders the old tree-only dialog with no path bar.
-- Written to a temp .ps1 and invoked via core.browse_command().
function core.browse_script_contents()
  return [==[
param([Parameter(Mandatory=$true)][string]$OutFile,
      [string]$Title = "Select folder",
      [string]$Start = "")

# Define just enough of the Vista+ common item dialog (IFileOpenDialog) to
# show a folder picker. The vtable method ORDER below is significant.
$code = @'
using System;
using System.Runtime.InteropServices;

public static class DtcacheFolderPicker
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialogRCW { }

    [ComImport, Guid("d57c7288-d4ad-4768-be02-9d969532d960"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes();
        void SetFileTypeIndex();
        void GetFileTypeIndex();
        void Advise();
        void Unadvise();
        void SetOptions(uint fos);
        void GetOptions(out uint fos);
        void SetDefaultFolder(IShellItem si);
        void SetFolder(IShellItem si);
        void GetFolder();
        void GetCurrentSelection();
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName();
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel();
        void SetFileNameLabel();
        void GetResult(out IShellItem si);
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler();
        void GetParent();
        [PreserveSig] int GetDisplayName(uint sigdn, out IntPtr ppsz);
        void GetAttributes();
        void Compare();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHCreateItemFromParsingName(
        string path, IntPtr bc, ref Guid riid, out IShellItem ppv);

    const uint FOS_PICKFOLDERS      = 0x20;
    const uint FOS_FORCEFILESYSTEM  = 0x40;
    const uint SIGDN_FILESYSPATH    = 0x80058000;

    public static string Pick(string title, string start)
    {
        var dlg = (IFileOpenDialog)(new FileOpenDialogRCW());
        uint opts;
        dlg.GetOptions(out opts);
        dlg.SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
        if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);
        if (!string.IsNullOrEmpty(start))
        {
            try
            {
                var iid = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
                IShellItem si;
                if (SHCreateItemFromParsingName(start, IntPtr.Zero, ref iid, out si) == 0)
                    dlg.SetFolder(si);
            }
            catch { }
        }
        if (dlg.Show(IntPtr.Zero) != 0) return null;  // cancelled
        IShellItem result;
        dlg.GetResult(out result);
        IntPtr pszPath;
        result.GetDisplayName(SIGDN_FILESYSPATH, out pszPath);
        string path = Marshal.PtrToStringUni(pszPath);
        Marshal.FreeCoTaskMem(pszPath);
        return path;
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp | Out-Null
$picked = [DtcacheFolderPicker]::Pick($Title, $Start)
# Write without a BOM: Set-Content -Encoding UTF8 (PS 5.1) prepends one, which
# would corrupt the path when read back.
if ($picked) {
  [System.IO.File]::WriteAllText($OutFile, $picked, (New-Object System.Text.UTF8Encoding($false)))
}
]==]
end

-- Command that runs the browse script. out_file receives the selection.
function core.browse_command(script_path, out_file, title, start_dir)
  local sp = core.quote(script_path)
  local of = core.quote(out_file)
  if sp == "" or of == "" then
    return nil, "script and output paths are required"
  end
  local parts = {
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", sp, of,
    core.quote(core.trim(title) ~= "" and title or "Select folder"),
  }
  local start = core.trim(start_dir)
  if start ~= "" then
    parts[#parts + 1] = core.quote(start)
  end
  return table.concat(parts, " ")
end

-- ------------------------------------------------------------------
-- open folder in the OS file manager
-- ------------------------------------------------------------------

function core.open_folder_command(path, os_name)
  -- normalize() drops a trailing separator: on Windows a quoted dir ending in
  -- "\" (e.g. explorer "D:\foo\") has its closing quote escaped by the
  -- backslash, which makes Explorer open the wrong folder.
  local dir = core.normalize(path)
  if dir == "" then return nil, "no folder to open" end
  if core.is_windows(os_name) then
    return "explorer " .. core.quote(dir)
  elseif os_name == "macos" then
    return "open " .. core.quote(dir)
  else
    return "xdg-open " .. core.quote(dir)
  end
end

-- Command that copies the *contents* of a text file to the system clipboard.
-- We copy from a file (rather than inline text) so command strings containing
-- quotes survive shell quoting intact. Windows single-quotes the path inside a
-- PowerShell -Command, so backslashes need no escaping.
function core.clipboard_command(path, os_name)
  local p = core.trim(path)
  if p == "" then return nil, "no file to copy" end
  if core.is_windows(os_name) then
    return 'powershell -NoProfile -Command "Set-Clipboard -Value '
      .. "([IO.File]::ReadAllText('" .. p .. "'))" .. '"'
  elseif os_name == "macos" then
    return "pbcopy < " .. core.quote(p)
  else
    return "xclip -selection clipboard -in " .. core.quote(p)
  end
end

-- Command that creates `path` only if it does not already exist. Used
-- before "open desired" so the folder picker target actually exists.
function core.make_dir_command(path, os_name)
  local dir = core.trim(path)
  if dir == "" then return nil, "no folder to create" end
  if core.is_windows(os_name) then
    local q = core.quote(dir)
    -- single cmd call; `if not exist` keeps it idempotent
    return "cmd /c if not exist " .. q .. " mkdir " .. q
  else
    return "mkdir -p " .. core.quote(dir)
  end
end

-- ------------------------------------------------------------------
-- move an existing cache folder to a new location
-- ------------------------------------------------------------------

-- Build a command that moves the contents of `src` into `dest`, creating
-- `dest` if needed. This is destructive on the source and must only be
-- run behind an explicit user confirmation (see core.confirm_* helpers).
-- Returns cmd, nil  or  nil, err.
--
-- NOTE on exit codes: on Windows this uses robocopy, whose success codes
-- are 0-7 (8+ means failure). Callers must treat rc < 8 as success.
function core.move_cache_command(src, dest, os_name)
  local s = core.normalize(src)
  local d = core.normalize(dest)
  if s == "" then return nil, "active cache directory is not set" end
  if d == "" then return nil, "desired cache directory is not set" end
  if not core.paths_differ(s, d, os_name) then
    return nil, "active and desired cache directories are the same"
  end
  if core.is_windows(os_name) then
    -- robocopy handles spaces and creates the destination tree.
    --   /E    copy all subdirs, including empty ones
    --   /MOVE delete source files+dirs after a successful copy
    --   /R:1 /W:1  retry once, wait 1s (don't hang on locked files)
    --   /NFL /NDL /NJH /NJS  quieter output
    return table.concat({
      "robocopy", core.quote(s), core.quote(d),
      "/E", "/MOVE", "/R:1", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS",
    }, " ")
  else
    -- copy contents (including dotfiles) then drop the old tree
    return "mkdir -p " .. core.quote(d)
      .. " && cp -a " .. core.quote(s) .. "/. " .. core.quote(d) .. "/"
      .. " && rm -rf " .. core.quote(s)
  end
end

-- ------------------------------------------------------------------
-- native Windows confirmation dialog (PowerShell MessageBox)
-- ------------------------------------------------------------------

-- PowerShell body for a Yes/No confirmation. Writes "yes" to OutFile
-- only when the user clicks Yes; otherwise leaves OutFile absent.
function core.confirm_script_contents()
  return table.concat({
    'param([Parameter(Mandatory=$true)][string]$OutFile,',
    '      [string]$Title = "Confirm",',
    '      [string]$Message = "Are you sure?")',
    'Add-Type -AssemblyName System.Windows.Forms | Out-Null',
    '$r = [System.Windows.Forms.MessageBox]::Show($Message, $Title,',
    '  [System.Windows.Forms.MessageBoxButtons]::YesNo,',
    '  [System.Windows.Forms.MessageBoxIcon]::Warning)',
    'if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {',
    -- write without a BOM (PS 5.1 -Encoding UTF8 adds one, breaking == "yes")
    '  [System.IO.File]::WriteAllText($OutFile, "yes", (New-Object System.Text.UTF8Encoding($false)))',
    '}',
  }, "\r\n") .. "\r\n"
end

-- Command that runs the confirm script. Keep `message` single-line: it is
-- passed as one shell argument.
function core.confirm_command(script_path, out_file, title, message)
  local sp = core.quote(script_path)
  local of = core.quote(out_file)
  if sp == "" or of == "" then
    return nil, "script and output paths are required"
  end
  return table.concat({
    "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", sp, of,
    core.quote(core.trim(title) ~= "" and title or "Confirm"),
    core.quote(core.trim(message) ~= "" and message or "Are you sure?"),
  }, " ")
end

-- ------------------------------------------------------------------
-- status / diagnostics text
-- ------------------------------------------------------------------

-- Build a short human-readable mismatch status used in the panel.
-- Returns: status_table { match=bool, message=string }
function core.cache_status(active, desired, os_name)
  local d = core.trim(desired)
  if d == "" then
    return { match = nil, message = "No desired cache directory set." }
  end
  if not core.paths_differ(active, desired, os_name) then
    return { match = true, message = "Active cache matches desired cache." }
  end
  return {
    match = false,
    message = "Active cache differs from desired. Restart darktable with "
      .. "--cachedir to use the desired location.",
  }
end

return core

end
-- ===== end embedded module =====
--[[
  dtcache.lua

  darktable cache helper plugin.

  Makes darktable's thumbnail/full-preview cache directory visible and gives
  practical helper actions around it on Windows. It CANNOT change the active
  cache directory of an already-running darktable process: darktable resolves
  --cachedir before Lua starts (see docs/darktable-src/src/common/darktable.c
  and src/common/file_location.c). Lua can only read the resolved value via
  darktable.configuration.cache_dir.

  What this plugin does instead:
    * show the active cache directory
    * store a desired cache directory as a plugin preference
    * warn when active and desired differ
    * build thumbnails for the whole library using darktable's own generator
    * write a .cmd launcher / print the exact startup command
    * open cache folders in the file manager

  The UI is hosted under settings -> Lua options (a "lua" preference whose
  widget is the panel); there is no lighttable lib panel.

  Install: copy this file (and dtcache_core.lua next to it) into
    C:\Users\Owner\AppData\Local\darktable\lua
  and enable it from the Lua script manager, or require it from luarc.
]]

local dt = require "darktable"
local core

-- Locate our own directory so we can require the sibling core module
-- regardless of where darktable loaded us from.
local function script_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("(.*[/\\])") or "./"
end

do
  local dir = script_dir()
  package.path = dir .. "?.lua;" .. package.path
  core = require "dtcache_core"
end

-- API compatibility marker. darktable 5.6 ships Lua API 9.7.0
-- (docs/darktable-src/src/lua/configuration.h). check_version validates when
-- the major matches and our requested minor is <= the running minor (the patch
-- is ignored), so we declare the minimum API we actually use. Everything this
-- plugin touches (preferences, widgets, control.execute/dispatch, register_lib)
-- is long-stable across the 9.x series, so 9.0.0 keeps us compatible from the
-- first API-9 release through 9.7 and any later 9.x.
dt.configuration.check_version(..., { 9, 0, 0 })

local PREF = "dtrmcache"  -- preferences namespace

-- ------------------------------------------------------------------
-- preference helpers
-- ------------------------------------------------------------------

local function pref_read(name, ptype)
  return dt.preferences.read(PREF, name, ptype)
end

local function default_exe(name)
  if core.is_windows(dt.configuration.running_os) then
    return "C:\\Program Files\\darktable\\bin\\" .. name
  end
  return name  -- assume on PATH elsewhere
end

-- Register user-facing preferences (shown in the Lua tab).
-- NOTE: desired_cache_dir is intentionally NOT registered here. It is set from
-- the panel's own entry + "browse…" button, and registering it as well would
-- show a duplicate row under Lua options. darktable can still read/write it as
-- an "invisible" preference (see get_desired/save_desired). We store it as a
-- plain string because the "directory" chooser cannot hold a not-yet-existing
-- path (it returns the literal "(NULL)", which then gets saved back).

-- NOTE: the darktable + generator executables are NOT registered as visible
-- "file" preferences. darktable renders those as file-chooser rows that get
-- stretched very tall on this page, and the user never needs to set them by
-- hand: they are auto-detected (see ensure_paths) and the resolved darktable
-- path is shown in the panel. They remain readable/writable invisible prefs.

-- The thumbnail size (min/max mip) is chosen from a plain-language dropdown in
-- the panel, not exposed as raw mip numbers here. The choice is persisted as an
-- invisible "thumb_preset" string preference (see get_max_mip below).

-- Convenience accessors reading current preference values.
local function get_desired()    return core.sanitize_path(pref_read("desired_cache_dir", "string")) end
local function get_darktable()
  local v = core.trim(pref_read("darktable_exe", "file"))
  return v ~= "" and v or default_exe("darktable.exe")
end
local function get_thumb_label()
  local l = core.trim(pref_read("thumb_preset", "string"))
  if l == "" then l = core.THUMB_PRESETS[1].label end
  return l
end
local function get_max_mip()    return core.max_mip_for_label(get_thumb_label()) end
local function active_cache()   return dt.configuration.cache_dir end

-- True when a file path exists on disk (core stays IO-free, so this lives here).
local function file_exists(p)
  if core.trim(p) == "" then return false end
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

-- Locate a real darktable.exe: the stored preference if it exists, else the
-- common install locations, else a registry probe. Returns "" if not found.
local function detect_darktable_exe()
  local pref = get_darktable()
  if file_exists(pref) then return pref end
  for _, cand in ipairs(core.darktable_exe_candidates(dt.configuration.running_os)) do
    if file_exists(cand) then return cand end
  end
  if core.is_windows(dt.configuration.running_os) then
    local script_path = dt.configuration.tmp_dir .. "\\dtrmcache_detect.ps1"
    local out_path = dt.configuration.tmp_dir .. "\\dtrmcache_detect_out.txt"
    local sf = io.open(script_path, "wb")
    if sf then
      sf:write(core.detect_script_contents())
      sf:close()
      os.remove(out_path)
      local cmd = core.detect_command(script_path, out_path)
      if cmd then dt.control.execute(cmd) end
      os.remove(script_path)  -- helper has served its purpose
      local of = io.open(out_path, "rb")
      if of then
        local p = core.trim(of:read("*a"))
        of:close()
        os.remove(out_path)
        if file_exists(p) then return p end
      end
    end
  end
  return ""
end

-- Fill in the darktable executable preference from auto-detection when the
-- stored one is missing, so non-technical users never touch paths. The exe is
-- only needed for the launcher shortcut; thumbnail generation uses darktable's
-- own in-process generator. Returns the resolved darktable exe ("" if none).
local function ensure_paths()
  local exe = detect_darktable_exe()
  if exe ~= "" and exe ~= get_darktable() then
    dt.preferences.write(PREF, "darktable_exe", "file", exe)
    dt.print_log("dtrmcache: detected darktable at " .. exe)
  end
  -- Scrub any previously-corrupted desired value (BOM / "(NULL)") by writing
  -- the sanitized version back to storage.
  dt.preferences.write(PREF, "desired_cache_dir", "string", get_desired())
  return exe
end

-- Forward declaration. offer_move is wired to the explicit "move active →
-- desired" button but defined later in the actions section (where its
-- dependencies confirm_dialog/run_async live); declaring it local up here keeps
-- it out of the global namespace.
local offer_move

-- ------------------------------------------------------------------
-- widgets
-- ------------------------------------------------------------------

local widgets = {}

local active_label = dt.new_widget("label") {
  label = "", selectable = true, halign = "start",
}
local desired_label = dt.new_widget("label") {
  label = "", selectable = true, halign = "start",
}
local status_label = dt.new_widget("label") {
  label = "", halign = "start",
}
local exe_label = dt.new_widget("label") {
  label = "", selectable = true, halign = "start",
}

local desired_entry = dt.new_widget("entry") {
  tooltip = "Desired cache directory. Saved to plugin preferences.",
  text = "",
}

-- Plain-language thumbnail-size dropdown (replaces the cryptic min/max mip).
-- The chosen preset is persisted as an invisible "thumb_preset" string pref.
local thumb_combo
do
  local def = {
    label = "thumbnail size to cache",
    tooltip = "How large a thumbnail to pre-render and store. Bigger looks "
      .. "sharper when you zoom in on the lighttable, but takes longer to "
      .. "generate and uses more disk. Pick the size closest to your screen.",
    changed_callback = function(w)
      dt.preferences.write(PREF, "thumb_preset", "string", w.value)
    end,
  }
  for i, label in ipairs(core.preset_labels()) do def[i] = label end
  thumb_combo = dt.new_widget("combobox")(def)
  -- A non-editable combobox is selected by index, not by text. Setting .value
  -- to a string would error and abort the whole script.
  thumb_combo.selected = core.preset_index_for_label(get_thumb_label())
end

-- Refresh all status text from current preferences/configuration.
local function refresh()
  local active = active_cache()
  local desired = get_desired()
  active_label.label  = "Active:  " .. (active ~= "" and active or "(unknown)")
  desired_label.label = "Desired: " .. (desired ~= "" and desired or "(not set)")
  desired_entry.text  = desired
  local st = core.cache_status(active, desired, dt.configuration.running_os)
  status_label.label = st.message

  local exe = get_darktable()
  if file_exists(exe) then
    exe_label.label = "darktable: " .. exe
  else
    exe_label.label = "darktable: NOT FOUND — click 'find darktable' or set it in preferences"
  end
end

-- Persist the entry text into the preference, then refresh. Saving only records
-- the desired location (for the launcher / status); moving existing cache files
-- is never implied here — that is the explicit "move active → desired" button,
-- so just recording a path can't surprise the user with a destructive prompt.
local function save_desired()
  local v = core.sanitize_path(desired_entry.text)
  dt.preferences.write(PREF, "desired_cache_dir", "string", v)
  refresh()
  dt.print_log("dtrmcache: saved desired cache dir = " .. (v ~= "" and v or "(empty)"))
end

-- ------------------------------------------------------------------
-- actions
-- ------------------------------------------------------------------

-- Run a command in the background so the UI stays responsive.
-- `is_ok(rc)` decides success; defaults to "exit code 0". robocopy needs a
-- custom predicate because its success codes are 0-7.
-- NOTE: dt.control.execute is system(), whose return is the raw exit code on
-- Windows but a wait-status on POSIX. The numeric predicates below assume the
-- Windows meaning; every current caller is Windows-only (robocopy), so that
-- holds — revisit is_ok if this is ever wired to a non-Windows command.
local function run_async(label, cmd, is_ok)
  is_ok = is_ok or function(rc) return rc == 0 end
  dt.print_toast("dtrmcache: " .. label .. " started")
  dt.print_log("dtrmcache: " .. label .. ": " .. cmd)
  dt.control.dispatch(function()
    local rc = dt.control.execute(cmd)
    if is_ok(rc) then
      dt.print_toast("dtrmcache: " .. label .. " finished")
    else
      dt.print_toast("dtrmcache: " .. label .. " failed (exit " .. tostring(rc) .. ")")
    end
    dt.print_log("dtrmcache: " .. label .. " exit code " .. tostring(rc))
  end)
end

-- robocopy reports success with exit codes 0-7.
local function robocopy_ok(rc) return type(rc) == "number" and rc < 8 end

-- Show a native Yes/No dialog (Windows only). Returns (answer_bool, err).
-- Mirrors browse_desired: write a temp .ps1, run it, read the result back.
local function confirm_dialog(title, message)
  if not core.is_windows(dt.configuration.running_os) then
    return false, "confirmation dialog is Windows-only"
  end
  local tmp = dt.configuration.tmp_dir
  local sep = "\\"
  local script_path = tmp .. sep .. "dtcache_confirm.ps1"
  local out_path = tmp .. sep .. "dtcache_confirm_out.txt"

  local sf = io.open(script_path, "wb")
  if not sf then return false, "could not write confirm helper" end
  sf:write(core.confirm_script_contents())
  sf:close()
  os.remove(out_path)

  local cmd, err = core.confirm_command(script_path, out_path, title, message)
  if not cmd then return false, err end
  dt.control.execute(cmd)  -- modal; blocks until the user answers
  os.remove(script_path)   -- helper has served its purpose

  local of = io.open(out_path, "rb")
  if not of then return false end  -- absent output == No/closed
  local ans = core.trim(of:read("*a"))
  of:close()
  os.remove(out_path)
  return ans == "yes"
end

-- Offer to move the existing cache from `from` into `to`, behind a
-- confirmation dialog. Destructive on the source and never automatic: it is
-- only reachable from the explicit "move active → desired" button.
--
-- Caveat surfaced to the user below: `from` is darktable's ACTIVE cache, which
-- the running process keeps open. robocopy skips locked files, so a move done
-- now generally relocates only part of the cache and leaves the rest in place
-- (a split cache). It is cleanest run while darktable is closed, or treated as
-- a pre-seed before relaunching with the desired --cachedir via the launcher.
function offer_move(from, to)
  local cmd, err = core.move_cache_command(from, to, dt.configuration.running_os)
  if not cmd then
    dt.print_toast("dtrmcache: " .. err)
    return
  end
  if not core.is_windows(dt.configuration.running_os) then
    dt.print_toast("dtrmcache: confirm-to-move is Windows-only; move the folder manually")
    return
  end
  local ok, derr = confirm_dialog("dtrmcache: move cache",
    "Move existing cache files from the active folder to the desired folder? "
      .. "darktable is using the active cache right now, so files it has open "
      .. "are left behind and the cache may end up split between both folders. "
      .. "For a clean move, do this with darktable closed. darktable keeps using "
      .. "the active folder until you relaunch it with the desired cache directory.")
  if derr then
    dt.print_toast("dtrmcache: " .. derr)
    return
  end
  if not ok then
    dt.print_toast("dtrmcache: move cancelled")
    return
  end
  run_async("move cache", cmd, robocopy_ok)
end

-- Build thumbnails for the whole library using darktable's own in-process
-- generator (image:generate_cache). Unlike the external darktable-generate-cache
-- tool this runs INSIDE darktable, so:
--   * it needs no exclusive database lock (darktable already holds it),
--   * it always targets darktable's active cache dir (no --cachedir needed),
--   * it skips images that already have a thumbnail on disk, so it RESUMES if
--     you stop/restart, and re-running is cheap.
-- Runs on a background job so the UI stays responsive.
local generating = false
local function generate_now()
  if generating then
    dt.print_toast("dtrmcache: thumbnail generation is already running")
    return
  end
  local max = get_max_mip()
  local db = dt.database
  local total = 0
  for _ in ipairs(db) do total = total + 1 end
  if total == 0 then
    dt.print_toast("dtrmcache: no images in the library")
    return
  end
  generating = true
  dt.print_toast("dtrmcache: building thumbnails for " .. total
    .. " images — you can keep working")
  dt.print_log("dtrmcache: generate_cache mip 0.." .. max .. " for " .. total .. " images")
  dt.control.dispatch(function()
    -- Wrap the whole job so an unexpected error can never leave `generating`
    -- stuck true (which would dead-lock the button until darktable restarts).
    local ok, err = pcall(function()
      local done, failed = 0, 0
      for i, img in ipairs(db) do
        -- check_dirs only needs to be true once: the mip cache directories are
        -- shared across all images, so create them on the first image only
        -- (see dt_lua_image_t:generate_cache docs) and skip the redundant
        -- per-image existence test thereafter.
        local gok = pcall(function() img:generate_cache(i == 1, 0, max) end)
        if not gok then failed = failed + 1 end
        done = done + 1
        if done % 25 == 0 then
          dt.print_toast("dtrmcache: thumbnails " .. done .. "/" .. total)
          dt.control.sleep(1)  -- yield briefly so the UI stays smooth
        end
      end
      local msg = "dtrmcache: thumbnails finished (" .. done .. "/" .. total .. ")"
      if failed > 0 then msg = msg .. ", " .. failed .. " skipped/failed" end
      dt.print_toast(msg)
      dt.print_log(msg)
    end)
    generating = false  -- always clear, even if the job errored out
    if not ok then
      dt.print_toast("dtrmcache: thumbnail generation stopped on an error")
      dt.print_log("dtrmcache: generate_cache error: " .. tostring(err))
    end
  end)
end

-- Native Windows folder picker: write a temp .ps1, run it, read the
-- chosen path back from a temp output file.
local function browse_desired()
  if not core.is_windows(dt.configuration.running_os) then
    dt.print_toast("dtrmcache: native browse is Windows-only; type the path instead")
    return
  end
  local tmp = dt.configuration.tmp_dir
  local sep = "\\"
  local script_path = tmp .. sep .. "dtcache_browse.ps1"
  local out_path = tmp .. sep .. "dtcache_browse_out.txt"

  -- (re)write the helper script and clear any previous output
  local sf = io.open(script_path, "wb")
  if not sf then
    dt.print_toast("dtrmcache: could not write browse helper")
    return
  end
  sf:write(core.browse_script_contents())
  sf:close()
  os.remove(out_path)

  local cmd, err = core.browse_command(script_path, out_path,
    "Select desired darktable cache directory", get_desired())
  if not cmd then
    dt.print_toast("dtrmcache: " .. err)
    return
  end

  dt.print_log("dtrmcache: browse: " .. cmd)
  dt.control.execute(cmd)  -- modal dialog; blocks until the user closes it
  os.remove(script_path)   -- helper has served its purpose

  local of = io.open(out_path, "rb")
  if not of then
    dt.print_toast("dtrmcache: folder selection cancelled")
    return
  end
  local chosen = core.trim(of:read("*a"))
  of:close()
  os.remove(out_path)

  if chosen == "" then
    dt.print_toast("dtrmcache: folder selection cancelled")
    return
  end
  desired_entry.text = chosen
  save_desired()
end

-- Install a Desktop launcher + a Start Menu shortcut named "darktable-dtrmcache"
-- that start darktable with the desired --cachedir. Aimed at non-technical
-- users: nothing to type, just double-click the Desktop icon or search the
-- Start menu.
local function write_launcher()
  if not core.is_windows(dt.configuration.running_os) then
    dt.print_toast("dtrmcache: the Desktop/Start Menu launcher is Windows-only")
    return
  end
  local exe = get_darktable()
  local desired = get_desired()
  if core.trim(exe) == "" then
    dt.print_toast("dtrmcache: set the darktable executable in preferences first")
    return
  end
  if desired == "" then
    dt.print_toast("dtrmcache: set a desired cache directory first")
    return
  end

  local tmp = dt.configuration.tmp_dir .. "\\"
  local script_path = tmp .. "dtrmcache_launcher.ps1"
  local out_path = tmp .. "dtrmcache_launcher_out.txt"

  local sf = io.open(script_path, "wb")
  if not sf then
    dt.print_toast("dtrmcache: could not write launcher helper")
    return
  end
  sf:write(core.launcher_script_contents())
  sf:close()
  os.remove(out_path)

  local cmd, err = core.launcher_install_command(
    script_path, exe, desired, "darktable-dtrmcache", out_path)
  if not cmd then
    dt.print_toast("dtrmcache: " .. err)
    return
  end
  dt.print_log("dtrmcache: install launcher: " .. cmd)
  dt.control.execute(cmd)
  os.remove(script_path)  -- helper has served its purpose

  local of = io.open(out_path, "rb")
  if of then
    local paths = core.trim(of:read("*a"))
    of:close()
    os.remove(out_path)
    dt.print_toast("dtrmcache: added a Desktop icon and a 'darktable-dtrmcache' Start Menu entry")
    dt.print_log("dtrmcache: launcher created:\n" .. paths)
  else
    dt.print_toast("dtrmcache: could not create the launcher")
  end
end

local function copy_startup_command()
  local cmd, err = core.startup_command(get_darktable(), get_desired())
  if not cmd then
    dt.print_toast("dtrmcache: " .. err)
    return
  end
  -- darktable has no clipboard API, so write the command to a temp file and
  -- shell out to copy its contents to the clipboard.
  local tmp = dt.configuration.tmp_dir .. "\\dtrmcache_startup.txt"
  local f = io.open(tmp, "wb")
  local wrote = false
  if f then f:write(cmd); f:close(); wrote = true end
  local clip, cerr = core.clipboard_command(tmp, dt.configuration.running_os)
  if clip and wrote then
    dt.control.execute(clip)
    dt.print_toast("dtrmcache: startup command copied to clipboard")
  else
    dt.print_toast("dtrmcache: " .. (cerr or "could not copy to clipboard"))
  end
  -- also log it as a fallback for copy/paste
  dt.print_log("dtrmcache startup command:\n" .. cmd)
end

-- Re-run auto-detection on demand and report the result in plain language.
local function find_darktable()
  local exe = ensure_paths()
  refresh()
  if exe ~= "" then
    dt.print_toast("dtrmcache: found darktable at " .. exe)
  else
    dt.print_toast("dtrmcache: could not find darktable.exe — set it in preferences")
  end
end

local function open_folder(use_desired)
  local dir = use_desired and get_desired() or active_cache()
  -- The desired folder may not exist yet; create it so Explorer opens something.
  if use_desired and core.trim(dir) ~= "" then
    local mk = core.make_dir_command(dir, dt.configuration.running_os)
    if mk then dt.control.execute(mk) end
  end
  local cmd, err = core.open_folder_command(dir, dt.configuration.running_os)
  if not cmd then
    dt.print_toast("dtrmcache: " .. err)
    return
  end
  dt.control.execute(cmd)
end

-- ------------------------------------------------------------------
-- build the panel widget (embedded in the Lua options page)
-- ------------------------------------------------------------------

local function button(label, tip, cb)
  return dt.new_widget("button") {
    label = label, tooltip = tip, clicked_callback = cb,
  }
end

ensure_paths()  -- auto-fill exe/generator paths before first display
refresh()

-- Two buttons side by side in one row, to keep the panel compact.
local function row(a, b)
  return dt.new_widget("box") { orientation = "horizontal", a, b }
end

local container = dt.new_widget("box") {
  orientation = "vertical",

  -- status (compact: four labels, no section header)
  active_label,
  desired_label,
  status_label,
  exe_label,

  -- desired cache entry + actions, all in paired rows
  desired_entry,
  row(
    button("browse…", "Pick a folder with the native Windows dialog", browse_desired),
    button("save", "Save the desired cache directory to preferences", save_desired)),
  row(
    button("find darktable", "Auto-detect the darktable program location", find_darktable),
    button("refresh", "Re-read active cache and preferences", refresh)),
  thumb_combo,
  button("generate thumbnails now",
    "Build thumbnails for your whole library into the active cache, using "
      .. "darktable itself. Runs in the background, works while darktable is "
      .. "open, and skips images already done (so it resumes if interrupted).",
    generate_now),
  row(
    button("make start menu shortcut",
      "Create a Start Menu shortcut and a Desktop icon that start darktable with the desired cache directory",
      write_launcher),
    button("copy launch command",
      "Copy the exact darktable --cachedir startup command to the clipboard",
      copy_startup_command)),
  row(
    button("open active", "Open the active cache folder", function() open_folder(false) end),
    button("open desired", "Open the desired cache folder", function() open_folder(true) end)),
  button("move active → desired",
    "Move existing cache files from the active folder to the desired folder (asks first)",
    function() offer_move(active_cache(), get_desired()) end),
}
widgets.container = container

-- ------------------------------------------------------------------
-- host the panel under settings -> Lua options
-- ------------------------------------------------------------------

-- A "lua" preference embeds a custom widget straight into the Lua options
-- page, so there is no lighttable lib panel. set_callback fires whenever
-- that page is shown, which we use to refresh the status labels from the
-- current configuration.
dt.preferences.register(PREF, "panel", "lua",
  "dtrmcache: cache helper",
  "Status and actions for darktable's thumbnail/full-preview cache.",
  "",          -- default value (unused; the widget itself is the UI)
  container,
  function(widget) refresh() end)

-- script_manager return contract
local script_data = {}
script_data.metadata = {
  name = "dtrmcache",
  purpose = "Inspect and manage darktable's thumbnail/full-preview cache",
  author = "darktable-cache",
}
-- The panel lives in the preferences dialog, which darktable manages, so
-- there is no lib to show/hide. Keep the hooks as safe no-ops.
script_data.destroy = function() end
script_data.restart = function() end
script_data.show = function() end
script_data.destroy_method = "hide"

return script_data
