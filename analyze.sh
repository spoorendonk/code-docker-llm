#!/usr/bin/env bash
# Main CI analysis entrypoint (project-agnostic).
# Builds the project, captures warnings/errors, runs tests,
# then starts the LLM server and feeds failures for analysis.
# Outputs structured ISSUE_TITLE / ISSUE_BODY for GitHub Actions.
#
# Configuration via environment variables:
#   BUILD_CMD        — command to build the project (default: cmake workflow)
#   TEST_CMD         — command to run tests (default: ctest)
#   BUILD_SETUP_CMD  — optional setup before build (e.g. "apt-get install -y libtbb-dev")
#   SYSTEM_PROMPT    — LLM system prompt (default: generic code reviewer)
#   REVIEW_EXTS      — file extensions for code review diff (default: "*.cpp *.h *.hpp *.c *.py *.rs *.go *.java *.ts *.js")
#   MODEL_PATH       — path to GGUF model file
#   LLAMA_PORT       — llama.cpp server port
#   CONTEXT_SIZE     — LLM context window size
set -euo pipefail

MODEL_PATH="${MODEL_PATH:-/models/model.gguf}"
LLAMA_PORT="${LLAMA_PORT:-8012}"
CONTEXT_SIZE="${CONTEXT_SIZE:-4096}"
MODE="${1:-auto}"  # auto | review

echo "=== LLM code analysis (mode: $MODE) ==="

# ── Optional setup (install extra packages, etc.) ─────────────────────
if [ -n "${BUILD_SETUP_CMD:-}" ]; then
    echo "Running setup: $BUILD_SETUP_CMD"
    eval "$BUILD_SETUP_CMD"
fi

# ── Build ─────────────────────────────────────────────────────────────
BUILD_DIR="/tmp/project-build"
BUILD_LOG=$(mktemp)
BUILD_OK=true

if [ -n "${BUILD_CMD:-}" ]; then
    echo "Building project..."
    if ! eval "$BUILD_CMD" 2>&1 | tee "$BUILD_LOG"; then
        BUILD_OK=false
    fi
else
    # Default: cmake workflow
    echo "Building project (cmake)..."
    if ! cmake -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 2>&1 | tee "$BUILD_LOG"; then
        BUILD_OK=false
    elif ! cmake --build "$BUILD_DIR" -j"$(nproc)" 2>&1 | tee -a "$BUILD_LOG"; then
        BUILD_OK=false
    fi
fi

# Extract unique warning/error lines (skip notes, includes, duplicates)
WARNINGS=$(grep -E '(warning|error):' "$BUILD_LOG" \
    | grep -v '^In file included' \
    | grep -v ': note:' \
    | grep -v 'declared here' \
    | sort -u \
    | head -30 || true)

# ── Test ─────────────────────────────────────────────────────────────
TEST_LOG=$(mktemp)
TEST_OK=true
if [ "$BUILD_OK" = true ]; then
    if [ -n "${TEST_CMD:-}" ]; then
        echo "Running tests..."
        eval "$TEST_CMD" 2>&1 | tee "$TEST_LOG" || TEST_OK=false
    else
        # Default: ctest if a cmake build dir exists
        if [ -d "$BUILD_DIR" ]; then
            echo "Running tests (ctest)..."
            ctest --test-dir "$BUILD_DIR" --output-on-failure 2>&1 | tee "$TEST_LOG" || TEST_OK=false
        fi
    fi
fi

TEST_FAILURES=$(grep -E '(FAILED|ERROR|FAIL)' "$TEST_LOG" | head -50 || true)

# ── Decide if we need LLM ───────────────────────────────────────────
if [ "$MODE" = "auto" ] && [ "$BUILD_OK" = true ] && [ "$TEST_OK" = true ] && [ -z "$WARNINGS" ]; then
    echo "Build and tests passed cleanly. No issues found."
    exit 0
fi

# ── Start llama.cpp server (after build/test free up resources) ──────
echo "Starting llama.cpp server..."
llama-server \
    --model "$MODEL_PATH" \
    --port "$LLAMA_PORT" \
    --ctx-size "$CONTEXT_SIZE" \
    --threads 2 \
    --log-disable \
    &
LLAMA_PID=$!

cleanup() {
    kill "$LLAMA_PID" 2>/dev/null || true
    wait "$LLAMA_PID" 2>/dev/null || true
}
trap cleanup EXIT

for i in $(seq 1 60); do
    if curl -sf "http://localhost:${LLAMA_PORT}/health" > /dev/null 2>&1; then
        echo "llama.cpp server ready."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "ERROR: llama.cpp server failed to start" >&2
        exit 1
    fi
    sleep 1
done

# ── Analyze with LLM ────────────────────────────────────────────────
ANALYSIS=$(mktemp)
ISSUE_TYPE=""

if [ "$MODE" = "review" ]; then
    ISSUE_TYPE="review"
    llm-review.sh review "" "$LLAMA_PORT" > "$ANALYSIS"

elif [ "$BUILD_OK" = false ]; then
    ISSUE_TYPE="build_failure"
    llm-review.sh build_failure "$WARNINGS" "$LLAMA_PORT" > "$ANALYSIS"

elif [ "$TEST_OK" = false ]; then
    ISSUE_TYPE="test_failure"
    llm-review.sh test_failure "$TEST_FAILURES" "$LLAMA_PORT" > "$ANALYSIS"

elif [ -n "$WARNINGS" ]; then
    ISSUE_TYPE="warnings"
    llm-review.sh warnings "$WARNINGS" "$LLAMA_PORT" > "$ANALYSIS"
fi

echo ""
echo "=== LLM Analysis ==="
cat "$ANALYSIS"

# ── Emit structured output for GitHub Actions ────────────────────────
COMMIT=$(cd /workspace && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

case "$ISSUE_TYPE" in
    build_failure) TITLE="Build failure on ${COMMIT}" ;;
    test_failure)  TITLE="Test failure on ${COMMIT}" ;;
    warnings)      TITLE="Compiler warnings on ${COMMIT}" ;;
    review)        TITLE="Code review for ${COMMIT}" ;;
esac

echo "ISSUE_TITLE=${TITLE}"
echo "ISSUE_BODY<<EOF"
cat <<BODY
## ${TITLE}

**Commit:** \`${COMMIT}\`
**Mode:** ${MODE}
**Build:** $([ "$BUILD_OK" = true ] && echo "passed" || echo "FAILED")
**Tests:** $([ "$TEST_OK" = true ] && echo "passed" || echo "FAILED")

### Analysis

$(cat "$ANALYSIS")

---
_Automated analysis by local LLM via llama.cpp_
BODY
echo "EOF"

if [ "$BUILD_OK" = false ] || [ "$TEST_OK" = false ]; then
    exit 1
fi
