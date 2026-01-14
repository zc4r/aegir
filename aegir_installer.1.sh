#!/bin/sh
# aegir_installer.1.sh
# Ægir Cherry Installer v1
# Usage: ./aegir_installer.1.sh [--help] [--dry-run] [--yes] [--noninteractive] [--verbose] [--bump] [--install-service] [--github-repo owner/name] [--skip-gh]
set -eu
# POSIX compatible sh; avoid bashisms for portability

# -------------------------
# Configuration defaults
# -------------------------
WORKDIR="${WORKDIR:-$HOME/ægir_card}"
REPO_NAME="${REPO_NAME:-aegir}"
GITHUB_REPO="${GITHUB_REPO:-}"   # optional override like zc4r/aegir
REMOTE_USER="${REMOTE_USER:-z}"
REMOTE_HOST="${REMOTE_HOST:-alkul.myrkur.net}"
REMOTE_DIR="${REMOTE_DIR:-/home/zc4r/ægir_card}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
DRY_RUN=0
ASSUME_YES=0
NONINTERACTIVE=0
VERBOSE=0
INSTALL_SERVICE=0
SKIP_GH=0
BUMP=0

# -------------------------
# Helpers
# -------------------------
log() {
  msg="$1"
  printf '%s\n' "$msg"
  logger -t aegir_installer "$msg" || true
}
die() { log "FATAL: $1"; exit 1; }
info() { [ "$VERBOSE" -eq 1 ] && log "INFO: $1"; }

confirm() {
  if [ "$ASSUME_YES" -eq 1 ] || [ "$NONINTERACTIVE" -eq 1 ]; then
    return 0
  fi
  printf "%s [Y/n]: " "$1"
  read -r ans || return 1
  ans="${ans:-Y}"
  case "$ans" in
    Y|y) return 0 ;;
    *) return 1 ;;
  esac
}

# detect package manager
detect_pkg_mgr() {
  if command -v pkg >/dev/null 2>&1; then echo "pkg"; return; fi
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v brew >/dev/null 2>&1; then echo "brew"; return; fi
  echo "unknown"
}

install_pkg() {
  pkg="$1"
  mgr="$(detect_pkg_mgr)"
  info "Installing $pkg via $mgr"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] install $pkg via $mgr"
    return 0
  fi
  case "$mgr" in
    pkg) sudo pkg install -y "$pkg" ;;
    apt) sudo apt-get update -y && sudo apt-get install -y "$pkg" ;;
    dnf) sudo dnf install -y "$pkg" ;;
    yum) sudo yum install -y "$pkg" ;;
    brew) brew install "$pkg" ;;
    *) die "No supported package manager found to install $pkg" ;;
  esac
}

# -------------------------
# Prerequisite downloader
# -------------------------
PREREQS="git curl ssh rsync node npm ffmpeg gh python3"
check_and_install_prereqs() {
  log "Checking prerequisites..."
  for p in $PREREQS; do
    if command -v "$p" >/dev/null 2>&1; then
      info "Found $p at $(command -v $p)"
      continue
    fi
    log "Prerequisite $p not found."
    if [ "$NONINTERACTIVE" -eq 1 ]; then
      log "Noninteractive mode: attempting to install $p"
      install_pkg "$p"
    else
      if confirm "Install $p now?"; then
        install_pkg "$p"
      else
        log "Skipping $p; this may cause failures later"
      fi
    fi
  done
  log "Prerequisite check complete."
}

# -------------------------
# Git bootstrap
# -------------------------
ensure_git_bootstrap() {
  cd "$WORKDIR" || die "Cannot cd to $WORKDIR"
  if [ ! -d .git ]; then
    log "Initializing git repository (main)"
    git init -b main
  else
    info ".git exists, skipping init"
  fi

  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    log "No commits found; creating bootstrap commit"
    echo "# Ægir pipeline" > README.md
    git add README.md
    git commit -m "Bootstrap Ægir repo"
  else
    info "Repository already has commits"
  fi
}

# -------------------------
# GitHub remote creation
# -------------------------
create_github_remote() {
  if [ "$SKIP_GH" -eq 1 ]; then
    info "Skipping GitHub remote creation"
    return 0
  fi
  if [ -n "$GITHUB_REPO" ]; then
    repo_arg="--repo $GITHUB_REPO"
  else
    # default to owner/repo if gh knows the user
    repo_arg="--public --source=. --remote=origin --push"
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    info "Remote origin already exists: $(git remote get-url origin)"
    return 0
  fi

  log "Creating GitHub repository via gh"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] gh repo create $repo_arg"
    return 0
  fi

  # Use gh to create repo; if GITHUB_REPO provided, create that exact name
  if [ -n "$GITHUB_REPO" ]; then
    gh repo create "$GITHUB_REPO" --public --source=. --remote=origin --push || die "gh repo create failed"
  else
    gh repo create --public --source=. --remote=origin --push || die "gh repo create failed"
  fi
}

# -------------------------
# Auto increment helper
# -------------------------
next_version_name() {
  base="$1"   # e.g. aegir_installer
  latest=$(ls "${base}."*.sh 2>/dev/null | sed -E "s/.*\.([0-9]+)\.sh/\1/" | sort -n | tail -n1 || true)
  if [ -z "$latest" ]; then
    echo "${base}.0.sh"
  else
    echo "${base}.$((latest + 1)).sh"
  fi
}

bump_version() {
  base="$1"
  newfile=$(next_version_name "$base")
  cp "$base.sh" "$newfile"
  chmod +x "$newfile"
  git add "$newfile" "$base.sh"
  git commit -m "Upgrade $base to $(basename "$newfile")"
  git push
  log "Bumped $base to $newfile and pushed"
}

# -------------------------
# Deploy function
# -------------------------
deploy_to_server() {
  log "Deploying to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] rsync build/ ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/build/"
    return 0
  fi
  rsync -avz --delete build/ "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/build/"
  rsync -avz --delete assets/ "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/assets/"
  ssh "${REMOTE_USER}@${REMOTE_HOST}" "cd ${REMOTE_DIR} && ./aegir_installer.sh --restart-service || true"
  log "Deploy complete"
}

# -------------------------
# Service install helper
# -------------------------
install_remote_service() {
  log "Installing remote service (rc.d/systemd) if requested"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] install service on ${REMOTE_HOST}"
    return 0
  fi
  # Example: copy a simple rc.d script for FreeBSD or systemd unit for Linux
  if ssh "${REMOTE_USER}@${REMOTE_HOST}" "test -d /etc/init.d" >/dev/null 2>&1; then
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "sudo cp ${REMOTE_DIR}/deploy/aegir_ws.rc /usr/local/etc/rc.d/aegir_ws && sudo chmod +x /usr/local/etc/rc.d/aegir_ws && sudo service aegir_ws enable || true"
  else
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "sudo cp ${REMOTE_DIR}/deploy/aegir_ws.service /etc/systemd/system/aegir_ws.service && sudo systemctl daemon-reload && sudo systemctl enable aegir_ws || true"
  fi
  log "Remote service install attempted"
}

# -------------------------
# Argument parsing
# -------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --noninteractive) NONINTERACTIVE=1; ASSUME_YES=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --install-service) INSTALL_SERVICE=1; shift ;;
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --skip-gh) SKIP_GH=1; shift ;;
    --bump) BUMP=1; shift ;;
    --restart-service) ssh "${REMOTE_USER}@${REMOTE_HOST}" "sudo service aegir_ws restart || sudo systemctl restart aegir_ws" && exit 0 ;;
    --help) sed -n '1,200p' "$0"; exit 0 ;;
    *) log "Unknown arg $1"; shift ;;
  esac
done

# -------------------------
# Main flow
# -------------------------
log "Starting Ægir installer v1"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

check_and_install_prereqs
ensure_git_bootstrap

# commit any untracked files that look like part of the project
if git status --porcelain | grep -q '??'; then
  info "Staging untracked project files"
  git add .github aegir_installer.* aegir_prereqs.sh takki.html 2>/dev/null || true
  if git status --porcelain | grep -q '??'; then
    info "Some files remain untracked; listing:"
    git status --porcelain | sed -n '1,200p'
  fi
  if git diff --cached --quiet; then
    info "No staged changes"
  else
    git commit -m "Add project files" || true
    git push || true
  fi
fi

create_github_remote

if [ "$BUMP" -eq 1 ]; then
  bump_version "aegir_installer"
  exit 0
fi

# Build step placeholder
if [ -f Makefile ]; then
  log "Running make deploy"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] make deploy"
  else
    make deploy || log "make deploy returned nonzero"
  fi
else
  log "No Makefile found; skipping build"
fi

# Deploy
deploy_to_server

if [ "$INSTALL_SERVICE" -eq 1 ]; then
  install_remote_service
fi

log "Ægir installer finished successfully"
exit 0

