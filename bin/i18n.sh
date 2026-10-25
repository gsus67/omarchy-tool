# shellcheck shell=bash
# Shared by the backend and its copied helpers. Uses the system message locale.
TOOL_LANGUAGE=${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}
case ${TOOL_LANGUAGE,,} in es|es_*|es-*|es.*) TOOL_LANGUAGE=es ;; *) TOOL_LANGUAGE=en ;; esac
TOOL_I18N_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../i18n/messages.json"
if [[ ! -f $TOOL_I18N_FILE ]]; then
  TOOL_I18N_FILE="$(dirname -- "${BASH_SOURCE[0]}")/messages.json"
fi

tool_catalog() {
  if [[ -f $TOOL_I18N_FILE ]]; then
    jq -c --arg language "$TOOL_LANGUAGE" '.[$language] // {}' "$TOOL_I18N_FILE"
  else
    printf '{}\n'
  fi
}

tool_text() {
  local source=$1 result value index=1 token
  shift
  if [[ -f $TOOL_I18N_FILE ]]; then
    result=$(jq -r --arg source "$source" --arg language "$TOOL_LANGUAGE" '.[$language][$source] // $source' "$TOOL_I18N_FILE")
  else
    result=$source
  fi
  for value in "$@"; do
    token="%$index"
    result=${result//"$token"/"$value"}
    index=$((index + 1))
  done
  printf '%s' "$result"
}
