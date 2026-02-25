# code-llm

Local LLM code analysis — build, test, and review any project on CPU-only CI runners (no GPU required).

Docker image with llama.cpp + Qwen2.5-Coder-1.5B.

## What it does

1. Builds your project from source (configurable build command)
2. Runs tests (configurable test command)
3. If there are build errors, test failures, or compiler warnings, feeds them to the local LLM
4. Outputs structured analysis for GitHub Actions to open issues

## Usage

```bash
# Build the image
docker build -t code-llm .

# Run against a local checkout (default cmake workflow)
docker run --rm -v /path/to/project:/workspace:ro code-llm auto
docker run --rm -v /path/to/project:/workspace:ro code-llm review

# Custom build/test commands
docker run --rm \
  -e BUILD_CMD="make -j$(nproc)" \
  -e TEST_CMD="make test" \
  -v /path/to/project:/workspace:ro \
  code-llm auto

# Extra setup (install project-specific dependencies)
docker run --rm \
  -e BUILD_SETUP_CMD="apt-get update && apt-get install -y libtbb-dev" \
  -e BUILD_CMD="cmake -B /tmp/build -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/build -j$(nproc)" \
  -e TEST_CMD="ctest --test-dir /tmp/build --output-on-failure" \
  -v /path/to/project:/workspace:ro \
  code-llm auto

# Custom LLM system prompt
docker run --rm \
  -e SYSTEM_PROMPT="You are a Rust code reviewer. Focus on safety and correctness." \
  -v /path/to/project:/workspace:ro \
  code-llm review
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `BUILD_CMD` | cmake workflow | Shell command to build the project |
| `TEST_CMD` | `ctest` | Shell command to run tests |
| `BUILD_SETUP_CMD` | _(none)_ | Optional setup before build (e.g. install packages) |
| `SYSTEM_PROMPT` | Generic code reviewer | LLM system prompt for analysis |
| `REVIEW_EXTS` | `*.cpp *.h *.hpp *.c *.py *.rs *.go *.java *.ts *.js` | File extensions included in review diffs |
| `MODEL_PATH` | `/models/model.gguf` | Path to GGUF model inside container |
| `LLAMA_PORT` | `8012` | llama.cpp server port |
| `CONTEXT_SIZE` | `4096` | LLM context window size |

## GitHub Actions

The workflow (`.github/workflows/llm-analysis.yml`) is manual-dispatch only. Trigger from the Actions tab with:
- **mode**: `auto` (analyze only on failure) or `review` (always review latest diff)
- **repository**: target repository to analyze (e.g. `owner/repo`)
- **ref**: branch or tag (default: `main`)
- **build_cmd**, **test_cmd**, **build_setup_cmd**, **system_prompt**: optional overrides

## Stack

- **llama.cpp** (static build, CPU-only, `GGML_NATIVE=OFF`)
- **Qwen2.5-Coder-1.5B-Instruct** Q4_K_M (~1GB GGUF)
- Ubuntu 24.04, build-essential, CMake
