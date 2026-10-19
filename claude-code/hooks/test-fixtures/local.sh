# Test fixture for test-hooks.sh. It stands in for a machine's local.sh, so the cases never depend
# on real drives. Drive E:, F: and G: are "media" here, and rename_movies/rename_shows with --apply
# is the one local rule.

HOOK_PROTECTED=(e:/media f:/media g:/media /e/media /f/media /g/media podmandata)

hook_local_protect() {
  if [[ $LC == *rename_movies* || $LC == *rename_shows* ]] && [[ $LC == *--apply* ]]; then
    hook_ask "renames media files (--apply)"
  fi
}
