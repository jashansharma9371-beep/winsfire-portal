#!/usr/bin/env bash
# Usage: ./push.sh https://github.com/YOUR-USERNAME/winsfire-portal.git
set -e
if [ -z "$1" ]; then echo "Usage: ./push.sh https://github.com/YOUR-USERNAME/winsfire-portal.git"; exit 1; fi
git init -q 2>/dev/null || true
git add .
git commit -m "WinsFire order portal" || true
git branch -M main
git remote remove origin 2>/dev/null || true
git remote add origin "$1"
git push -u origin main
