#!/usr/bin/env bash
# Frees disk space on a Linux dev machine: Docker, uv, mise, JetBrains, pacman, yay, npm and pnpm.
# Every run first shows what each target would remove, where, and how big it is. Targets whose
# tool is not installed are skipped. Nothing is removed unless you run clean.
#
# Usage: disk-cleanup [check | clean | list] [target...] [options]
#   check             (default) dry run: what each target would free, with sizes and a total
#   clean, free       free the space: shows each target, then asks y/N before cleaning it
#   list              list the target IDs, then exit
#
#   target...         only these targets (same as --only)
#   --only a,b        only the named targets
#   --skip a,b        leave the named targets out
#   -y, --yes         clean without asking per target (docker-volumes still asks)
#   -v, --verbose     list every item of a target, not only the first 10
#   --uv-clean        uv: remove the whole cache (uv cache clean) instead of pruning unused entries
#   --all-volumes     docker-volumes: also remove unused named volumes, not only anonymous ones
#
# docker-volumes is opt-in: check lists the unused volumes, but clean touches them only when the
# target is named, and it always asks first, because a volume can hold data.
#
# Examples:
#   disk-cleanup                              # check every target
#   disk-cleanup clean docker-build uv        # clean only these two, asking for each
#   disk-cleanup clean --skip pacman,yay      # everything else, asking for each
#   disk-cleanup clean --yes --only npm,pnpm  # no questions
#   disk-cleanup clean docker-volumes         # lists the unused volumes, then asks
set -u

TARGETS=(docker-build docker-images docker-volumes uv mise jetbrains jetbrains-toolbox pacman yay npm pnpm)
OPT_IN=' docker-volumes '

CMD=check; YES=0; VERBOSE=0; UV_CLEAN=0; ALL_VOLUMES=0; SKIP=''; EXPLICIT=0

CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}

# --- output helpers ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

tilde() { local p=$1; [[ $p == "$HOME"* ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }

ask_yn() {  # $1 question, $2 = 1 to ask even with --yes. With no terminal the answer is no
  local always=${2:-0}
  if (( YES && ! always )); then return 0; fi
  [[ -t 0 ]] || { say "  $1 [skipped: no terminal; use --yes$( (( always )) && printf ', but this target always asks')]"; return 1; }
  local a; read -r -p "  $1 [y/N] " a
  [[ $a == [yY]* ]]
}

run() {  # prints the command, then runs it
  say "  + $*"
  "$@" || { warn "command failed (exit $?): $*"; return 1; }
}

# --- size helpers -----------------------------------------------------------------------------

hsize() {  # bytes -> 1.5GiB
  local b=${1:-0}
  if (( b < 1024 )); then printf '%dB' "$b"; else numfmt --to=iec-i --suffix=B --format='%.1f' "$b"; fi
}

du_bytes() {  # disk usage of all the paths together, in bytes; 0 when there are none
  (( $# )) || { echo 0; return; }
  local n; n=$(du -s -c -B1 -- "$@" 2>/dev/null | tail -n1 | cut -f1)
  echo "${n:-0}"
}

docker_bytes() {  # "9.957GB (63%)" -> 9957000000 (docker prints decimal units)
  local s=${1%% *}; s=${s%B}
  numfmt --from=si "$s" 2>/dev/null || echo 0
}

# The free space of / and of $HOME when it is on another filesystem.
mounts() {
  local h; h=$(df --output=target "$HOME" 2>/dev/null | tail -n1)
  if [[ -n $h && $h != / ]]; then printf '%s\n' / "$h"; else printf '%s\n' /; fi
}
show_df() { local -a m; mapfile -t m < <(mounts); df -h "${m[@]}" | sed 's/^/  /'; }
avail_bytes() { local -a m; mapfile -t m < <(mounts); df -B1 --output=avail "${m[@]}" | awk 'NR > 1 { s += $1 } END { print s + 0 }'; }

# --- per-target results -----------------------------------------------------------------------

# A probe fills these: the bytes it expects to free, whether that is an upper bound, why the target
# is skipped (empty when it is not), and the lines that show what would be removed.
EST=0; UPTO=0; SKIPPED=''; DETAILS=()

reset_probe() { EST=0; UPTO=0; SKIPPED=''; DETAILS=(); }
detail() { DETAILS+=("$*"); }

limit_list() {  # stdin -> DETAILS, the first 10 lines unless --verbose
  local line n=0 shown=10
  (( VERBOSE )) && shown=1000000
  while IFS= read -r line; do
    n=$((n + 1))
    (( n <= shown )) && DETAILS+=("    $line")
  done
  (( n > shown )) && DETAILS+=("    ... and $((n - shown)) more (--verbose lists them all)")
  return 0
}

add_sized() {  # stdin "bytes<TAB>label" -> DETAILS, largest first
  local b label
  limit_list < <(sort -t $'\t' -k1,1nr | while IFS=$'\t' read -r b label; do
    printf '%9s  %s\n' "$(hsize "$b")" "$label"
  done)
}

paths_sized() {  # paths as arguments -> "bytes<TAB>~/path" lines
  local p
  for p in "$@"; do printf '%s\t%s\n' "$(du_bytes "$p")" "$(tilde "$p")"; done
}

# --- target descriptions ----------------------------------------------------------------------

target_desc() {
  case $1 in
    docker-build)      echo "Docker build cache (docker builder prune -a)" ;;
    docker-images)     echo "Docker images no container uses (docker image prune -a)" ;;
    docker-volumes)    echo "Unused Docker volumes, opt-in (docker volume prune)" ;;
    uv)                echo "uv cache (uv cache prune; --uv-clean: uv cache clean)" ;;
    mise)              echo "mise tool versions no config uses (mise prune)" ;;
    jetbrains)         echo "Caches and data of older JetBrains IDE versions" ;;
    jetbrains-toolbox) echo "JetBrains Toolbox rollback backups and download cache" ;;
    pacman)            echo "Old pacman packages: keep the newest of each, drop uninstalled (paccache)" ;;
    yay)               echo "yay AUR build cache (yay -Sca)" ;;
    npm)               echo "npm cache (npm cache clean --force)" ;;
    pnpm)              echo "pnpm store: unreferenced packages (pnpm store prune)" ;;
  esac
}

target_tool() {  # the command a target needs
  case $1 in
    docker-*)     echo docker ;;
    jetbrains*)   echo '' ;;
    pacman)       echo paccache ;;
    *)            echo "$1" ;;
  esac
}

# --- Docker -----------------------------------------------------------------------------------

DOCKER_OK=''
docker_ok() {  # docker installed and the daemon answers; the result is kept for the run
  if [[ -z $DOCKER_OK ]]; then
    if ! have docker; then DOCKER_OK='docker is not installed'
    elif ! timeout 20 docker info >/dev/null 2>&1; then DOCKER_OK='the docker daemon is not reachable'
    else DOCKER_OK=yes; fi
  fi
  [[ $DOCKER_OK == yes ]] || { SKIPPED=$DOCKER_OK; return 1; }
}

docker_df_row() {  # $1 type (Images, Build Cache, ...) -> "count|size|reclaimable"
  docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null \
    | awk -F'|' -v t="$1" '$1 == t { print $2 "|" $3 "|" $4 }'
}

probe_docker_build() {
  docker_ok || return
  local row count size recl
  row=$(docker_df_row 'Build Cache')
  IFS='|' read -r count size recl <<<"$row"
  EST=$(docker_bytes "${recl:-0B}")
  detail "  ${count:-0} build cache records, ${size:-0B} in total, ${recl:-0B} reclaimable (docker system df)"
}

probe_docker_images() {
  docker_ok || return
  local row count size recl id cont sz uniq repo tag created
  row=$(docker_df_row Images)
  IFS='|' read -r count size recl <<<"$row"
  EST=$(docker_bytes "${recl:-0B}")
  detail "  ${count:-0} images, ${size:-0B} in total, ${recl:-0B} reclaimable; images no container uses:"
  add_sized < <(
    docker system df -v --format '{{range .Images}}{{.ID}}|{{.Containers}}|{{.Size}}|{{.UniqueSize}}|{{.Repository}}|{{.Tag}}|{{.CreatedSince}}{{println}}{{end}}' 2>/dev/null \
      | while IFS='|' read -r id cont sz uniq repo tag created; do
          [[ -n $id && $cont == 0 ]] || continue
          id=${id#sha256:}
          printf '%s\t%s:%s  %s, %s unique, %s\n' "$(docker_bytes "$uniq")" "$repo" "$tag" "${id:0:12}" "$uniq" "$created"
        done)
}

VOL_ANON=(); VOL_NAMED=()
probe_docker_volumes() {
  docker_ok || return
  local name links sz labels kind b
  VOL_ANON=(); VOL_NAMED=()
  local -a rows=()
  while IFS='|' read -r name links sz labels; do
    [[ -n $name && $links == 0 ]] || continue
    b=$(docker_bytes "$sz")
    if [[ $labels == *com.docker.volume.anonymous* ]]; then
      VOL_ANON+=("$name"); kind='anonymous'; EST=$((EST + b))
    else
      VOL_NAMED+=("$name")
      kind='named'
      [[ $labels =~ com\.docker\.compose\.project=([^,]*) ]] && kind="named, compose project ${BASH_REMATCH[1]}"
      if (( ALL_VOLUMES )); then EST=$((EST + b)); else kind+="; kept, --all-volumes removes it"; fi
    fi
    rows+=("$b"$'\t'"$name  ($kind)")
  done < <(docker system df -v --format '{{range .Volumes}}{{.Name}}|{{.Links}}|{{.Size}}|{{.Labels}}{{println}}{{end}}' 2>/dev/null)
  detail "  ${#VOL_ANON[@]} anonymous and ${#VOL_NAMED[@]} named volumes are not used by any container:"
  (( ${#rows[@]} )) && add_sized < <(printf '%s\n' "${rows[@]}")
  detail "  Check that none of them holds data you need (docker volume inspect <name>)."
}

clean_docker_build()  { run docker builder prune -a -f; }
clean_docker_images() { run docker image prune -a -f; }
clean_docker_volumes() {
  if (( ALL_VOLUMES )); then run docker volume prune -a -f; else run docker volume prune -f; fi
}

# --- uv ---------------------------------------------------------------------------------------

UV_DIR=''
probe_uv() {
  have uv || { SKIPPED='uv is not installed'; return; }
  UV_DIR=$(uv cache dir 2>/dev/null)
  [[ -n $UV_DIR && -d $UV_DIR ]] || { SKIPPED='no uv cache'; return; }
  EST=$(du_bytes "$UV_DIR")
  if (( UV_CLEAN )); then
    detail "  uv cache clean removes all of $(tilde "$UV_DIR") ($(hsize "$EST")):"
  else
    UPTO=1
    detail "  uv cache prune removes the entries of $(tilde "$UV_DIR") that nothing uses; how much is known"
    detail "  only after it runs (--uv-clean removes the whole $(hsize "$EST")). Its folders:"
  fi
  local -a sub; mapfile -t sub < <(find "$UV_DIR" -mindepth 1 -maxdepth 1 -type d)
  (( ${#sub[@]} )) && add_sized < <(paths_sized "${sub[@]}")
}

clean_uv() { if (( UV_CLEAN )); then run uv cache clean; else run uv cache prune; fi; }

# --- mise -------------------------------------------------------------------------------------

MISE_CACHE=${MISE_CACHE_DIR:-$CACHE_HOME/mise}
MISE_DATA=${MISE_DATA_DIR:-$DATA_HOME/mise}

mise_prunable() {  # -> "tool<TAB>version<TAB>install path"
  if have jq; then
    mise ls --prunable --json 2>/dev/null \
      | jq -r 'to_entries[] | .key as $t | .value[] | [$t, .version, .install_path] | @tsv' 2>/dev/null
  else  # without jq, guess the folder the way mise names it (npm:foo -> npm-foo)
    local t v
    mise ls --prunable 2>/dev/null | while read -r t v _; do
      [[ -n $v ]] && printf '%s\t%s\t%s\n' "$t" "$v" "$MISE_DATA/installs/${t//[:\/]/-}/$v"
    done
  fi
}

probe_mise() {
  have mise || { SKIPPED='mise is not installed'; return; }
  local t v p c b
  local -a rows=()
  while IFS=$'\t' read -r t v p; do
    [[ -n $p ]] || continue
    c=${p%/*}; c=$MISE_CACHE/${c##*/}/$v  # the cache folder uses the same tool folder name
    b=$(du_bytes "$p" "$c")
    EST=$((EST + b))
    rows+=("$b"$'\t'"$t@$v  $(tilde "$p")")
  done < <(mise_prunable)
  detail "  ${#rows[@]} versions that no tracked config selects (mise ls --prunable):"
  (( ${#rows[@]} )) && add_sized < <(printf '%s\n' "${rows[@]}")
}

clean_mise() { run mise prune --tools --yes; }

# --- JetBrains --------------------------------------------------------------------------------

JB_CACHE=$CACHE_HOME/JetBrains
JB_DATA=$DATA_HOME/JetBrains
JB_CONFIG=$CONFIG_HOME/JetBrains
JB_OLD=()

# Product folders are named <Product><year>.<n>, e.g. PyCharm2026.3. For each product the newest
# version found in the cache, data or config folder is kept; older ones in cache and data are
# listed. Config folders (settings) are small and left alone.
jb_old_dirs() {
  local d n base
  local -A newest=()
  for base in "$JB_CACHE" "$JB_DATA" "$JB_CONFIG"; do
    for d in "$base"/*/; do
      n=${d%/}; n=${n##*/}
      [[ $n =~ ^(.*[^0-9.])([0-9]{4}\.[0-9]+)$ ]] || continue
      local prod=${BASH_REMATCH[1]} ver=${BASH_REMATCH[2]}
      if [[ -z ${newest[$prod]:-} ]] || [[ $(printf '%s\n' "${newest[$prod]}" "$ver" | sort -V | tail -n1) == "$ver" ]]; then
        newest[$prod]=$ver
      fi
    done
  done
  for base in "$JB_CACHE" "$JB_DATA"; do
    for d in "$base"/*/; do
      n=${d%/}; n=${n##*/}
      [[ $n =~ ^(.*[^0-9.])([0-9]{4}\.[0-9]+)$ ]] || continue
      [[ ${BASH_REMATCH[2]} != "${newest[${BASH_REMATCH[1]}]}" ]] && printf '%s\n' "${d%/}"
    done
  done
}

probe_jetbrains() {
  [[ -d $JB_CACHE || -d $JB_DATA ]] || { SKIPPED='no JetBrains folders'; return; }
  mapfile -t JB_OLD < <(jb_old_dirs)
  (( ${#JB_OLD[@]} )) && EST=$(du_bytes "${JB_OLD[@]}")
  detail "  Folders of older IDE versions; the newest version of each product is kept:"
  (( ${#JB_OLD[@]} )) && add_sized < <(paths_sized "${JB_OLD[@]}")
  return 0
}

clean_jetbrains() {
  local d
  for d in "${JB_OLD[@]}"; do
    [[ $d == "$JB_CACHE"/* || $d == "$JB_DATA"/* ]] || { warn "not a JetBrains folder, left alone: $d"; continue; }
    run rm -rf -- "$d"
  done
}

JB_TB=$JB_CACHE/Toolbox
JB_TB_ITEMS=()
toolbox_running() { pgrep -f 'jetbrains-toolbox' >/dev/null 2>&1; }

probe_jetbrains_toolbox() {
  [[ -d $JB_TB ]] || { SKIPPED='JetBrains Toolbox is not installed'; return; }
  JB_TB_ITEMS=()
  local d
  for d in "$JB_TB"/backup/*; do [[ -e $d ]] && JB_TB_ITEMS+=("$d"); done
  [[ -d $JB_TB/download ]] && [[ -n $(ls -A "$JB_TB/download" 2>/dev/null) ]] && JB_TB_ITEMS+=("$JB_TB/download")
  (( ${#JB_TB_ITEMS[@]} )) && EST=$(du_bytes "${JB_TB_ITEMS[@]}")
  detail "  Copies of the previous IDE builds that Toolbox keeps for rollback, and its download cache"
  detail "  (only the contents of download/ are removed). You lose the rollback to the previous build:"
  (( ${#JB_TB_ITEMS[@]} )) && add_sized < <(paths_sized "${JB_TB_ITEMS[@]}")
  toolbox_running && detail "  Toolbox is running: quit it before clean, which skips this target while it runs."
  return 0
}

clean_jetbrains_toolbox() {
  local d
  for d in "${JB_TB_ITEMS[@]}"; do
    if [[ $d == "$JB_TB/download" ]]; then
      run find "$d" -mindepth 1 -delete
    elif [[ $d == "$JB_TB"/backup/* ]]; then
      run rm -rf -- "$d"
    fi
  done
}

# --- pacman -----------------------------------------------------------------------------------

PAC_DIR=''
probe_pacman() {
  have paccache || { SKIPPED='paccache is not installed (pacman-contrib)'; return; }
  PAC_DIR=$(pacman-conf CacheDir 2>/dev/null | head -n1)
  PAC_DIR=${PAC_DIR:-/var/cache/pacman/pkg/}; PAC_DIR=${PAC_DIR%/}
  local -a files
  # Older versions of every package (-k1), plus every version of uninstalled ones (-uk0).
  mapfile -t files < <({ paccache -dvk1 --nocolor; paccache -dvuk0 --nocolor; } 2>/dev/null \
                         | grep -E '\.pkg\.tar' | sort -u)
  local pkgs; pkgs=$(printf '%s\n' "${files[@]}" | grep -vc '\.sig$')
  detail "  $pkgs packages in $PAC_DIR (paccache -dk1 and -duk0, with their .sig files); needs sudo."
  detail "  Only the newest version of each installed package stays, so downgrading needs a download."
  (( ${#files[@]} )) || return 0
  EST=$(cd "$PAC_DIR" && du_bytes "${files[@]}")
  local f
  add_sized < <(for f in "${files[@]}"; do [[ $f == *.sig ]] || printf '%s\t%s\n' "$(cd "$PAC_DIR" && du_bytes "$f")" "$f"; done)
}

clean_pacman() {
  have sudo || { warn "sudo is not installed; run paccache -rk1 and paccache -ruk0 as root"; return 1; }
  run sudo paccache -rk1 && run sudo paccache -ruk0
}

# --- yay --------------------------------------------------------------------------------------

YAY_DIR=''
probe_yay() {
  have yay || { SKIPPED='yay is not installed'; return; }
  if have jq; then YAY_DIR=$(yay -Pg 2>/dev/null | jq -r '.buildDir // empty' 2>/dev/null); fi
  YAY_DIR=${YAY_DIR:-$CACHE_HOME/yay}; YAY_DIR=${YAY_DIR%/}
  [[ -d $YAY_DIR ]] || { SKIPPED="no yay cache ($(tilde "$YAY_DIR"))"; return; }
  EST=$(du_bytes "$YAY_DIR"); UPTO=1
  detail "  AUR build folders in $(tilde "$YAY_DIR"). yay asks two questions: remove the folders of"
  detail "  uninstalled packages, and remove untracked files (built packages, sources) of the rest:"
  local d n state
  add_sized < <(for d in "$YAY_DIR"/*/; do
    [[ -d $d ]] || continue
    n=${d%/}; n=${n##*/}
    if pacman -Qq "$n" >/dev/null 2>&1; then state='installed'; else state='not installed'; fi
    printf '%s\t%s  (%s)\n' "$(du_bytes "$d")" "$n" "$state"
  done)
}

clean_yay() { if (( YES )); then run yay -Sca --noconfirm; else run yay -Sca; fi; }

# --- npm, pnpm --------------------------------------------------------------------------------

NPM_DIR=''
probe_npm() {
  have npm || { SKIPPED='npm is not installed'; return; }
  NPM_DIR=$(npm config get cache 2>/dev/null)/_cacache
  [[ -d $NPM_DIR ]] || { SKIPPED="no npm cache ($(tilde "$NPM_DIR"))"; return; }
  EST=$(du_bytes "$NPM_DIR")
  detail "  $(tilde "$NPM_DIR")"
}

clean_npm() { run npm cache clean --force; }

PNPM_OLD=()
probe_pnpm() {
  have pnpm || { SKIPPED='pnpm is not installed'; return; }
  local store parent d
  store=$(timeout 60 pnpm store path 2>/dev/null)
  [[ -n $store && -d $store ]] || { SKIPPED='no pnpm store'; return; }
  EST=$(du_bytes "$store"); UPTO=1
  detail "  pnpm store prune removes the packages of $(tilde "$store") ($(hsize "$EST")) that no project"
  detail "  references; how much is known only after it runs."
  # Stores left by older pnpm versions (v3, v10 next to v11) are not used any more.
  PNPM_OLD=()
  parent=${store%/}; parent=${parent%/*}
  for d in "$parent"/v[0-9]*; do
    [[ -d $d && ${d%/} != "${store%/}" ]] && PNPM_OLD+=("$d")
  done
  if (( ${#PNPM_OLD[@]} )); then
    detail "  Stores of older pnpm versions, removed whole:"
    add_sized < <(paths_sized "${PNPM_OLD[@]}")
    EST=$((EST + $(du_bytes "${PNPM_OLD[@]}")))
  fi
  return 0
}

clean_pnpm() {
  local d
  run pnpm store prune || return 1
  for d in "${PNPM_OLD[@]}"; do run rm -rf -- "$d"; done
}

# --- running a target -------------------------------------------------------------------------

ROWS=()          # summary lines
TOTAL=0          # check: bytes expected; clean: bytes freed
TOTAL_UPTO=0     # check: bytes of the targets that only know an upper bound

row() {  # $1 target, $2 size, $3 note
  local r; r=$(printf '  %-18s %16s  %s' "$1" "$2" "$3")
  ROWS+=("${r%"${r##*[! ]}"}")
}

run_target() {
  local id=$1 fn=${1//-/_} size note
  reset_probe
  "probe_$fn"
  if [[ -n $SKIPPED ]]; then
    say; say "$id: skipped, $SKIPPED"
    row "$id" '-' "skipped: $SKIPPED"; return
  fi
  size=$(hsize "$EST"); (( UPTO )) && size="up to $size"
  say; say "$id: $(target_desc "$id")    [$size]"
  local l; for l in "${DETAILS[@]}"; do say "$l"; done

  if (( EST == 0 && ! UPTO )); then say "  nothing to free"; row "$id" 0B 'nothing to free'; return; fi

  if [[ $CMD == check ]]; then
    if [[ $OPT_IN == *" $id "* ]] && (( ! EXPLICIT )); then
      row "$id" "$size" 'opt-in, not in the total: name it to clean it'; return
    fi
    if (( UPTO )); then TOTAL_UPTO=$((TOTAL_UPTO + EST)); note='exact amount known after cleaning'
    else TOTAL=$((TOTAL + EST)); note=''; fi
    row "$id" "$size" "$note"; return
  fi

  # clean
  if [[ $id == jetbrains-toolbox ]] && toolbox_running; then
    say "  skipped: JetBrains Toolbox is running; quit it and run again"
    row "$id" '-' 'skipped: Toolbox is running'; return
  fi
  local always=0; [[ $OPT_IN == *" $id "* ]] && always=1
  if ! ask_yn "Clean $id ($size)?" "$always"; then row "$id" '-' 'not cleaned'; return; fi
  local before after freed
  before=$(avail_bytes)
  if "clean_$fn"; then note='cleaned'; else note='failed, see above'; fi
  after=$(avail_bytes)
  freed=$((after - before)); (( freed < 0 )) && freed=0
  TOTAL=$((TOTAL + freed))
  say "  freed $(hsize "$freed")"
  row "$id" "$(hsize "$freed")" "$note"
}

# --- arguments --------------------------------------------------------------------------------

valid_target() { local t; for t in "${TARGETS[@]}"; do [[ $t == "$1" ]] && return 0; done; return 1; }

show_targets() {
  local t tool state
  for t in "${TARGETS[@]}"; do
    tool=$(target_tool "$t")
    if [[ -n $tool ]] && ! have "$tool"; then state="($tool not installed)"; else state=''; fi
    printf '  %-18s %s%s\n' "$t" "$(target_desc "$t")" "${state:+ $state}"
  done
}

CHOSEN=' '
add_chosen() {
  local t
  for t in ${1//,/ }; do
    valid_target "$t" || die "unknown target: $t (see disk-cleanup list)"
    [[ $CHOSEN == *" $t "* ]] || CHOSEN+="$t "
  done
}

GOT_CMD=0
while (( $# )); do
  case $1 in
    check|clean|free|list)
      if (( GOT_CMD )) || [[ $CHOSEN != ' ' ]]; then die "the command must come first: $1"; fi
      CMD=$1; [[ $CMD == free ]] && CMD=clean; GOT_CMD=1 ;;
    --only)        [[ -n ${2:-} ]] || die "--only needs a comma-separated list of targets"
                   add_chosen "$2"; EXPLICIT=1; shift ;;
    --skip)        [[ -n ${2:-} ]] || die "--skip needs a comma-separated list of targets"
                   SKIP+=" ${2//,/ }"; shift ;;
    -y|--yes)      YES=1 ;;
    -v|--verbose)  VERBOSE=1 ;;
    --uv-clean)    UV_CLEAN=1 ;;
    --all-volumes) ALL_VOLUMES=1 ;;
    -h|--help|help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*)            die "unknown option: $1 (see --help)" ;;
    *)             add_chosen "$1"; EXPLICIT=1 ;;
  esac
  shift
done

if [[ $CMD == list ]]; then
  say "Targets (docker-volumes is opt-in: clean runs it only when it is named):"
  show_targets; exit 0
fi

if [[ $CHOSEN == ' ' ]]; then
  for t in "${TARGETS[@]}"; do
    # check shows the opt-in targets too; clean leaves them out unless they are named
    [[ $CMD == clean && $OPT_IN == *" $t "* ]] && continue
    CHOSEN+="$t "
  done
fi
for t in $SKIP; do
  valid_target "$t" || die "unknown target in --skip: $t (see disk-cleanup list)"
  CHOSEN=${CHOSEN/ $t / }
done
[[ $CHOSEN == ' ' ]] && { say "Nothing selected."; exit 0; }

have numfmt || die "numfmt (coreutils) is needed"

# --- main -------------------------------------------------------------------------------------

if [[ $CMD == check ]]; then say "disk-cleanup check: dry run, nothing is removed."
else say "disk-cleanup clean: each target is shown first$( (( YES )) || printf ', then you are asked y/N')."; fi
say; say "Disk usage:"; show_df

for t in "${TARGETS[@]}"; do
  [[ $CHOSEN == *" $t "* ]] && run_target "$t"
done

say; say "Summary:"
for l in "${ROWS[@]}"; do say "$l"; done
say
if [[ $CMD == check ]]; then
  if (( TOTAL_UPTO )); then
    say "Total: $(hsize "$TOTAL"), plus up to $(hsize "$TOTAL_UPTO") from targets that know only an upper bound."
  else
    say "Total: $(hsize "$TOTAL")."
  fi
  if [[ $CHOSEN == *" docker-volumes "* ]] && (( ! EXPLICIT )); then
    say "docker-volumes is not in the total; clean it with: disk-cleanup clean docker-volumes"
  fi
  say "Free the space with: disk-cleanup clean [target...]  (asks per target)"
else
  say "Freed: $(hsize "$TOTAL") (measured as the change in free space)."
  say; say "Disk usage now:"; show_df
fi
