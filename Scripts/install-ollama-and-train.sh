#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
ollama_version="${OLLAMA_VERSION:-v0.40.5}"
archive="${SAVEPILOT_OLLAMA_ARCHIVE:-/tmp/Ollama-darwin-${ollama_version}.zip}"
asset_url="https://github.com/ollama/ollama/releases/download/${ollama_version}/Ollama-darwin.zip"
checksum_url="https://github.com/ollama/ollama/releases/download/${ollama_version}/sha256sum.txt"
log_dir="$HOME/Library/Application Support/SavePilot"
mkdir -p "$log_dir"

echo "[1/7] Downloading the official Ollama ${ollama_version} app (resumable)"
curl -L --fail --retry 8 --retry-delay 3 -C - -o "$archive" "$asset_url"

echo "[2/7] Verifying the official release checksum"
expected_checksum="$(curl -L --fail --retry 5 -sS "$checksum_url" | awk '$2 == "Ollama-darwin.zip" { print $1 }')"
actual_checksum="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
if [[ -z "$expected_checksum" || "$actual_checksum" != "$expected_checksum" ]]; then
  echo "Checksum verification failed" >&2
  exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/savepilot-ollama.XXXXXX")"
cleanup() { rm -rf "$staging_dir"; }
trap cleanup EXIT
echo "[3/7] Verifying code signature and installing /Applications/Ollama.app"
ditto -x -k "$archive" "$staging_dir"
staged_app="$(find "$staging_dir" -maxdepth 3 -type d -name Ollama.app -print -quit)"
if [[ -z "$staged_app" ]]; then
  echo "Ollama.app was not found in the verified archive" >&2
  exit 1
fi
codesign --verify --deep --strict "$staged_app"
ditto "$staged_app" /Applications/Ollama.app
codesign --verify --deep --strict /Applications/Ollama.app

echo "[4/7] Starting the local-only Ollama service"
open -a /Applications/Ollama.app
for _ in {1..30}; do
  if curl -sS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -sS --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null

ollama_cli="/Applications/Ollama.app/Contents/Resources/ollama"
if [[ ! -x "$ollama_cli" ]]; then
  ollama_cli="$(find /Applications/Ollama.app/Contents -type f -name ollama -perm -111 -print -quit)"
fi
if [[ -z "$ollama_cli" || ! -x "$ollama_cli" ]]; then
  echo "Ollama CLI was not found in the installed app" >&2
  exit 1
fi

echo "[5/7] Pulling the high-accuracy local models"
"$ollama_cli" pull qwen3-embedding:4b
"$ollama_cli" pull qwen3:4b

echo "[6/7] Generating the isolated Oracle corpus"
cd "$project_dir"
PYTHONPATH=CrossPlatform/src python3 Training/hard_case_corpus.py

echo "[7/7] Iteratively calibrating the relationship decision layer"
PYTHONPATH=CrossPlatform/src python3 Training/train_embedding_relation.py \
  Training/generated/savepilot-hard-cases-v2.jsonl \
  --model qwen3-embedding:4b \
  --output "$log_dir/relationship-embedding-calibration.json" \
  | tee "$log_dir/ollama-training.log"

echo "Ollama setup and SavePilot calibration completed successfully."
