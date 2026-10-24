import YouTubeCastReceiver, { Player } from 'yt-cast-receiver';

let stopTimer = null;

class RoundPlayer extends Player {
  async doPlay(video, position) {
    if (stopTimer) {
      clearTimeout(stopTimer);
      stopTimer = null;
    }
    const pos = position || 0;
    console.log(`[Cast Receiver] Play requested: ${video.id} ("${video.title || 'Unknown'}") @ ${pos}s`);
    try {
      // 1. Dispatch directly to Playback Manager with title and artist
      const playData = {
        title: video.title || 'Incoming Video',
        artist: video.author || video.artist || 'YouTube Cast',
        position: pos,
        source: 'cast',   // lets the daemon scope "stop casting" to this track only
        music: (video.client && video.client.key) === 'YTMUSIC'   // YouTube Music: play as audio with the cover
      };
      await fetch(`http://127.0.0.1:8000/api/play/${video.id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(playData)
      });
      console.log(`[Cast Receiver] Successfully dispatched ${video.id} to Playback Manager.`);

      // 2. Poll until track is actively ready and playing
      // This keeps the receiver in LOADING state on the sender's phone until playback is actually streaming!
      const startTime = Date.now();
      const timeoutMs = 30000; // streams start in a few seconds now (no download)
      while (Date.now() - startTime < timeoutMs) {
        try {
          const res = await fetch('http://127.0.0.1:8000/api/state');
          if (res.ok) {
            const st = await res.json();
            // hud_synced = the HUD confirmed (via /api/hud/state) that mpv is on this track in the
            // intended play state - not the daemon's own wall-clock guess.
            if (st.active_video_id === video.id && st.is_playing && !st.caching_video_id && st.hud_synced) {
              console.log(`[Cast Receiver] Track ${video.id} is live on the HUD. Reporting PLAYING to phone.`);
              return true;
            }
          }
        } catch (_) {}
        await new Promise((r) => setTimeout(r, 400));
      }

      console.log(`[Cast Receiver] Timeout waiting for ${video.id} to be ready, proceeding with play confirmation.`);
      return true;
    } catch (e) {
      console.error('[Cast Receiver] Error notifying playback manager:', e);
      return false;
    }
  }

  async doPause() {
    console.log('[Cast Receiver] Pause requested');
    try {
      await fetch('http://127.0.0.1:8000/api/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'pause' })
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  async doResume() {
    console.log('[Cast Receiver] Resume requested');
    try {
      await fetch('http://127.0.0.1:8000/api/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'play' })
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  async doStop() {
    console.log('[Cast Receiver] Stop / Disconnect requested');
    if (stopTimer) clearTimeout(stopTimer);
    stopTimer = setTimeout(async () => {
      try {
        await fetch('http://127.0.0.1:8000/api/control', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'stop_cast' })
        });
      } catch (e) {}
    }, 200);
    return true;
  }

  async doSeek(position) {
    console.log(`[Cast Receiver] Seek to ${position}s`);
    try {
      await fetch('http://127.0.0.1:8000/api/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'seek', seek_seconds: position })
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  async doSetVolume(volume) {
    console.log(`[Cast Receiver] Set volume: ${volume.level}%`);
    try {
      await fetch('http://127.0.0.1:8000/api/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'volume', value: volume.level })
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  async doGetVolume() {
    try {
      const res = await fetch('http://127.0.0.1:8000/api/state');
      if (res.ok) {
        const d = await res.json();
        return { level: Math.round(d.volume !== undefined ? d.volume : 80), muted: false };
      }
    } catch (_) {}
    return { level: 80, muted: false };
  }

  async doGetPosition() {
    try {
      const res = await fetch('http://127.0.0.1:8000/api/state');
      if (res.ok) {
        const d = await res.json();
        return Math.round(d.playback_position_s || 0);
      }
    } catch (_) {}
    return 0;
  }

  async doGetDuration() {
    try {
      const res = await fetch('http://127.0.0.1:8000/api/state');
      if (res.ok) {
        const d = await res.json();
        if (d.duration_seconds) return Math.round(d.duration_seconds);
      }
    } catch (_) {}
    return 240;
  }
}

const player = new RoundPlayer();
const receiver = new YouTubeCastReceiver(player, {
  dial: {
    port: 8008,
  },
  device: {
    name: 'Living Room Player',
    screenName: 'Living Room Player',
    brand: 'Raspberry Pi',
    model: 'Round Media Player'
  },
  logLevel: 'INFO'
});

const senders = new Map();
async function reportSenders() {
  const names = [...senders.values()];
  try {
    await fetch('http://127.0.0.1:8000/api/cast/senders', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ senders: names }),
    });
  } catch (e) { console.log(`[Cast Receiver] could not report senders: ${e.message}`); }
}

receiver.on('senderConnect', (sender) => {
  console.log(`[Cast Receiver] Sender connected: ${sender.name}`);
  senders.set(sender.id ?? sender.name, sender.name ?? 'phone');
  reportSenders();
});

receiver.on('senderDisconnect', (sender) => {
  console.log(`[Cast Receiver] Sender disconnected: ${sender.name}`);
  senders.delete(sender.id ?? sender.name);
  reportSenders();
});

console.log('[Cast Receiver] Starting YouTube Cast Receiver on port 8008...');
await receiver.start();
console.log('[Cast Receiver] YouTube Cast Receiver is active and advertising as "Living Room Player"');
