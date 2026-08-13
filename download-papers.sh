#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAPER_DIR="${ROOT_DIR}/papers"
mkdir -p "${PAPER_DIR}"

download() {
  local filename="$1"
  local url="$2"
  local destination="${PAPER_DIR}/${filename}"

  printf 'Downloading %s\n' "${filename}"
  curl \
    --location \
    --fail \
    --silent \
    --show-error \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 20 \
    --max-time 300 \
    "${url}" \
    --output "${destination}.tmp"

  if [[ "$(dd if="${destination}.tmp" bs=4 count=1 2>/dev/null)" != "%PDF" ]]; then
    printf 'Downloaded file is not a PDF: %s\n' "${url}" >&2
    rm -f "${destination}.tmp"
    return 1
  fi

  mv "${destination}.tmp" "${destination}"
}

download "01-cordis-spatiotemporal-composability.pdf" \
  "https://raw.githubusercontent.com/cordiverse/paper/main/paper.pdf"
download "02-r3-skill-routing.pdf" \
  "https://arxiv.org/pdf/2606.03565"
download "03-compositional-skill-routing.pdf" \
  "https://arxiv.org/pdf/2606.18051"
download "04-tool-graph-retriever.pdf" \
  "https://arxiv.org/pdf/2508.05152"
download "05-graph-rag-tool-fusion.pdf" \
  "https://arxiv.org/pdf/2502.07223"
download "06-gtool.pdf" \
  "https://arxiv.org/pdf/2508.12725"
download "07-dynamic-tool-dependency-retrieval.pdf" \
  "https://aclanthology.org/2026.findings-acl.1680.pdf"
download "08-toolret.pdf" \
  "https://arxiv.org/pdf/2503.01763"
download "09-toolomni.pdf" \
  "https://arxiv.org/pdf/2604.13787"
download "10-c-world-toolgym.pdf" \
  "https://arxiv.org/pdf/2601.06328"
download "11-toolsandbox.pdf" \
  "https://arxiv.org/pdf/2408.04682"
download "12-mcp-atlas.pdf" \
  "https://arxiv.org/pdf/2602.00933"
download "13-mcp-bench.pdf" \
  "https://arxiv.org/pdf/2508.20453"
download "14-etom-msc-bench.pdf" \
  "https://arxiv.org/pdf/2510.19423"
download "15-dynamic-mcp-bench.pdf" \
  "https://arxiv.org/pdf/2607.20531"
download "16-harness-bench.pdf" \
  "https://arxiv.org/pdf/2605.27922"
download "17-toolbench.pdf" \
  "https://arxiv.org/pdf/2307.16789"

(
  cd "${PAPER_DIR}"
  sha256sum ./*.pdf > SHA256SUMS
)

printf 'Downloaded %s PDFs to %s\n' \
  "$(find "${PAPER_DIR}" -maxdepth 1 -type f -name '*.pdf' | wc -l)" \
  "${PAPER_DIR}"
