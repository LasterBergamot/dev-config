#!/usr/bin/env bash
# UserPromptSubmit, warning only: tells the user when a prompt contains something that looks
# like a credential, before it is sent to the model. The prompt is never blocked.
source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh"
hook_read_input || exit 0

for re in "${HOOK_CREDENTIAL_TEXT[@]}"; do
  if [[ $PROMPT =~ $re ]]; then
    hook_jsv "The prompt contains text that looks like a credential. Remove it and use an environment variable or a local file instead."
    printf '{"systemMessage":%s}\n' "$JS"
    exit 0
  fi
done
exit 0
