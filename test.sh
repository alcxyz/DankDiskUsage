#!/usr/bin/env bash
set -euo pipefail

python3 -m unittest discover -s tests -p 'test_*.py'
node --test tests/test_*.js

# Keep plugin-specific checks here so the shared CI workflow stays aligned.
go vet ./...
