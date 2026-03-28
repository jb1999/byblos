#!/usr/bin/env bash
#
# integration_test.sh — End-to-end integration tests for Byblos
#
# Tests: Rust core, LLM helper, app bundle, agent components, website
# Usage: ./tests/integration_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURES="$SCRIPT_DIR/fixtures"

source "$HOME/.cargo/env" 2>/dev/null || true
cd "$PROJECT_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
PASS=0; FAIL=0; SKIP=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $1 — $2"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}○${NC} $1 — $2"; ((SKIP++)); }

echo "=== Byblos Integration Tests ==="

# ---- 1. Rust Core ----
echo ""
echo "--- Rust Core ---"
RESULT=$(cargo test 2>&1)
if [ $? -eq 0 ]; then
    COUNT=$(echo "$RESULT" | grep "test result" | head -1 | grep -o '[0-9]* passed' | head -1)
    pass "Unit tests ($COUNT)"
else
    fail "Unit tests" "cargo test failed"
fi

# ---- 2. TTS Test Fixtures ----
echo ""
echo "--- Test Fixtures (TTS) ---"
mkdir -p "$FIXTURES"

generate_fixture() {
    local name=$1 text=$2
    local path="$FIXTURES/$name.wav"
    if [ ! -f "$path" ]; then
        say -o "$path" --data-format=LEF32@16000 "$text"
    fi
    if [ -f "$path" ] && [ -s "$path" ]; then
        pass "Fixture: $name.wav ($(du -h "$path" | awk '{print $1}'))"
    else
        fail "Fixture: $name.wav" "Failed to generate"
    fi
}

generate_fixture "hello-world" "Hello world, this is a test of Byblos voice transcription."
generate_fixture "filler-words" "Um, so like, I was thinking that, you know, we should probably fix the bug in the login page."
generate_fixture "email-dictation" "Hi John, I wanted to follow up on our meeting yesterday. The project timeline looks good and I think we can ship by Friday. Let me know if you have any questions. Thanks."
generate_fixture "agent-command" "What time is it right now?"
generate_fixture "short-utterance" "Yes."

# ---- 3. LLM Helper ----
echo ""
echo "--- LLM Helper ---"
LLM_HELPER="$PROJECT_DIR/target/release/byblos-llm"
LLM_MODEL=$(ls "$HOME/Library/Application Support/Byblos/llm-models/"*.gguf 2>/dev/null | head -1)

if [ -z "$LLM_MODEL" ] || [ ! -f "$LLM_HELPER" ]; then
    skip "LLM helper" "No model or binary"
else
    # Ping test
    RESULT=$(echo '{"method":"ping"}' | timeout 45 "$LLM_HELPER" "$LLM_MODEL" 2>/dev/null | tail -1)
    if echo "$RESULT" | grep -q '"pong"'; then
        pass "LLM ping/pong"
    else
        fail "LLM ping" "Got: $RESULT"
    fi

    # Text cleanup test
    RESULT=$( (sleep 20; echo '{"method":"process","text":"um so like fix the bug please","system_prompt":"Remove filler words. Return ONLY the cleaned text, nothing else. /no_think"}'; sleep 30; echo '{"method":"quit"}') | timeout 60 "$LLM_HELPER" "$LLM_MODEL" 2>/dev/null | grep '"ok":true' | tail -1)
    if echo "$RESULT" | grep -q '"ok":true'; then
        pass "LLM text cleanup"
    else
        fail "LLM text cleanup" "No valid response"
    fi

    # JSON agent output test
    RESULT=$( (sleep 5; echo '{"method":"process","text":"what time is it","system_prompt":"Respond ONLY with JSON: {\"actions\":[{\"type\":\"ANSWER\",\"params\":{}}],\"response\":\"message\"} /no_think"}'; sleep 30; echo '{"method":"quit"}') | timeout 45 "$LLM_HELPER" "$LLM_MODEL" 2>/dev/null | grep '"ok":true' | tail -1)
    if echo "$RESULT" | grep -q 'ANSWER\|actions'; then
        pass "LLM agent JSON"
    else
        fail "LLM agent JSON" "No action in response"
    fi

    # Think-tag stripping test
    RESULT=$( (sleep 5; echo '{"method":"process","text":"hello","system_prompt":"Say hi back."}'; sleep 30; echo '{"method":"quit"}') | timeout 45 "$LLM_HELPER" "$LLM_MODEL" 2>/dev/null | grep '"ok":true' | tail -1)
    if echo "$RESULT" | grep -q '<think>'; then
        fail "Think-tag stripping" "Tags not stripped"
    else
        pass "Think-tag stripping"
    fi
fi

# ---- 4. Agent Components ----
echo ""
echo "--- Agent Components ---"

# mdfind
RESULT=$(/usr/bin/mdfind -name "readme" 2>&1 | head -1)
if [ -n "$RESULT" ] && ! echo "$RESULT" | grep -qi "usage\|error\|unknown"; then
    pass "File search (mdfind)"
else
    fail "File search" "$RESULT"
fi

# Shortcuts CLI
if /usr/bin/shortcuts list &>/dev/null; then
    pass "Shortcuts CLI"
else
    skip "Shortcuts CLI" "not available"
fi

# AppleScript
if [ "$(osascript -e 'return "ok"' 2>/dev/null)" = "ok" ]; then
    pass "AppleScript execution"
else
    fail "AppleScript" "failed"
fi

# ---- 5. App Bundle ----
echo ""
echo "--- App Bundle ---"
APP="$HOME/Applications/Byblos.app"

if [ ! -d "$APP" ]; then
    skip "App bundle" "Not installed at ~/Applications"
else
    # Signature
    if codesign --verify "$APP" 2>/dev/null; then
        pass "Code signature valid"
    else
        fail "Code signature" "invalid"
    fi

    # Entitlements
    if codesign -d --entitlements - "$APP" 2>&1 | grep -q "accessibility"; then
        pass "Accessibility entitlement"
    else
        fail "Accessibility entitlement" "missing"
    fi

    # Dylib
    if [ -f "$APP/Contents/Frameworks/libbyblos_core.dylib" ]; then
        pass "Core dylib bundled"
    else
        fail "Core dylib" "missing"
    fi

    # Dylib path
    if otool -L "$APP/Contents/MacOS/Byblos" 2>/dev/null | grep byblos_core | grep -q "@rpath"; then
        pass "Dylib @rpath"
    else
        fail "Dylib path" "not @rpath"
    fi

    # LLM helper
    if [ -f "$APP/Contents/MacOS/byblos-llm" ]; then
        pass "LLM helper bundled"
    else
        fail "LLM helper" "missing"
    fi

    # Icon
    if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
        pass "App icon"
    else
        fail "App icon" "missing"
    fi
fi

# ---- 6. Website ----
echo ""
echo "--- Website ---"

for page in "" "manual.html" "privacy.html" "terms.html" "favicon.png"; do
    URL="https://byblos.im/$page"
    STATUS=$(curl -sI -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || echo "000")
    NAME=${page:-"index"}
    if [ "$STATUS" = "200" ]; then
        pass "$NAME"
    else
        fail "$NAME" "HTTP $STATUS"
    fi
done

# ---- Summary ----
echo ""
echo "==========================================="
echo -e "  ${GREEN}$PASS passed${NC}  ${RED}$FAIL failed${NC}  ${YELLOW}$SKIP skipped${NC}"
echo "==========================================="

[ $FAIL -eq 0 ] && exit 0 || exit 1
