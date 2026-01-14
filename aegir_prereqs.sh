# === Cherry Prerequisite Downloader ===
# Always include this block at the top of your cherry scripts

log(){ logger -t cherry_prereqs "$1"; echo "$1"; }

# List of prerequisites
PREREQS="git node npm ffmpeg curl python3 gh"

for pkg in $PREREQS; do
  if ! command -v "$pkg" >/dev/null 2>&1; then
    echo "Prerequisite '$pkg' not found."
    printf "Install '$pkg' now? [Y/n]: "
    read -r ans
    ans="${ans:-Y}"
    if [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
      log "Installing $pkg..."
      # FreeBSD pkg always fetches newest available version
      sudo pkg install -y "$pkg" || { log "Failed to install $pkg"; exit 1; }
    else
      log "Skipping $pkg (may cause failures)"
    fi
  else
    log "Found $pkg: $(command -v $pkg)"
  fi
done

log "All prerequisites checked and installed."
# === End Cherry Prerequisite Downloader ===

