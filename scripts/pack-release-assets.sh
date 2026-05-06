#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_pi_mono_dir="$(git -C "$script_dir" rev-parse --show-toplevel)"

usage() {
  cat <<'EOF'
Usage: scripts/pack-release-assets.sh [OPTIONS]

Build and pack selected pi-mono packages, producing .tgz files suitable for
uploading as immutable GitHub Release assets.

Options:
  --pi-mono-dir DIR   Path to the pi-mono checkout. Default: this script's git root
  --repo OWNER/REPO   GitHub repo used to form release URLs. Default: jackfriedson/pi-mono
  --tag TAG           Release tag. Default: pi-mono-packages-<12-char-commit>
  --out DIR           Output directory. Default: <pi-mono-dir>/.tmp/release-assets/<tag>
  --skip-build        Do not run npm run build before packing.
  -h, --help          Show this help.

What this script does:
  1. Computes the current pi-mono commit.
  2. Runs `npm run build` unless --skip-build is set.
  3. Runs `npm pack --workspace ...` for these packages:
       @mariozechner/pi-ai
       @mariozechner/pi-agent-core
       @mariozechner/pi-tui
       @mariozechner/pi-coding-agent
  4. Writes these helper files next to the generated .tgz files:
       SHA256SUMS
       package-url-overrides.json
       release-notes.md

Typical full workflow from the pi-mono repo root:

  # 1. Install dependencies and build all packages.
  npm ci
  scripts/pack-release-assets.sh --repo jackfriedson/pi-mono

  # 2. Upload the package tarballs as immutable GitHub Release assets.
  short_commit="$(git rev-parse --short=12 HEAD)"
  full_commit="$(git rev-parse HEAD)"
  tag="pi-mono-packages-${short_commit}"
  out=".tmp/release-assets/${tag}"

  gh release create "${tag}" \
    "${out}"/*.tgz \
    --repo jackfriedson/pi-mono \
    --target "${full_commit}" \
    --title "pi-mono packages ${short_commit}" \
    --notes-file "${out}/release-notes.md"

  # 3. Copy the URL specs into downstream package manifests.
  cat "${out}/package-url-overrides.json"

If the packages are already built and dist/ is known to be current, use:

  scripts/pack-release-assets.sh --skip-build --repo jackfriedson/pi-mono

If the release already exists and you only need to upload/replace assets, use:

  gh release upload "${tag}" "${out}"/*.tgz \
    --repo jackfriedson/pi-mono \
    --clobber

Notes:
  - Do not use --skip-build unless you intentionally want to reuse existing dist/ outputs.
  - The default tag is based on the exact source commit for traceability.
  - The release assets should be treated as immutable once downstream lockfiles reference them.
EOF
}

pi_mono_dir="$default_pi_mono_dir"
repo="jackfriedson/pi-mono"
tag=""
out=""
skip_build=false

while (($#)); do
  case "$1" in
    --pi-mono-dir)
      pi_mono_dir="$2"
      shift 2
      ;;
    --repo)
      repo="$2"
      shift 2
      ;;
    --tag)
      tag="$2"
      shift 2
      ;;
    --out)
      out="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$pi_mono_dir/.git" ]]; then
  echo "Expected a git checkout at $pi_mono_dir" >&2
  exit 1
fi

commit="$(git -C "$pi_mono_dir" rev-parse --short=12 HEAD)"
full_commit="$(git -C "$pi_mono_dir" rev-parse HEAD)"
if [[ -z "$tag" ]]; then
  tag="pi-mono-packages-$commit"
fi
if [[ -z "$out" ]]; then
  out="$pi_mono_dir/.tmp/release-assets/$tag"
fi

mkdir -p "$out"
out_abs="$(cd "$out" && pwd)"

packages=(
  "@mariozechner/pi-ai"
  "@mariozechner/pi-agent-core"
  "@mariozechner/pi-tui"
  "@mariozechner/pi-coding-agent"
)

echo "pi-mono checkout: $pi_mono_dir"
echo "pi-mono commit:   $full_commit"
echo "release repo:     $repo"
echo "release tag:      $tag"
echo "output:           $out_abs"

if [[ "$skip_build" != true ]]; then
  echo "Running npm run build in $pi_mono_dir..."
  npm --prefix "$pi_mono_dir" run build
else
  echo "Skipping build; using existing dist/ outputs."
fi

for package in "${packages[@]}"; do
  safe_name="${package#@mariozechner/}"
  safe_name="${safe_name//-/_}"
  echo "Packing $package..."
  npm --prefix "$pi_mono_dir" pack --json --workspace "$package" --pack-destination "$out_abs" \
    > "$out_abs/$safe_name.pack.json"
done

(
  cd "$out_abs"
  shasum -a 256 *.tgz > SHA256SUMS
)

node --input-type=module - "$out_abs" "$repo" "$tag" > "$out_abs/package-url-overrides.json" <<'NODE'
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const [outDir, repo, tag] = process.argv.slice(2);
const entries = {};
for (const file of await readdir(outDir)) {
  if (!file.endsWith(".pack.json")) continue;
  const [packument] = JSON.parse(await readFile(join(outDir, file), "utf8"));
  entries[packument.name] = `https://github.com/${repo}/releases/download/${tag}/${packument.filename}`;
}
console.log(`${JSON.stringify(entries, null, 2)}\n`);
NODE

cat > "$out_abs/release-notes.md" <<EOF
pi-mono package tarballs

Source repository: https://github.com/$repo
Source commit: $full_commit

Assets:

\`\`\`
$(cat "$out_abs/SHA256SUMS")
\`\`\`
EOF

cat <<EOF

Created release assets in:
  $out_abs

Upload these files to GitHub release '$tag' in $repo:
  $(find "$out_abs" -maxdepth 1 -name '*.tgz' -printf '%f ')

Then apply the URL values from:
  $out_abs/package-url-overrides.json
EOF
