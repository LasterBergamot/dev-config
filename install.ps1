# Windows launcher for install.sh. Finds the bash that ships with Git for Windows (not the WSL
# bash.exe in System32, which would install into a different home folder) and passes the
# arguments through. Usage: .\install.ps1 [--list | --all | --only a,b | --skip a,b | --dry-run | --yes]

$ErrorActionPreference = 'Stop'

$bash = $null
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    # git.exe sits in <root>\cmd or <root>\mingw64\bin; bash.exe in <root>\bin or <root>\usr\bin.
    $dir = Split-Path $git.Source
    $root = Split-Path $dir
    if ((Split-Path $dir -Leaf) -eq 'bin' -and (Split-Path $root -Leaf) -like 'mingw*') { $root = Split-Path $root }
    foreach ($rel in 'bin\bash.exe', 'usr\bin\bash.exe') {
        $candidate = Join-Path $root $rel
        if (Test-Path -LiteralPath $candidate) { $bash = $candidate; break }
    }
}
if (-not $bash) {
    foreach ($root in "$env:ProgramFiles\Git", "${env:ProgramFiles(x86)}\Git", "$env:LOCALAPPDATA\Programs\Git") {
        $candidate = Join-Path $root 'bin\bash.exe'
        if (Test-Path -LiteralPath $candidate) { $bash = $candidate; break }
    }
}
if (-not $bash) { throw 'Git for Windows bash was not found. Install Git for Windows and make sure git is on PATH.' }

$script = (Join-Path $PSScriptRoot 'install.sh') -replace '\\', '/'
& $bash $script @args
exit $LASTEXITCODE
