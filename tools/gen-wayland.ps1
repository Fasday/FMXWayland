<#
.SYNOPSIS
  A small wayland-scanner for Object Pascal: Wayland protocol XML -> Delphi units.

.DESCRIPTION
  For every protocol XML (default: protocols\*.xml) writes src\Protocols\FMXWayland.Protocol.<Name>.pas with what
  wayland-scanner emits for C (client side):

  - the wl_interface tables (name, version, requests and events as wl_message: name, signature with the "since"
    version prefix and "?" for nullable arguments, and the types arrays: a shared run of NULLs for messages without
    object arguments, then one entry per signature argument for the others - the layout of wayland-scanner's
    <protocol>_types[]). They are variables filled in the unit's initialization (Pascal typed constants cannot refer
    to each other in a cycle);
  - opaque proxy types P<interface> (records without fields);
  - constants: enum entries (<INTERFACE>_<ENUM>_<ENTRY>), request opcodes (<INTERFACE>_<REQUEST>_OPCODE - not
    <INTERFACE>_<REQUEST> as in C: Pascal identifiers are case-insensitive and would clash with the wrapper functions),
    <..>_SINCE_VERSION;
  - typed request wrappers <interface>_<request> over FMXWayland.Wayland.WlProxyMarshalFlags (wl_proxy_marshal_flags
    with the argument array instead of C varargs); constructors return the new proxy, destructors pass
    WL_MARSHAL_FLAG_DESTROY; plus <interface>_add_listener/_set_user_data/_get_user_data/_get_version and _destroy
    when the interface has no destroy request (as in C);
  - listener records T<interface>_listener with one cdecl procedure field per event.

  The generated units are committed (they are derived from the MIT-licensed XML files in protocols\, whose copyright
  notices they repeat). Run the script again after adding or updating an XML file.

.EXAMPLE
  .\tools\gen-wayland.ps1
#>
param(
  [string[]] $Xml = @(),
  [string] $OutDir = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
if (-not $Xml -or $Xml.Count -eq 0) { $Xml = @(Get-ChildItem (Join-Path $Root 'protocols') -Filter '*.xml' | ForEach-Object FullName) }
if (-not $OutDir) { $OutDir = Join-Path $Root 'src\Protocols' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Reserved = @('and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const', 'constructor', 'destructor',
  'dispinterface', 'div', 'do', 'downto', 'else', 'end', 'except', 'exports', 'file', 'finalization', 'finally', 'for',
  'function', 'goto', 'if', 'implementation', 'in', 'inherited', 'initialization', 'inline', 'interface', 'is', 'label',
  'library', 'mod', 'nil', 'not', 'object', 'of', 'or', 'out', 'packed', 'procedure', 'program', 'property', 'raise',
  'record', 'repeat', 'resourcestring', 'set', 'shl', 'shr', 'string', 'then', 'threadvar', 'to', 'try', 'type', 'unit',
  'until', 'uses', 'var', 'while', 'with', 'xor')

function Pascalize([string] $s) {
  (($s -split '_') | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join ''
}
function Field([string] $s) { if ($Reserved -contains $s.ToLower()) { "&$s" } else { $s } }
function XmlDoc([string] $s) {
  $s = ($s -replace '\s+', ' ').Trim()
  $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}
function Summary($node) {
  $d = $node.SelectSingleNode('description')
  if ($d -and $d.GetAttribute('summary')) { return XmlDoc $d.GetAttribute('summary') }
  return ''
}

# ---- pass 1: model of all protocols ----
$protocols = @()
$ifaceUnit = @{}
foreach ($file in $Xml) {
  [xml] $doc = Get-Content -Raw -Encoding UTF8 $file
  $p = $doc.protocol
  $unitName = 'FMXWayland.Protocol.' + (Pascalize $p.name)
  $ifaces = @()
  foreach ($i in $p.SelectNodes('interface')) {
    $msgs = @{ request = @(); event = @() }
    foreach ($kind in 'request', 'event') {
      foreach ($m in $i.SelectNodes($kind)) {
        $alist = @()
        foreach ($a in $m.SelectNodes('arg')) {
          $alist += [pscustomobject]@{
            Name = $a.GetAttribute('name'); Type = $a.GetAttribute('type'); Iface = $a.GetAttribute('interface')
            AllowNull = ($a.GetAttribute('allow-null') -eq 'true'); Summary = (XmlDoc $a.GetAttribute('summary'))
          }
        }
        $since = 1
        if ($m.GetAttribute('since')) { $since = [int]$m.GetAttribute('since') }
        $msgs[$kind] += [pscustomobject]@{
          Name = $m.GetAttribute('name'); Since = $since; Destructor = ($m.GetAttribute('type') -eq 'destructor')
          Args = $alist; Summary = (Summary $m)
        }
      }
    }
    $enums = @()
    foreach ($e in $i.SelectNodes('enum')) {
      $entries = @()
      foreach ($en in $e.SelectNodes('entry')) {
        $since = 1
        if ($en.GetAttribute('since')) { $since = [int]$en.GetAttribute('since') }
        $entries += [pscustomobject]@{ Name = $en.GetAttribute('name'); Value = $en.GetAttribute('value'); Since = $since
          Summary = (XmlDoc $en.GetAttribute('summary')) }
      }
      $enums += [pscustomobject]@{ Name = $e.GetAttribute('name'); Entries = $entries; Summary = (Summary $e) }
    }
    $ifaces += [pscustomobject]@{
      Name = $i.GetAttribute('name'); Version = [int]$i.GetAttribute('version'); Requests = $msgs['request']
      Events = $msgs['event']; Enums = $enums; Summary = (Summary $i)
    }
    $ifaceUnit[$i.GetAttribute('name')] = $unitName
  }
  $copyright = ''
  if ($p.copyright) { $copyright = $p.copyright.Trim() }
  $protocols += [pscustomobject]@{ Name = $p.name; Unit = $unitName; File = (Split-Path $file -Leaf); Ifaces = $ifaces
    Copyright = $copyright }
}

function PasType($arg) {
  switch ($arg.Type) {
    'int' { 'Int32' }
    'uint' { 'UInt32' }
    'fixed' { 'Twl_fixed' }
    'string' { 'PAnsiChar' }
    'object' { if ($arg.Iface) { "P$($arg.Iface)" } else { 'Pointer' } }
    'new_id' { if ($arg.Iface) { "P$($arg.Iface)" } else { 'Pointer' } }
    'array' { 'Pwl_array' }
    'fd' { 'Int32' }
    default { throw "unknown argument type $($arg.Type)" }
  }
}
function ArgLetter($arg) {
  switch ($arg.Type) {
    'int' { 'i' } 'uint' { 'u' } 'fixed' { 'f' } 'string' { 's' } 'object' { 'o' } 'array' { 'a' } 'fd' { 'h' }
    'new_id' { if ($arg.Iface) { 'n' } else { 'sun' } }
  }
}
# Unique "A<Name>" parameter names (Pascal is case-insensitive).
function ParamNames([string[]] $taken, $list) {
  $used = @{}
  foreach ($t in $taken) { $used[$t.ToLower()] = $true }
  $names = @()
  foreach ($a in $list) {
    $n = 'A' + (Pascalize $a.Name)
    $k = 1
    while ($used.ContainsKey($n.ToLower())) { $n = 'A' + (Pascalize $a.Name) + $k; $k++ }
    $used[$n.ToLower()] = $true
    $names += $n
  }
  , $names
}

# ---- pass 2: units ----
foreach ($p in $protocols) {
  $sb = New-Object Text.StringBuilder
  function L([string] $s = '') { [void]$sb.Append($s).Append("`r`n") }

  $deps = @{}
  foreach ($i in $p.Ifaces) {
    foreach ($m in @($i.Requests) + @($i.Events)) {
      foreach ($a in $m.Args) {
        if ($a.Iface) {
          if (-not $ifaceUnit.ContainsKey($a.Iface)) { throw "$($p.File): unknown interface $($a.Iface)" }
          $u = $ifaceUnit[$a.Iface]
          if ($u -ne $p.Unit) { $deps[$u] = $true }
        }
      }
    }
  }

  L "// GENERATED by FMXWayland tools\gen-wayland.ps1 from protocols\$($p.File). Do not edit."
  L "// Protocol ""$($p.Name)"". The copyright and license of the protocol description:"
  L '//'
  foreach ($cl in ($p.Copyright -split "`r?`n")) { L (('//   ' + $cl.Trim()).TrimEnd()) }
  L ''
  L "/// <summary>Client binding of the Wayland protocol ""$($p.Name)"".</summary>"
  L "unit $($p.Unit);"
  L ''
  L 'interface'
  L ''
  L '{$MINENUMSIZE 4}'
  L ''
  L 'uses'
  $usesList = @('FMXWayland.Wayland') + @($deps.Keys | Sort-Object)
  L ('  ' + ($usesList -join ', ') + ';')
  L ''
  L 'type'
  foreach ($i in $p.Ifaces) {
    if ($i.Name -eq 'wl_display') {
      L "  Pwl_display = FMXWayland.Wayland.Pwl_display;"
      continue
    }
    if ($i.Summary) { L "  /// <summary>$($i.Name): $($i.Summary)</summary>" }
    L "  T$($i.Name) = record"
    L '  end;'
    L "  P$($i.Name) = ^T$($i.Name);"
  }
  L ''

  # Constants.
  $constNames = @{}
  L 'const'
  foreach ($i in $p.Ifaces) {
    $IU = $i.Name.ToUpper()
    foreach ($e in $i.Enums) {
      if ($e.Summary) { L "  // $($i.Name).$($e.Name): $($e.Summary)" }
      foreach ($en in $e.Entries) {
        $v = $en.Value
        if ($v -match '^0x([0-9a-fA-F]+)$') { $v = '$' + $Matches[1] }
        $cn = "$($IU)_$($e.Name.ToUpper())_$($en.Name.ToUpper())"
        L "  $cn = $v;"
        if ($en.Since -gt 1) { L "  $($cn)_SINCE_VERSION = $($en.Since);" }
      }
    }
    $op = 0
    foreach ($m in $i.Requests) {
      L "  $($IU)_$($m.Name.ToUpper())_OPCODE = $op;"
      $op++
    }
    foreach ($m in @($i.Requests) + @($i.Events)) {
      $cn = "$($IU)_$($m.Name.ToUpper())_SINCE_VERSION"
      if ($constNames.ContainsKey($cn)) {
        if ($constNames[$cn] -ne $m.Since) { $cn = "$($IU)_$($m.Name.ToUpper())_EVENT_SINCE_VERSION" } else { continue }
      }
      $constNames[$cn] = $m.Since
      L "  $cn = $($m.Since);"
    }
  }
  L ''

  # Listener records.
  $hasListeners = @($p.Ifaces | Where-Object { $_.Events.Count -gt 0 }).Count -gt 0
  if ($hasListeners) {
    L 'type'
    foreach ($i in $p.Ifaces) {
      if ($i.Events.Count -eq 0) { continue }
      $self = 'A' + (Pascalize $i.Name)
      L "  /// <summary>Events of $($i.Name) (wl_proxy_add_listener): every field must be assigned.</summary>"
      L "  T$($i.Name)_listener = record"
      foreach ($m in $i.Events) {
        $names = ParamNames @('AData', $self) $m.Args
        $params = @('AData: Pointer', "$($self): P$($i.Name)")
        for ($k = 0; $k -lt $m.Args.Count; $k++) { $params += "$($names[$k]): $(PasType $m.Args[$k])" }
        if ($m.Summary) { L "    /// <summary>$($m.Summary)</summary>" }
        L "    $(Field $m.Name): procedure($($params -join '; ')); cdecl;"
      }
      L '  end;'
      L "  P$($i.Name)_listener = ^T$($i.Name)_listener;"
    }
    L ''
  }

  L 'var'
  foreach ($i in $p.Ifaces) { L "  $($i.Name)_interface: Twl_interface;" }
  L ''

  # Declarations of the functions (and remember their bodies).
  $bodies = New-Object Text.StringBuilder
  function B([string] $s = '') { [void]$bodies.Append($s).Append("`r`n") }
  foreach ($i in $p.Ifaces) {
    $self = 'A' + (Pascalize $i.Name)
    $pt = "P$($i.Name)"
    $proxy = "Pwl_proxy($self)"
    if ($i.Events.Count -gt 0) {
      $h = "function $($i.Name)_add_listener($($self): $pt; AListener: P$($i.Name)_listener; AData: Pointer): Integer;"
      L $h
      B $h; B 'begin'; B "  Result := wl_proxy_add_listener($proxy, AListener, AData);"; B 'end;'; B
    }
    if ($i.Name -ne 'wl_display') {
      $h = "procedure $($i.Name)_set_user_data($($self): $pt; AUserData: Pointer);"
      L $h; B $h; B 'begin'; B "  wl_proxy_set_user_data($proxy, AUserData);"; B 'end;'; B
      $h = "function $($i.Name)_get_user_data($($self): $pt): Pointer;"
      L $h; B $h; B 'begin'; B "  Result := wl_proxy_get_user_data($proxy);"; B 'end;'; B
      $h = "function $($i.Name)_get_version($($self): $pt): UInt32;"
      L $h; B $h; B 'begin'; B "  Result := wl_proxy_get_version($proxy);"; B 'end;'; B
      if (-not ($i.Requests | Where-Object { $_.Name -eq 'destroy' })) {
        $h = "procedure $($i.Name)_destroy($($self): $pt);"
        L $h; B $h; B 'begin'; B "  wl_proxy_destroy($proxy);"; B 'end;'; B
      }
    }
    $op = 0
    foreach ($m in $i.Requests) {
      $names = ParamNames @($self, 'AInterface', 'AVersion') $m.Args
      $params = @("$($self): $pt")
      $newId = $null
      $untyped = $false
      for ($k = 0; $k -lt $m.Args.Count; $k++) {
        $a = $m.Args[$k]
        if ($a.Type -eq 'new_id') {
          $newId = $a
          if (-not $a.Iface) { $untyped = $true; $params += 'AInterface: Pwl_interface'; $params += 'AVersion: UInt32' }
          continue
        }
        $params += "$($names[$k]): $(PasType $a)"
      }
      $fname = "$($i.Name)_$($m.Name)"
      if ($newId) {
        $ret = if ($untyped) { 'Pointer' } else { "P$($newId.Iface)" }
        $h = "function $fname($($params -join '; ')): $ret;"
      } else {
        $h = "procedure $fname($($params -join '; '));"
      }
      if ($m.Summary) { L "/// <summary>$($i.Name).$($m.Name): $($m.Summary)</summary>" }
      L $h
      $slots = 0
      foreach ($a in $m.Args) { if ($a.Type -eq 'new_id' -and -not $a.Iface) { $slots += 3 } else { $slots += 1 } }
      B $h
      B 'var'
      B "  LArgs: array[0..$([Math]::Max($slots, 1) - 1)] of Twl_argument;"
      B 'begin'
      B '  FillChar(LArgs, SizeOf(LArgs), 0);'
      $s = 0
      for ($k = 0; $k -lt $m.Args.Count; $k++) {
        $a = $m.Args[$k]
        $n = $names[$k]
        switch ($a.Type) {
          'int' { B "  LArgs[$s].i := $n;" }
          'uint' { B "  LArgs[$s].u := $n;" }
          'fixed' { B "  LArgs[$s].f := $n;" }
          'string' { B "  LArgs[$s].s := $n;" }
          'object' { B "  LArgs[$s].o := $n;" }
          'array' { B "  LArgs[$s].a := $n;" }
          'fd' { B "  LArgs[$s].h := $n;" }
          'new_id' {
            if (-not $a.Iface) {
              B "  LArgs[$s].s := AInterface^.name;"
              B "  LArgs[$($s + 1)].u := AVersion;"
              $s += 2
            }
            B "  LArgs[$s].o := nil;"
          }
        }
        $s++
      }
      $flags = if ($m.Destructor) { 'WL_MARSHAL_FLAG_DESTROY' } else { '0' }
      $opc = "$($i.Name.ToUpper())_$($m.Name.ToUpper())_OPCODE"
      if ($newId) {
        if ($untyped) {
          B "  Result := WlProxyMarshalFlags($proxy, $opc, AInterface, AVersion, $flags, @LArgs[0]);"
        } else {
          B "  Result := P$($newId.Iface)(WlProxyMarshalFlags($proxy, $opc, @$($newId.Iface)_interface,"
          B "    wl_proxy_get_version($proxy), $flags, @LArgs[0]));"
        }
      } else {
        B "  WlProxyMarshalFlags($proxy, $opc, nil, wl_proxy_get_version($proxy), $flags, @LArgs[0]);"
      }
      B 'end;'
      B
      $op++
    }
    L ''
  }

  # The tables.
  $nullRun = 0
  $typeEntries = New-Object System.Collections.ArrayList
  $msgTypeIndex = @{}
  foreach ($i in $p.Ifaces) {
    foreach ($kind in 'Requests', 'Events') {
      $idx = 0
      foreach ($m in $i.$kind) {
        $entries = @()
        $allNull = $true
        foreach ($a in $m.Args) {
          if ($a.Type -eq 'new_id' -and -not $a.Iface) { $entries += 'nil', 'nil', 'nil' }
          elseif (($a.Type -eq 'object' -or $a.Type -eq 'new_id') -and $a.Iface) { $entries += "@$($a.Iface)_interface"; $allNull = $false }
          else { $entries += 'nil' }
        }
        $key = "$($i.Name)|$kind|$idx"
        if ($allNull) {
          $nullRun = [Math]::Max($nullRun, $entries.Count)
          $msgTypeIndex[$key] = -1
        } else {
          $msgTypeIndex[$key] = $typeEntries.Count
          foreach ($en in $entries) { [void]$typeEntries.Add($en) }
        }
        $idx++
      }
    }
  }
  $typesName = "$($p.Name)_types"
  $typesCount = $nullRun + $typeEntries.Count

  L 'implementation'
  L ''
  L 'var'
  L "  $($typesName): array[0..$([Math]::Max($typesCount, 1) - 1)] of Pwl_interface;"
  foreach ($i in $p.Ifaces) {
    if ($i.Requests.Count -gt 0) { L "  $($i.Name)_requests: array[0..$($i.Requests.Count - 1)] of Twl_message;" }
    if ($i.Events.Count -gt 0) { L "  $($i.Name)_events: array[0..$($i.Events.Count - 1)] of Twl_message;" }
  }
  L ''
  L 'procedure InitInterfaces;'
  L 'begin'
  for ($k = 0; $k -lt $typeEntries.Count; $k++) {
    if ($typeEntries[$k] -ne 'nil') { L "  $typesName[$($nullRun + $k)] := $($typeEntries[$k]);" }
  }
  foreach ($i in $p.Ifaces) {
    foreach ($kind in 'Requests', 'Events') {
      $arr = if ($kind -eq 'Requests') { "$($i.Name)_requests" } else { "$($i.Name)_events" }
      $idx = 0
      foreach ($m in $i.$kind) {
        $sig = ''
        if ($m.Since -gt 1) { $sig += "$($m.Since)" }
        foreach ($a in $m.Args) { if ($a.AllowNull) { $sig += '?' }; $sig += (ArgLetter $a) }
        $ti = $msgTypeIndex["$($i.Name)|$kind|$idx"]
        $tpos = if ($ti -lt 0) { 0 } else { $nullRun + $ti }
        L "  $arr[$idx].name := '$($m.Name)';"
        L "  $arr[$idx].signature := '$sig';"
        L "  $arr[$idx].types := @$typesName[$tpos];"
        $idx++
      }
    }
    L "  $($i.Name)_interface.name := '$($i.Name)';"
    L "  $($i.Name)_interface.version := $($i.Version);"
    L "  $($i.Name)_interface.method_count := $($i.Requests.Count);"
    if ($i.Requests.Count -gt 0) { L "  $($i.Name)_interface.methods := @$($i.Name)_requests[0];" }
    else { L "  $($i.Name)_interface.methods := nil;" }
    L "  $($i.Name)_interface.event_count := $($i.Events.Count);"
    if ($i.Events.Count -gt 0) { L "  $($i.Name)_interface.events := @$($i.Name)_events[0];" }
    else { L "  $($i.Name)_interface.events := nil;" }
  }
  L 'end;'
  L ''
  [void]$sb.Append($bodies.ToString())
  L 'initialization'
  L '  InitInterfaces;'
  L 'end.'

  $outFile = Join-Path $OutDir "$($p.Unit).pas"
  [IO.File]::WriteAllText($outFile, $sb.ToString(), (New-Object Text.UTF8Encoding $true))
  Write-Host "$($p.File) -> $outFile ($($p.Ifaces.Count) interfaces)"
}
