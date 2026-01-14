#!/bin/sh
# aegir_installer.sh — idempotent installer, interactive defaults, syslogged
# Usage:
#   ./aegir_installer.sh LEFT_URL="..." RIGHT_URL="..." WS_PORT=8080
set -eu

# --- defaults (ghostly auto-incremented if absent)
DEFAULT_WORKDIR="$HOME/ægir_card"
DEFAULT_WS_PORT=8080
DEFAULT_CRON_MARK="# aegir_daily_noon"

# --- read env or prompt
WORKDIR="${WORKDIR:-$DEFAULT_WORKDIR}"
ASSETS="$WORKDIR/assets"
BUILD="$WORKDIR/build"
LOGS="$WORKDIR/logs"

# interactive prompt for URLs if not provided
if [ -z "${LEFT_URL:-}" ]; then
  printf "Left image URL not provided. Enter LEFT_URL (or leave blank to abort): "
  read -r LEFT_URL
  if [ -z "$LEFT_URL" ]; then
    echo "Aborted: LEFT_URL required." >&2
    exit 1
  fi
fi

if [ -z "${RIGHT_URL:-}" ]; then
  printf "Right image URL not provided. Enter RIGHT_URL (or leave blank to abort): "
  read -r RIGHT_URL
  if [ -z "$RIGHT_URL" ]; then
    echo "Aborted: RIGHT_URL required." >&2
    exit 1
  fi
fi

WS_PORT="${WS_PORT:-$DEFAULT_WS_PORT}"

# create layout idempotently
mkdir -p "$ASSETS" "$BUILD" "$LOGS"

log() {
  # syslog via logger; also echo to stdout
  logger -t aegir_installer "$1"
  echo "$1"
}

log "Installer started. Workdir: $WORKDIR"

# helper: write file only if content changed
write_if_changed() {
  dest="$1"; shift
  tmp="$(mktemp)"
  cat > "$tmp" "$@"
  if [ -f "$dest" ]; then
    if cmp -s "$tmp" "$dest"; then
      rm -f "$tmp"
      return 0
    fi
  fi
  mv "$tmp" "$dest"
  chmod 644 "$dest"
  log "Wrote $dest"
}

# Download images idempotently
download_image() {
  url="$1"; out="$2"
  if [ -f "$out" ]; then
    log "Image exists: $out (skipping download)"
    return 0
  fi
  log "Downloading $url -> $out"
  curl -fSL -o "$out" "$url" || { log "Download failed: $url"; exit 1; }
}

download_image "$LEFT_URL" "$ASSETS/left_half.png"
download_image "$RIGHT_URL" "$ASSETS/right_half.png"

# Write Makefile (idempotent)
write_if_changed "$WORKDIR/Makefile" <<'MAKEFILE'
# (Makefile content — same modular Makefile as before, with syslog hooks)
SHELL := /bin/sh
.PHONY: all download synth-audio render-video build-widget deploy install-cron clean

WORKDIR := $(CURDIR)
ASSETS := $(WORKDIR)/assets
BUILD := $(WORKDIR)/build
LOGS := $(WORKDIR)/logs

LEFT_IMG := $(ASSETS)/left_half.png
RIGHT_IMG := $(ASSETS)/right_half.png
AUDIO := $(BUILD)/aegir_click_storm.wav
VIDEO := $(BUILD)/aegir_widget_4k.mp4
WIDGET := $(BUILD)/widget.html
CRON_MARK := "# aegir_daily_noon"

# helper to syslog from Makefile
SYSLOG := logger -t aegir_make

all: download synth-audio render-video build-widget
	@$(SYSLOG) "make all completed"
	@echo "Done. Outputs in $(BUILD)"

download:
	@mkdir -p $(ASSETS) $(BUILD) $(LOGS)
	@if [ -z "$(LEFT_URL)" ] || [ -z "$(RIGHT_URL)" ]; then \
	  echo "ERROR: set LEFT_URL and RIGHT_URL when calling make download"; \
	  exit 1; \
	fi
	@curl -fSL -o "$(LEFT_IMG)" "$(LEFT_URL)"
	@curl -fSL -o "$(RIGHT_IMG)" "$(RIGHT_URL)"
	@$(SYSLOG) "Downloaded images"

synth-audio:
	@mkdir -p $(BUILD)
	@$(SYSLOG) "Synthesizing audio"
	@ffmpeg -y -hide_banner -loglevel error -f lavfi -i "sine=frequency=1200:duration=0.06" -af "adelay=0|0,volume=0.9,afade=t=out:st=0.03:d=0.03" $(BUILD)/click_raw.wav
	@ffmpeg -y -hide_banner -loglevel error -f lavfi -i "anoisesrc=color=brown:duration=12" -af "bandpass=f=900:w=0.8,highpass=f=80,volume=0.6,tremolo=f=0.25:d=0.6" $(BUILD)/storm_raw.wav
	@ffmpeg -y -hide_banner -loglevel error -f lavfi -i "anoisesrc=color=white:duration=0.06" -af "bandpass=f=2000:w=1.2,volume=0.25,afade=t=out:st=0.03:d=0.03" $(BUILD)/click_noise.wav
	@ffmpeg -y -hide_banner -loglevel error -i $(BUILD)/click_raw.wav -i $(BUILD)/click_noise.wav -filter_complex "[0:a][1:a]amix=inputs=2:weights=1 0.6,volume=1.2" $(BUILD)/click_final.wav
	@ffmpeg -y -hide_banner -loglevel error -i $(BUILD)/storm_raw.wav -i $(BUILD)/click_final.wav -filter_complex "[1:a]adelay=0|0,volume=1.0[click];[0:a]loudnorm=I=-16:TP=-1.5:LRA=7,afftdn=nf=-25,highpass=f=40,lowpass=f=12000[storm];[storm][click]amix=inputs=2:weights=1 1,acompressor=threshold=-18:ratio=3:attack=20:release=250" -c:a pcm_s16le -ar 48000 -ac 2 "$(AUDIO)"
	@rm -f $(BUILD)/click_raw.wav $(BUILD)/click_noise.wav $(BUILD)/click_final.wav $(BUILD)/storm_raw.wav
	@$(SYSLOG) "Audio synthesized: $(AUDIO)"

render-video:
	@mkdir -p $(BUILD)
	@if [ ! -f "$(LEFT_IMG)" ] || [ ! -f "$(RIGHT_IMG)" ]; then \
	  echo "ERROR: left/right images missing. Run: make download LEFT_URL='...' RIGHT_URL='...'"; \
	  exit 1; \
	fi
	@$(SYSLOG) "Rendering video"
	@ffmpeg -y -hide_banner -loglevel error -loop 1 -t 10 -i "$(RIGHT_IMG)" -filter_complex "scale=3840:2160,format=yuv420p,zoompan=z='if(lte(on,1),1.0,zoom+0.0008)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=250,hue='h=2*PI*t/6:s=1',eq=contrast=1.05:brightness=0.01:saturation=1.15" -c:v libx264 -crf 18 -preset slow $(BUILD)/bg.mp4
	@ffmpeg -y -hide_banner -loglevel error -i $(BUILD)/bg.mp4 -loop 1 -i "$(LEFT_IMG)" -filter_complex "[1:v]scale=1920:2160,format=rgba[card];[0:v][card]overlay=x='if(lt(t,0.6), -w + (t/0.6)*w, if(lt(t,6), 0, (t-6)/0.6*w))':y=0:format=auto,format=yuv420p" -c:v libx264 -crf 18 -preset slow -t 10 $(BUILD)/video_noaudio.mp4
	@ffmpeg -y -hide_banner -loglevel error -i $(BUILD)/video_noaudio.mp4 -i "$(AUDIO)" -c:v copy -c:a aac -b:a 192k -shortest "$(VIDEO)"
	@$(SYSLOG) "Video rendered: $(VIDEO)"

build-widget:
	@mkdir -p $(BUILD)
	@cp -f widget.html $(BUILD)/widget.html
	@$(SYSLOG) "Widget copied to $(BUILD)/widget.html"

deploy: all
	@$(SYSLOG) "Deploy completed at $$(date -u)"
	@echo "Deploy finished."

install-cron:
	@echo "Installing cron job for daily noon deploy..."
	@CRON_CMD="0 12 * * * cd $(WORKDIR) && /usr/bin/make -s deploy >> $(WORKDIR)/logs/deploy.log 2>&1"
	@(crontab -l 2>/dev/null | sed '/$(CRON_MARK)/d'; echo "$(CRON_MARK)"; echo "$$CRON_CMD") | crontab -
	@$(SYSLOG) "Cron installed"

clean:
	@rm -rf $(BUILD) $(ASSETS) $(LOGS)
	@$(SYSLOG) "Cleaned"
MAKEFILE

# --- write WebSocket server (Node.js) idempotently
write_if_changed "$WORKDIR/ws_server.js" <<'NODE'
/*
  ws_server.js — simple WebSocket server + config endpoint
  Usage: node ws_server.js [port]
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');

const PORT = process.env.PORT || process.argv[2] || 8080;
const BUILD_DIR = path.resolve(__dirname, 'build');

const server = http.createServer((req, res) => {
  if (req.url === '/config.json') {
    // dynamic config (auto-refresh clients can poll or receive via WS)
    const cfg = {
      preset: 'hushed',
      updated: new Date().toISOString()
    };
    res.writeHead(200, {'Content-Type':'application/json'});
    res.end(JSON.stringify(cfg));
    return;
  }
  // serve static files from build
  let filePath = path.join(BUILD_DIR, req.url === '/' ? 'widget.html' : req.url);
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    const ext = path.extname(filePath).toLowerCase();
    const mime = {'.html':'text/html','.js':'application/javascript','.css':'text/css','.png':'image/png','.wav':'audio/wav','.mp4':'video/mp4'}[ext] || 'application/octet-stream';
    res.writeHead(200, {'Content-Type': mime});
    res.end(data);
  });
});

const wss = new WebSocket.Server({ server });
let clients = new Set();

wss.on('connection', (ws, req) => {
  clients.add(ws);
  ws.on('message', (msg) => {
    // expect JSON messages: {type:'toggle', state:true} or {type:'config', ...}
    try {
      const data = JSON.parse(msg.toString());
      if (data && data.type) {
        // broadcast to all clients
        const out = JSON.stringify(data);
        for (const c of clients) {
          if (c.readyState === WebSocket.OPEN) c.send(out);
        }
      }
    } catch (e) {
      // ignore parse errors
    }
  });
  ws.on('close', () => clients.delete(ws));
});

server.listen(PORT, () => {
  console.log(`Ægir WS server listening on ${PORT}`);
});
NODE

# --- write widget.html (updated to use WebSocket)
write_if_changed "$WORKDIR/widget.html" <<'HTML'
<!doctype html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ægir Widget (WS)</title></head>
<body style="margin:0;background:#050507;color:#eee">
<canvas id="canvas" width="3840" height="2160" style="width:100vw;height:100vh;display:block"></canvas>
<div style="position:fixed;left:16px;top:16px;z-index:9999">
  <button id="toggle">Toggle Slide</button>
  <button id="play">Play</button>
  <select id="preset"><option value="hushed">Hushed Abyss</option><option value="razor">Razor Storm</option><option value="neptune">Neptune's Pulse</option></select>
</div>
<script>
/* Minimal widget: loads assets from /assets, connects to ws server at same host:PORT,
   broadcasts toggle events as JSON {type:'toggle', state:true}, and applies incoming events.
   Replace WS_URL if server runs elsewhere.
*/
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
const left = new Image(); left.src = '/assets/left_half.png';
const right = new Image(); right.src = '/assets/right_half.png';
let active = false;
function draw(){
  const w = canvas.width, h = canvas.height;
  ctx.clearRect(0,0,w,h);
  // matte
  ctx.fillStyle = '#220005'; ctx.fillRect(0,0,w/2,h);
  // right half
  if (right.complete) ctx.drawImage(right, w/2, 0, w/2, h);
  // left half
  const x = active ? w/2 : 0;
  if (left.complete) ctx.drawImage(left, x, 0, w/2, h);
}
left.onload = right.onload = draw;
setInterval(draw, 1000/30);

// WebSocket connection (auto-reconnect)
const WS_HOST = (location.hostname || 'localhost');
const WS_PORT = (location.port && location.port !== '0') ? location.port : 8080;
const WS_URL = `ws://${WS_HOST}:${WS_PORT}`;
let ws;
function connect(){
  ws = new WebSocket(WS_URL);
  ws.onopen = ()=> console.log('ws open');
  ws.onmessage = (ev)=> {
    try {
      const msg = JSON.parse(ev.data);
      if (msg.type === 'toggle') { active = !!msg.state; draw(); }
      if (msg.type === 'config') { if (msg.preset) document.getElementById('preset').value = msg.preset; }
    } catch(e){}
  };
  ws.onclose = ()=> { console.log('ws closed, reconnecting in 2s'); setTimeout(connect,2000); };
}
connect();

// UI
document.getElementById('toggle').addEventListener('click', ()=> {
  active = !active; draw();
  const payload = JSON.stringify({type:'toggle', state: active});
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(payload);
});
document.getElementById('play').addEventListener('click', ()=> {
  const a = new Audio('/build/aegir_click_storm.wav'); a.play().catch(()=>console.warn('play blocked'));
});
</script>
</body>
</html>
HTML

# --- make helper executable
chmod +x "$WORKDIR/ws_server.js" || true
chmod -R 755 "$WORKDIR"

# --- install cron via Makefile
cd "$WORKDIR"
make install-cron LEFT_URL="$LEFT_URL" RIGHT_URL="$RIGHT_URL" || log "make install-cron failed"

log "Installer finished. To run WS server: node $WORKDIR/ws_server.js $WS_PORT"
log "To test widget: python3 -m http.server --directory $WORKDIR/build 8000 and open http://localhost:8000/widget.html"

