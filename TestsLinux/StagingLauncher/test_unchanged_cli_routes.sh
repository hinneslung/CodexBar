#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <CodexBarStagingLauncher>" >&2
  exit 64
fi

launcher="$(realpath "$1")"
cli="$(dirname "$launcher")/CodexBarCLI"
if [[ ! -x "$launcher" || ! -x "$cli" ]]; then
  echo "the release-matched launcher and CodexBarCLI must be executable siblings" >&2
  exit 66
fi
if ! command -v strace >/dev/null 2>&1; then
  echo "strace is required for the unchanged-CLI route gate" >&2
  exit 69
fi
if ! command -v unshare >/dev/null 2>&1; then
  echo "unshare is required for the unchanged-CLI offline route gate" >&2
  exit 69
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
canary="codexbar-route-gate-fixture-20260831"
mkdir -p "$work/home" "$work/config" "$work/data" "$work/cache" "$work/tmp"
chmod 0700 "$work/home" "$work/config" "$work/data" "$work/cache" "$work/tmp"

config_for() {
  local provider="$1"
  local source="$2"
  local include_credential="$3"
  local api_key=''
  local cookie_fields=''
  if [[ "$include_credential" == true ]]; then
    api_key=",\"apiKey\":\"$canary\""
    local browser_cookie
    browser_cookie="auth=$canary; __Host-auth=$canary; session=$canary; sessionKey=$canary; "
    browser_cookie+="access-token=$canary; kimi-auth=$canary; sso=$canary; sso-rw=$canary; "
    browser_cookie+="session_id=$canary; token_v2=$canary; HERTZ-SESSION=$canary; sec_token=$canary; "
    browser_cookie+="api-platform_serviceToken=$canary; userId=$canary; "
    browser_cookie+="__Secure-authjs.session-token=$canary; authjs.session-token=$canary; "
    browser_cookie+="__Secure-next-auth.session-token=$canary; next-auth.session-token=$canary; "
    browser_cookie+="__Secure-session=$canary; ory_session_fixture=$canary; INGRESSCOOKIE=$canary"
    cookie_fields=",\"cookieHeader\":\"$browser_cookie\",\"cookieSource\":\"manual\""
  fi
  case "$provider:$source" in
    azureopenai:api)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"azureopenai\",\"enabled\":true," \
        "\"source\":\"api\"$api_key,\"enterpriseHost\":" \
        '"https://route-gate.openai.azure.com","workspaceID":"route-gate"}]}'
      ;;
    litellm:api|llmproxy:api|sub2api:api)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"$provider\",\"enabled\":true," \
        "\"source\":\"api\"$api_key," \
        '"enterpriseHost":"http://127.0.0.1:9"}]}'
      ;;
    xai:api)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"xai\",\"enabled\":true," \
        "\"source\":\"api\"$api_key,\"workspaceID\":\"route-gate\"}]}"
      ;;
    stepfun:web)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"stepfun\",\"enabled\":true," \
        "\"source\":\"web\"$(if [[ "$include_credential" == true ]]; then printf \
          ',\"region\":\"%s\",\"cookieSource\":\"manual\"' "$canary"; fi)}]}"
      ;;
    notion:web)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"notion\",\"enabled\":true," \
        "\"source\":\"web\"$(if [[ "$include_credential" == true ]]; then printf \
          ',\"cookieHeader\":\"curl '\''https://app.notion.com/api/v3/getSpaces'\'' -H '\''Cookie: token_v2=%s'\''\",\"cookieSource\":\"manual\"' "$canary"; fi)}]}"
      ;;
    qoder:web)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"qoder\",\"enabled\":true," \
        "\"source\":\"web\"$(if [[ "$include_credential" == true ]]; then printf \
          ',\"cookieHeader\":\"curl '\''https://qoder.com/api/v2/me/usages/big_model_credits'\'' -H '\''Cookie: session=%s'\''\",\"cookieSource\":\"manual\"' "$canary"; fi)}]}"
      ;;
    t3chat:web)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"t3chat\",\"enabled\":true," \
        "\"source\":\"web\"$(if [[ "$include_credential" == true ]]; then printf \
          ',\"cookieHeader\":\"curl '\''https://t3.chat/api/trpc/getCustomerData'\'' -H '\''Cookie: __Secure-authjs.session-token=%s'\''\",\"cookieSource\":\"manual\"' "$canary"; fi)}]}"
      ;;
    zoommate:web)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"zoommate\",\"enabled\":true," \
        "\"source\":\"web\"$(if [[ "$include_credential" == true ]]; then printf \
          ',\"cookieHeader\":\"curl '\''https://ai.zoom.us/ai-computer/api/v1/credits/status'\'' -H '\''Authorization: Bearer %s'\''\",\"cookieSource\":\"manual\"' "$canary"; fi)}]}"
      ;;
    *:web)
      printf '%s' \
        "{\"version\":1,\"providers\":[{\"id\":\"$provider\",\"enabled\":true," \
        "\"source\":\"web\"$cookie_fields}]}"
      ;;
    *:api)
      printf '{"version":1,"providers":[{"id":"%s","enabled":true,"source":"api"%s}]}' \
        "$provider" "$api_key"
      ;;
    *)
      echo "unsupported route fixture: $provider:$source" >&2
      return 64
      ;;
  esac
}

run_invocation() {
  local label="$1"
  local provider="$2"
  local source="$3"
  local config="$4"
  local mode="$5"
  local credential_environment="$6"
  shift 6
  local trace="$work/$label.trace"
  local stdout="$work/$label.stdout"
  local stderr="$work/$label.stderr"

  local -a environment_command=(
    env -i
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "HOME=$work/home"
    "XDG_CONFIG_HOME=$work/config"
    "XDG_DATA_HOME=$work/data"
    "XDG_CACHE_HOME=$work/cache"
    "TMPDIR=$work/tmp"
    "LANG=C.UTF-8"
    "TZ=UTC"
  )
  # Bound libc DNS retries as well as isolating the network namespace. Some
  # FoundationNetworking clients otherwise wait through their full provider
  # deadline after the namespace rejects DNS, which makes an offline gate flaky.
  environment_command+=("RES_OPTIONS=attempts:1 timeout:1")
  local -a environment=()
  if [[ -n "$credential_environment" ]]; then
    environment+=("$credential_environment=$canary")
    environment+=("$@")
  fi
  # Valid fake credentials otherwise reach real provider services and make this
  # permanent gate depend on internet timing. Every fixture runs in an unprivileged
  # network namespace: a credential-present route must reach the provider layer,
  # while the missing control must still fail earlier and remain distinguishable.
  local -a network_namespace=(unshare --user --map-root-user --net)
  set +e
  printf '%s' "$config" | "${environment_command[@]}" "${environment[@]}" timeout 55 \
    "${network_namespace[@]}" strace -f -qq -s 65536 \
    -e trace=execve,socket,connect -o "$trace" \
    "$launcher" --timeout-seconds 50 --provider "$provider" --source "$source" --mode "$mode" \
    >"$stdout" 2>"$stderr"
  local status=$?
  set -e
  if [[ $status -eq 124 || $status -eq 125 || $status -eq 126 || $status -eq 127 || $status -ge 128 ]]; then
    echo "$label could not complete the route gate (status $status)" >&2
    return 1
  fi
  if [[ ! -s "$trace" ]]; then
    echo "$label produced no exec trace" >&2
    return 1
  fi
  assert_exec_evidence "$label" "$mode" "$trace" "$stdout" "$stderr"
}

run_route() {
  local provider="$1"
  local source="$2"
  local label="$provider-$source"
  run_invocation "$label-present" "$provider" "$source" \
    "$(config_for "$provider" "$source" true)" usage ""
  run_invocation "$label-missing" "$provider" "$source" \
    "$(config_for "$provider" "$source" false)" usage ""
  assert_structured_credential_evidence \
    "$provider" "$source" "$work/$label-present.stdout" "$work/$label-missing.stdout"
}

run_web_route() {
  local provider="$1"
  local cli_provider="$2"
  local source="$3"
  local label="$provider-$source"
  run_invocation "$label-present" "$cli_provider" "$source" \
    "$(config_for "$provider" "$source" true)" usage ""
  run_invocation "$label-missing" "$cli_provider" "$source" \
    "$(config_for "$provider" "$source" false)" usage ""
  assert_structured_credential_evidence \
    "$provider" "$source" "$work/$label-present.stdout" "$work/$label-missing.stdout"
}

run_diagnostic_route() {
  local provider="$1"
  local cli_provider="$2"
  local source="$3"
  local label="$provider-$source-diagnose"
  run_invocation "$label-present" "$cli_provider" "$source" \
    "$(config_for "$provider" "$source" true)" diagnose ""
  run_invocation "$label-missing" "$cli_provider" "$source" \
    "$(config_for "$provider" "$source" false)" diagnose ""
  assert_diagnostic_credential_evidence \
    "$provider" "$source" "$work/$label-present.stdout" "$work/$label-missing.stdout" \
    "$work/$label-present.trace" "$work/$label-missing.trace"
}

assert_exec_evidence() {
  local label="$1"
  local mode="$2"
  local trace="$3"
  local stdout="$4"
  local stderr="$5"
  if grep -Fq "$canary" "$trace" || grep -Fq "$canary" "$stdout" || grep -Fq "$canary" "$stderr"; then
    echo "$label exposed the credential canary" >&2
    return 1
  fi

  local path
  local saw_launcher=false
  local saw_cli=false
  while IFS= read -r path; do
    case "$path" in
      "$launcher") saw_launcher=true ;;
      "$cli") saw_cli=true ;;
      *)
        echo "$label executed unrelated child: $path" >&2
        return 1
        ;;
    esac
  done < <(sed -n 's/.*execve("\([^"]*\)".*/\1/p' "$trace")
  if [[ "$saw_launcher" != true || "$saw_cli" != true ]]; then
    echo "$label did not execute exactly the staged launcher and unchanged CLI" >&2
    return 1
  fi
  if [[ "$mode" == usage ]]; then
    grep -Fq '"usage", "--provider"' "$trace" || {
      echo "$label did not exec the unchanged CLI usage mode" >&2
      return 1
    }
  elif [[ "$mode" == diagnose ]]; then
    grep -Fq '"diagnose", "--provider"' "$trace" &&
      grep -Fq '"--format", "json", "--redact"' "$trace" || {
        echo "$label did not exec the exact redacted diagnose mode" >&2
        return 1
      }
  else
    echo "$label requested unsupported evidence mode: $mode" >&2
    return 1
  fi
}

assert_structured_credential_evidence() {
  local provider="$1"
  local source="$2"
  local present="$3"
  local missing="$4"
  python3 - "$provider" "$source" "$present" "$missing" <<'PY'
import json
import re
import sys

provider, source, present_path, missing_path = sys.argv[1:]

def payload(path, role, require_provider_layer):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{provider}:{source} {role} output is not structured JSON: {error}")
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        raise SystemExit(f"{provider}:{source} {role} output must contain exactly one provider payload")
    item = value[0]
    if item.get("provider") != provider or item.get("source") != source:
        raise SystemExit(
            f"{provider}:{source} {role} output selected "
            f"{item.get('provider')}:{item.get('source')} instead of the forced route"
        )
    error = item.get("error")
    if error is not None:
        if not isinstance(error, dict):
            raise SystemExit(f"{provider}:{source} {role} produced an argument/config/runtime outcome")
        kind = error.get("kind")
        if require_provider_layer and kind != "provider":
            raise SystemExit(f"{provider}:{source} {role} did not reach the provider layer")
        if not require_provider_layer and kind not in {"provider", "runtime"}:
            raise SystemExit(f"{provider}:{source} {role} produced an argument/config outcome")
        if not isinstance(error.get("message"), str) or not error["message"].strip():
            raise SystemExit(f"{provider}:{source} {role} produced an empty provider error")
    elif item.get("usage") is None and item.get("credits") is None:
        raise SystemExit(f"{provider}:{source} {role} produced neither usage, credits, nor provider error")
    return item

present = payload(present_path, "credential-present", True)
missing = payload(missing_path, "credential-missing", False)
missing_error = missing.get("error")
if not isinstance(missing_error, dict):
    raise SystemExit(f"{provider}:{source} missing fixture did not prove that a credential is required")

missing_pattern = re.compile(
    r"missing|not configured|no available fetch strategy|"
    r"no\s+.*(?:key|token|credential|cookie)|"
    r"requires?\s+.*(?:key|token|credential|cookie)|set\s+[A-Z][A-Z0-9_]+",
    re.IGNORECASE,
)
missing_web_support = (
    source == "web"
    and missing_error.get("kind") == "runtime"
    and "selected source requires web support" in missing_error["message"].lower()
)
if not missing_pattern.search(missing_error["message"]) and not missing_web_support:
    raise SystemExit(
        f"{provider}:{source} missing fixture did not report a recognizable missing-credential outcome"
    )

present_error = present.get("error")
if isinstance(present_error, dict) and missing_pattern.search(present_error["message"]):
    raise SystemExit(f"{provider}:{source} credential-present fixture still reported a missing credential")
if present == missing:
    raise SystemExit(f"{provider}:{source} credential-present and missing fixtures were indistinguishable")
PY
}

assert_diagnostic_credential_evidence() {
  local provider="$1"
  local source="$2"
  local present="$3"
  local missing="$4"
  local present_trace="$5"
  local missing_trace="$6"
  python3 - "$provider" "$source" "$present" "$missing" "$present_trace" "$missing_trace" <<'PY'
import json
import sys

provider, source, present_path, missing_path, present_trace_path, missing_trace_path = sys.argv[1:]

def payload(path, role):
    try:
        with open(path, encoding="utf-8") as handle:
            item = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{provider}:{source} {role} diagnostic is not valid redacted JSON: {error}")
    if not isinstance(item, dict) or item.get("schemaVersion") != "1.0":
        raise SystemExit(f"{provider}:{source} {role} diagnostic has the wrong schema")
    if item.get("provider") != provider:
        raise SystemExit(
            f"{provider}:{source} {role} diagnostic selected {item.get('provider')}"
        )
    settings = item.get("settings")
    if item.get("sourceMode") != source or not isinstance(settings, dict) or settings.get("sourceMode") != source:
        raise SystemExit(f"{provider}:{source} {role} diagnostic did not use the staged source")
    auth = item.get("auth")
    attempts = item.get("fetchAttempts")
    if not isinstance(auth, dict) or not isinstance(auth.get("configured"), bool):
        raise SystemExit(f"{provider}:{source} {role} diagnostic has malformed auth evidence")
    if not isinstance(attempts, list) or any(not isinstance(value, dict) for value in attempts):
        raise SystemExit(f"{provider}:{source} {role} diagnostic has malformed fetch evidence")
    error = item.get("error")
    if error is not None and (
        not isinstance(error, dict)
        or not isinstance(error.get("category"), str)
        or not isinstance(error.get("safeDescription"), str)
    ):
        raise SystemExit(f"{provider}:{source} {role} diagnostic has malformed error evidence")
    return item

present = payload(present_path, "credential-present")
missing = payload(missing_path, "credential-missing")
present_attempts = present["fetchAttempts"]
if not any(
    attempt.get("kind") == "web" and attempt.get("wasAvailable") is True
    for attempt in present_attempts
):
    raise SystemExit(f"{provider}:{source} credential-present diagnostic did not reach the web provider")

present_error = present.get("error")
missing_error = missing.get("error")
present_category = present_error.get("category") if isinstance(present_error, dict) else None
missing_category = missing_error.get("category") if isinstance(missing_error, dict) else None
if missing["auth"]["configured"]:
    raise SystemExit(f"{provider}:{source} credential-missing diagnostic did not prove missing auth")
if not present["auth"]["configured"]:
    def network_setup_count(path):
        with open(path, encoding="utf-8", errors="replace") as handle:
            return sum("socket(" in line or "connect(" in line for line in handle)

    present_network_setup = network_setup_count(present_trace_path)
    missing_network_setup = network_setup_count(missing_trace_path)
    if present_network_setup <= missing_network_setup:
        raise SystemExit(
            f"{provider}:{source} staged credential was not distinguishable from missing auth"
        )
elif present_category == "auth" and missing_category == "auth":
    raise SystemExit(f"{provider}:{source} credential-present diagnostic still reported missing auth")
PY
}

run_open_code_bridge_route() {
  local provider="$1"
  local environment_key="$2"
  shift 2
  local config
  config="$(config_for "$provider" api false)"
  run_invocation "$provider-api-open-code-present" "$provider" api "$config" \
    usage "$environment_key" "$@"
  run_invocation "$provider-api-open-code-missing" "$provider" api "$config" usage ""
  assert_structured_credential_evidence \
    "$provider" api "$work/$provider-api-open-code-present.stdout" \
    "$work/$provider-api-open-code-missing.stdout"
}

manual_api_providers=(
  aiand alibaba amp azureopenai chutes claude codebuff copilot crof deepgram
  deepinfra doubao elevenlabs fireworks groq ibmbob kilo kimi litellm llmproxy
  moonshot neuralwatt ollama openai opencodego openrouter poe sub2api synthetic
  venice warp xai zai zenmux clawrouter
)

expanded_api_providers=(
  neuralwatt elevenlabs warp clawrouter llmproxy litellm sub2api xai
)

manual_web_routes=(
  'alibabatokenplan|alibaba-token-plan|web'
  'amp|amp|web'
  'commandcode|commandcode|web'
  'cursor|cursor|web'
  'grok|grok|web'
  'opencodego|opencodego|web'
  'qwencloud|qwen-cloud|web'
  'sakana|sakana|web'
  'ollama|ollama|web'
  'qoder|qoder|web'
)

diagnostic_web_routes=(
  'manus|manus|web'
  'perplexity|perplexity|web'
  'longcat|longcat|web'
  'stepfun|stepfun|web'
  'opencode|opencode|web'
  't3chat|t3chat|web'
  'mimo|mimo|web'
  'mistral|mistral|web'
  'zoommate|zoommate|web'
  'notion|notion|web'
)

# provider|secret environment key|optional nonsecret environment assignments
open_code_bridge_routes=(
  'aiand|AIAND_API_KEY'
  'alibaba|ALIBABA_CODING_PLAN_API_KEY'
  'chutes|CHUTES_API_KEY'
  'clinepass|CLINE_API_KEY'
  'copilot|COPILOT_API_TOKEN'
  'crof|CROF_API_KEY'
  'deepinfra|DEEPINFRA_API_KEY'
  'deepseek|DEEPSEEK_API_KEY'
  'fireworks|FIREWORKS_API_KEY'
  'kilo|KILO_API_KEY'
  'kimi|KIMI_CODE_API_KEY'
  'minimax|MINIMAX_API_KEY'
  'moonshot|MOONSHOT_API_KEY|MOONSHOT_REGION=international'
  'ollama|OLLAMA_API_KEY'
  'opencodego|OPENCODE_API_KEY'
  'openrouter|OPENROUTER_API_KEY'
  'poe|POE_API_KEY'
  'synthetic|SYNTHETIC_API_KEY'
  'venice|VENICE_API_KEY'
  'zai|Z_AI_API_KEY|Z_AI_REGION=global'
)

export launcher cli work canary
export -f config_for assert_exec_evidence assert_structured_credential_evidence run_invocation run_route
if [[ "${CODEXBAR_ROUTE_GATE_WEB_ONLY:-0}" != 1 ]]; then
  selected_api_providers=("${manual_api_providers[@]}")
  if [[ "${CODEXBAR_ROUTE_GATE_EXPANDED_ONLY:-0}" == 1 ]]; then
    selected_api_providers=("${expanded_api_providers[@]}")
  fi
  printf '%s\n' "${selected_api_providers[@]}" |
    xargs -r -n 1 -P 5 bash -c 'run_route "$1" api' _
fi
if [[ "${CODEXBAR_ROUTE_GATE_EXPANDED_ONLY:-0}" != 1 ]]; then
  for route in "${manual_web_routes[@]}"; do
    IFS='|' read -r provider cli_provider source <<<"$route"
    run_web_route "$provider" "$cli_provider" "$source"
  done
fi
for route in "${diagnostic_web_routes[@]}"; do
  IFS='|' read -r provider cli_provider source <<<"$route"
  run_diagnostic_route "$provider" "$cli_provider" "$source"
done
if [[ "${CODEXBAR_ROUTE_GATE_WEB_ONLY:-0}" != 1 && \
  "${CODEXBAR_ROUTE_GATE_EXPANDED_ONLY:-0}" != 1 ]]
then
  for route in "${open_code_bridge_routes[@]}"; do
    IFS='|' read -r provider environment_key extra_environment <<<"$route"
    if [[ -n "$extra_environment" ]]; then
      run_open_code_bridge_route "$provider" "$environment_key" "$extra_environment"
    else
      run_open_code_bridge_route "$provider" "$environment_key"
    fi
  done
fi

echo "unchanged CodexBar CLI route-isolation gate passed"
