#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing kind ==="
go install sigs.k8s.io/kind@v0.25.0

echo "=== Installing Crossplane CLI ==="
curl -sL https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh | sh
sudo mv crossplane /usr/local/bin/

echo "=== Initializing build submodules ==="
make submodules

echo "=== Pre-fetching Go module cache ==="
go mod download

echo "=== Post-create setup complete ==="
