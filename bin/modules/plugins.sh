# shellcheck shell=bash
# Module: plugins
#
# Turns installed Omarchy plugins on and off from the panel, through Omarchy's
# own `omarchy plugin enable|disable`. The list comes from `omarchy plugin
# list`, so any plugin added later shows up by itself. Built-in plugins and
# Omarchy Tool itself are left out.
#
# Turning a bar widget off drops it from the bar layout, so its place
# (section and position) is remembered first and handed back to `omarchy
# plugin enable` when it is turned on again. Nothing is written outside our
# own config; turning the module off leaves every plugin as it is.

PLUGINS_OMARCHY="${OMARCHY_TOOL_OMARCHY:-omarchy}"
PLUGINS_SHELL_JSON="${OMARCHY_TOOL_SHELL_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json}"

plugins_enabled() {
  [[ $(config_get '.modules.plugins.enabled // false') == true ]]
}

plugins_self_id() {
  jq -r '.id // empty' "$TOOL_DIR/manifest.json" 2>/dev/null
}

# Installed third-party plugins except this one, as JSON.
plugins_list_json() {
  local self
  self=$(plugins_self_id)
  "$PLUGINS_OMARCHY" plugin list --json 2>/dev/null |
    jq -c --arg self "$self" '[.[] | select(.firstParty != true and .id != $self)
      | {id, name, kinds, enabled: (.enabled == true)}] | sort_by(.name | ascii_downcase)' 2>/dev/null ||
    echo '[]'
}

plugins_known() {
  plugins_list_json | jq -e --arg id "$1" 'any(.[]; .id == $id)' >/dev/null
}

# Where a widget sits in the bar right now: {"section": "right", "index": 2}.
plugins_placement() {
  [[ -f $PLUGINS_SHELL_JSON ]] || return 0
  jq -c --arg id "$1" '
    first(.bar.layout // {} | to_entries[] | .key as $section
      | .value | to_entries[] | select(.value.id == $id)
      | {section: $section, index: .key}) // empty' "$PLUGINS_SHELL_JSON" 2>/dev/null
}

plugins_apply() { :; }

plugins_status() {
  local enabled=false list
  plugins_enabled && enabled=true
  list=$(plugins_list_json)
  jq -n --argjson enabled "$enabled" --argjson plugins "$list" \
    '{enabled: $enabled, applied: true, plugins: $plugins}'
}

plugins_enable() {
  config_update '.modules.plugins.enabled = true'
}

plugins_disable() {
  config_update '.modules.plugins.enabled = false'
}

# on <plugin-id>
plugins_on() {
  local id=${1:-} placement section index args=()
  [[ -n $id ]] || fail "usage: omarchy-tool plugins on <plugin-id>"
  plugins_enabled || fail "activa primero la función Plugins"
  plugins_known "$id" || fail "$(tool_text 'plugin desconocido: %1' "$id")"
  placement=$(config_get -c '.modules.plugins.placements[$id] // empty' --arg id "$id")
  if [[ -n $placement ]]; then
    section=$(jq -r '.section // empty' <<<"$placement")
    index=$(jq -r '.index // empty' <<<"$placement")
    [[ $section =~ ^(left|center|right)$ ]] && args+=(--section "$section")
    [[ -n $section && $index =~ ^[0-9]+$ ]] && args+=(--index "$index")
  fi
  "$PLUGINS_OMARCHY" plugin enable "$id" "${args[@]}" >/dev/null ||
    fail "$(tool_text 'no se pudo activar %1' "$id")"
}

# off <plugin-id>
plugins_off() {
  local id=${1:-} placement
  [[ -n $id ]] || fail "usage: omarchy-tool plugins off <plugin-id>"
  plugins_enabled || fail "activa primero la función Plugins"
  plugins_known "$id" || fail "$(tool_text 'plugin desconocido: %1' "$id")"
  placement=$(plugins_placement "$id")
  if [[ -n $placement ]]; then
    config_update '.modules.plugins.placements[$id] = $placement' --arg id "$id" --argjson placement "$placement"
  fi
  "$PLUGINS_OMARCHY" plugin disable "$id" >/dev/null ||
    fail "$(tool_text 'no se pudo desactivar %1' "$id")"
}
