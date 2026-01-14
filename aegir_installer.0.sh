cat > /tmp/aegir_installer.sh <<'SH' && chmod +x /tmp/aegir_installer.sh && /tmp/aegir_installer.sh
#!/bin/sh
# Minimal, idempotent, interactive installer for FreeBSD 15.0
set -eu
log(){ logger -t aegir_installer "$1"; echo "$1"; }

# Include prerequisites
. ./cherry_prereqs.sh   # or paste the block inline

# Continue with your cherry pipeline...

WORKDIR="${WORKDIR:-$HOME/ægir_card}"
ASSETS="$WORKDIR/assets"
BUILD="$WORKDIR/build"
LOGS="$WORKDIR/logs"
WS_PORT="${WS_PORT:-8080}"
CRON_MARK="# aegir_daily_noon"

prompt_if_empty(){
  varname="$1"; prompt="$2"
  eval val=\$$varname
  if [ -z "$val" ]; then
    printf "%s: " "$prompt"
    read -r val
    if [ -z "$val" ]; then
      echo "Aborted: $varname required." >&2
      exit 1
    fi
    eval "$varname=\$val"
  fi
}

printf "This installer will create a local project in %s and will NOT run sudo.\n" "$WORKDIR"
prompt_if_empty LEFT_URL "Left image URL (LEFT_URL)"
prompt_if_empty RIGHT_URL "Right image URL (RIGHT_URL)"
printf "Public domain for TLS (optional, press Enter to skip): "
read -r EXAMPLE_DOMAIN || true
printf "Email for Certbot (optional, press Enter to skip): "
read -r EMAIL || true
printf "Privileged token for admin actions (AEGIR_TOKEN): "
read -r AEGIR_TOKEN || true
printf "Service type (rc.d recommended for FreeBSD) [rc.d]: "
read -r SERVICE_TYPE || true
SERVICE_TYPE="${SERVICE_TYPE:-rc.d}"

log "Creating project at: $WORKDIR"
mkdir -p "$ASSETS" "$BUILD" "$LOGS"

write_if_changed(){
  dest="$1"; shift
  tmp="$(mktemp)"
  cat > "$tmp" "$@"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
  mv "$tmp" "$dest"
  chmod 644 "$dest"
  log "Wrote $dest"
}

download_image(){
  url="$1"; out="$2"
  if [ -f "$out" ]; then log "Image exists: $out (skipping)"; return 0; fi
  log "Downloading $url -> $out"
  curl -fSL -o "$out" "$url" || { log "Download failed: $url"; exit 1; }
}

download_image "$LEFT_URL" "$ASSETS/left_half.png"
download_image "$RIGHT_URL" "$ASSETS/right_half.png"

# Makefile (condensed, idempotent)
write_if_changed "$WORKDIR/Makefile" <<'MAKEFILE'
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
SYSLOG := logger -t aegir_make

all: download synth-audio render-video build-widget
	@$(SYSLOG) "make all completed"

download:
	@mkdir -p $(ASSETS) $(BUILD) $(LOGS)
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

install-cron:
	@CRON_CMD="0 12 * * * cd $(WORKDIR) && /usr/bin/make -s deploy >> $(WORKDIR)/logs/deploy.log 2>&1"
	@(crontab -l 2>/dev/null | sed '/$(CRON_MARK)/d'; echo "$(CRON_MARK)"; echo "$$CRON_CMD") | crontab -
	@$(SYSLOG) "Cron installed"

clean:
	@rm -rf $(BUILD) $(ASSETS) $(LOGS)
	@$(SYSLOG) "Cleaned"
MAKEFILE

# Minimal WebSocket server (token-checked, config poller)
write_if_changed "$WORKDIR/ws_server.js" <<'NODE'
/* Minimal WS server for Ægir (drop-in) */
const http = require('http'), fs = require('fs'), path = require('path');
const WebSocket = require('ws');
const fetch = (...args) => import('node-fetch').then(m=>m.default(...args));
const PORT = process.env.PORT || process.argv[2] || 8080;
const BUILD_DIR = path.resolve(__dirname,'build');
const SECRET = process.env.AEGIR_TOKEN || process.env.AEGIR_TOKEN || '';
let currentConfig = { preset:'hushed', updated:new Date().toISOString() };
const server = http.createServer((req,res)=>{
  if(req.url==='/config.json'){ res.writeHead(200,{'Content-Type':'application/json'}); res.end(JSON.stringify(currentConfig)); return; }
  let file = path.join(BUILD_DIR, req.url==='/'?'widget.html':req.url);
  fs.readFile(file,(e,d)=>{ if(e){ res.writeHead(404); res.end('Not found'); return;} res.writeHead(200); res.end(d); });
});
const wss = new WebSocket.Server({server});
let clients=new Set();
wss.on('connection', ws=>{ clients.add(ws); ws.on('message', m=>{ try{ const data=JSON.parse(m.toString()); if(data.token && data.token===process.env.AEGIR_TOKEN){ if(data.type==='config'&&data.preset){ currentConfig.preset=data.preset; currentConfig.updated=new Date().toISOString(); broadcast({type:'config',preset:currentConfig.preset,updated:currentConfig.updated}); } return; } if(data.type==='toggle'){ broadcast({type:'toggle',state:!!data.state}); } }catch(e){} }); ws.on('close',()=>clients.delete(ws)); ws.send(JSON.stringify({type:'config',preset:currentConfig.preset,updated:currentConfig.updated})); });
function broadcast(o){ const m=JSON.stringify(o); for(const c of clients) if(c.readyState===WebSocket.OPEN) c.send(m); }
server.listen(PORT,()=>console.log('Ægir WS server listening on',PORT));
NODE

# Minimal widget (WS-enabled)
write_if_changed "$WORKDIR/widget.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ægir Widget</title></head><body style="margin:0;background:#050507;color:#eee"><canvas id="c" width="3840" height="2160" style="width:100vw;height:100vh;display:block"></canvas><div style="position:fixed;left:16px;top:16px;z-index:9999"><button id="t">Toggle</button><button id="p">Play</button></div><script>const c=document.getElementById('c'),ctx=c.getContext('2d');const L=new Image();L.src='/assets/left_half.png';const R=new Image();R.src='/assets/right_half.png';let active=false;function draw(){const w=c.width,h=c.height;ctx.clearRect(0,0,w,h);ctx.fillStyle='#220005';ctx.fillRect(0,0,w/2,h);if(R.complete)ctx.drawImage(R,w/2,0,w/2,h);const x=active? w/2:0; if(L.complete)ctx.drawImage(L,x,0,w/2,h);}setInterval(draw,1000/30);const ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host);ws.onmessage=e=>{try{const m=JSON.parse(e.data); if(m.type==='toggle'){active=!!m.state;} if(m.type==='config'){}}catch{} };document.getElementById('t').addEventListener('click',()=>{active=!active; ws.send(JSON.stringify({type:'toggle',state:active}));});document.getElementById('p').addEventListener('click',()=>{new Audio('/build/aegir_click_storm.wav').play().catch(()=>{});});</script></body></html>
HTML

# FreeBSD rc.d script (write to WORKDIR for review; you must copy to /usr/local/etc/rc.d manually)
write_if_changed "$WORKDIR/aegir_ws.rc" <<'RC'
#!/bin/sh
# PROVIDE: aegir_ws
# REQUIRE: NETWORKING
. /etc/rc.subr
name="aegir_ws"
rcvar=aegir_ws_enable
aegir_ws_enable=${aegir_ws_enable:-"NO"}
command="/usr/local/bin/node"
command_args="$WORKDIR/ws_server.js $WS_PORT"
load_rc_config $name
run_rc_command "$1"
RC

# Logrotate snippet
write_if_changed "$WORKDIR/logrotate_aegir.conf" <<'LOG'
$WORKDIR/logs/*.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  create 0640 $(whoami) $(whoami)
}
LOG

# helper script
write_if_changed "$WORKDIR/install_helper.sh" <<'HELP'
#!/bin/sh
cd "$(dirname "$0")"
make download LEFT_URL="${LEFT_URL:-}" RIGHT_URL="${RIGHT_URL:-}"
make deploy
HELP
chmod +x "$WORKDIR/install_helper.sh"

# Install node deps locally if npm exists
cd "$WORKDIR"
if command -v npm >/dev/null 2>&1; then
  if [ ! -d node_modules ]; then
    echo "Installing node deps locally (ws, node-fetch)..."
    npm init -y >/dev/null 2>&1 || true
    npm install ws node-fetch >/dev/null 2>&1 || true
  fi
else
  log "npm not found; please install Node.js/npm to run the WS server"
fi

# Install cron entry for current user
make install-cron LEFT_URL="$LEFT_URL" RIGHT_URL="$RIGHT_URL" || log "make install-cron failed"

log "Installer finished. Next steps (manual, non-destructive):"
echo "  1) Review files in $WORKDIR"
echo "  2) To run WS server now: node $WORKDIR/ws_server.js $WS_PORT"
echo "  3) To install rc.d script system-wide (FreeBSD): sudo cp $WORKDIR/aegir_ws.rc /usr/local/etc/rc.d/aegir_ws && sudo chmod +x /usr/local/etc/rc.d/aegir_ws && sudo sysrc aegir_ws_enable=YES && sudo service aegir_ws start"
echo "  4) To serve widget locally: python3 -m http.server --directory $WORKDIR/build 8000"
echo "  5) If you want TLS and reverse proxy, configure nginx with the provided snippet in $WORKDIR/build/nginx_aegir.conf and obtain certs with certbot"
log "Done."
SH

