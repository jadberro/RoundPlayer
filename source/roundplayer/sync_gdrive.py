#!/usr/bin/env python3
"""
High-Performance Parallel Google Drive Hi-Fi Remote Indexer & Dynamic Multi-Folder Ingestion
Scans public Google Drive folders in parallel without downloading heavy audio payloads,
indexes full artist/album/track hierarchy into /data/hifi_music/remote_library.json,
discovers native cover art from Google Drive, and alerts the Round HUD and Web Remote instantly.
"""

import os
import sys
import re
import json
import time
import hashlib
import requests
from requests.adapters import HTTPAdapter
import threading
from urllib.parse import urlparse, parse_qs
from concurrent.futures import ThreadPoolExecutor, as_completed
from gdown.download_folder import _parse_embedded_folder_view, _GoogleDriveFile
import hifi_manager

AUDIO_EXTENSIONS = ('.flac', '.wav', '.m4a', '.dsf', '.dff', '.mp3', '.aac', '.alac', '.ogg', '.aiff')
COVER_NAMES = ('cover', 'folder', 'front', 'artwork', 'albumart')
DEFAULT_FOLDER_ID = os.environ.get('ROUNDPLAYER_GDRIVE_FOLDER_ID', '')
DRIVE_FOLDERS_FILE = os.path.join(hifi_manager.HIFI_DIR, 'drive_folders.json')
NOTIFY_WEBHOOK = 'http://127.0.0.1:8000/api/hifi/notify_library_update'

def extract_folder_id(url_or_id: str) -> str:
    """Extracts raw folder ID from any Google Drive URL format or raw ID string."""
    if not url_or_id:
        return DEFAULT_FOLDER_ID
    url_or_id = url_or_id.strip()
    # Match /folders/<ID>
    m = re.search(r'/folders/([a-zA-Z0-9_-]+)', url_or_id)
    if m:
        return m.group(1)
    # Match ?id=<ID>
    if 'id=' in url_or_id:
        parsed = urlparse(url_or_id)
        params = parse_qs(parsed.query)
        if 'id' in params:
            return params['id'][0]
    # Check if raw alphanumeric string
    if re.match(r'^[a-zA-Z0-9_-]{20,}$', url_or_id):
        return url_or_id
    return DEFAULT_FOLDER_ID

def load_drive_folders() -> list:
    """Loads list of registered Google Drive folder IDs."""
    if os.path.isfile(DRIVE_FOLDERS_FILE):
        try:
            with open(DRIVE_FOLDERS_FILE, 'r', encoding='utf-8') as f:
                data = json.load(f)
                if isinstance(data, list) and data:
                    return data
        except Exception as e:
            print(f"[Drive Sync] Error reading {DRIVE_FOLDERS_FILE}: {e}")
    return [DEFAULT_FOLDER_ID] if DEFAULT_FOLDER_ID else []

def save_drive_folders(folders: list):
    """Saves configured Google Drive folders to disk."""
    try:
        os.makedirs(hifi_manager.HIFI_DIR, exist_ok=True)
        # Ensure uniqueness
        seen = set()
        clean = []
        for fid in folders:
            if fid and fid not in seen:
                seen.add(fid)
                clean.append(fid)
        with open(DRIVE_FOLDERS_FILE, 'w', encoding='utf-8') as f:
            json.dump(clean, f, indent=2)
    except Exception as e:
        print(f"[Drive Sync] Error saving {DRIVE_FOLDERS_FILE}: {e}")

def create_session() -> requests.Session:
    """Creates a requests session with connection pooling for parallel workers."""
    s = requests.Session()
    adapter = HTTPAdapter(pool_connections=30, pool_maxsize=30, max_retries=2)
    s.mount('https://', adapter)
    s.mount('http://', adapter)
    s.headers.update({
        'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    })
    return s

def clean_track_title(filename: str) -> str:
    base = os.path.splitext(filename)[0]
    # Remove leading digits e.g. "01 - " or "01 "
    if base.startswith(tuple(f"{i:02d} - " for i in range(1, 100))):
        return base[5:].strip()
    if base.startswith(tuple(f"{i:02d} " for i in range(1, 100))):
        return base[3:].strip()
    if base.startswith(tuple(f"{i:02d}." for i in range(1, 100))):
        return base[3:].strip()
    return base

def parse_track_num(filename: str) -> int:
    try:
        parts = filename.split()
        if parts and parts[0][:2].isdigit():
            return int(parts[0][:2])
        parts_dash = filename.split("-")
        if parts_dash and parts_dash[0].strip().isdigit():
            return int(parts_dash[0].strip())
    except Exception:
        pass
    return 0

def fetch_folder_contents(sess: requests.Session, folder_id: str) -> tuple:
    """Fetches direct children of a Google Drive folder with timeout safety."""
    try:
        name, children = _parse_embedded_folder_view(
            sess=sess,
            folder_id=folder_id,
            verify=True,
            timeout=(6.0, 15.0)
        )
        return folder_id, name, children
    except Exception as e:
        print(f"[Drive Crawler] Warning: error scanning folder {folder_id}: {e}")
        return folder_id, None, []

def notify_system_of_update():
    """Alerts the playback manager and connected clients that library has updated."""
    try:
        requests.post(NOTIFY_WEBHOOK, json={"action": "library_update"}, timeout=3.0)
        print("[Drive Sync] Dispatched live catalog update notification to playback manager.")
    except Exception as e:
        print(f"[Drive Sync] Could not reach notify webhook: {e}")

def async_fetch_covers(gdrive_covers: dict, missing_itunes_covers: list):
    """
    Background worker:
    1. Downloads native Google Drive covers found in album folders directly.
    2. For any remaining albums without covers, queries iTunes search asynchronously.
    Runs in a detached daemon thread so sync() returns in seconds.
    """
    def _worker():
        sess = create_session()
        # 1. First priority: native covers from Google Drive
        for key, gdrive_file_id in gdrive_covers.items():
            dest_path = os.path.join(hifi_manager.COVERS_DIR, f"{key}.jpg")
            if not os.path.isfile(dest_path):
                try:
                    url = f"https://drive.usercontent.google.com/download?id={gdrive_file_id}&export=download"
                    r = sess.get(url, timeout=12)
                    if r.status_code == 200 and len(r.content) > 1024:
                        with open(dest_path, "wb") as f:
                            f.write(r.content)
                        # Small throttle
                        time.sleep(0.05)
                except Exception as e:
                    print(f"[Cover Fetch GDrive Error] {key}: {e}")

        # 2. Second priority: fallback to iTunes search for albums with no GDrive cover
        for artist, album, dest_path in missing_itunes_covers:
            try:
                if not os.path.isfile(dest_path):
                    hifi_manager.fetch_cover_from_itunes(artist, album, dest_path)
                    time.sleep(0.3)
            except Exception as e:
                print(f"[Cover Fetch iTunes Error] {artist} - {album}: {e}")

    threading.Thread(target=_worker, daemon=True).start()

def sync(new_folder_url: str = None) -> dict:
    """
    Scans all configured Google Drive folders using high-speed parallel workers,
    merges track catalog, writes remote_library.json, and returns catalog statistics.
    """
    start_time = time.time()
    hifi_manager.init_dirs()
    folders = load_drive_folders()

    if new_folder_url:
        new_id = extract_folder_id(new_folder_url)
        if new_id not in folders:
            folders.append(new_id)
            save_drive_folders(folders)
            print(f"[Drive Sync] Added new folder ID to configuration: {new_id}")

    print(f"[Drive Sync] Total Google Drive folders to index: {len(folders)}")

    sess = create_session()
    artists_dict = {}
    gdrive_covers = {}  # key -> gdrive_file_id

    # Queue of albums to fetch in parallel: (artist_name, album_name, folder_id)
    albums_to_fetch = []

    for idx, folder_id in enumerate(folders, 1):
        print(f"[{idx}/{len(folders)}] Fetching root directory for folder: {folder_id}...")
        _, root_name, root_children = fetch_folder_contents(sess, folder_id)
        if not root_children:
            print(f"      Warning: No children returned for folder {folder_id}")
            continue

        direct_artists = [c for c in root_children if c[2] == _GoogleDriveFile.TYPE_FOLDER]
        direct_files = [c for c in root_children if c[2] != _GoogleDriveFile.TYPE_FOLDER]
        print(f"      Root has {len(direct_artists)} artist subfolders and {len(direct_files)} files.")

        # Process any direct files in root as "Various Artists / Singles"
        for c_id, c_name, c_type in direct_files:
            ext = os.path.splitext(c_name)[1].lower()
            if ext in AUDIO_EXTENSIONS:
                art = "Various Artists"
                alb = "Singles"
                if art not in artists_dict:
                    artists_dict[art] = {}
                if alb not in artists_dict[art]:
                    artists_dict[art][alb] = []
                rel_track = f"{art}/{alb}/{c_name}"
                tid = hashlib.md5(rel_track.encode("utf-8")).hexdigest()[:12]
                artists_dict[art][alb].append({
                    "track_id": tid,
                    "gdrive_file_id": c_id,
                    "title": clean_track_title(c_name),
                    "artist": art,
                    "album": alb,
                    "track_num": parse_track_num(c_name),
                    "format": ext.replace(".", "").upper(),
                    "file_name": c_name,
                    "rel_path": rel_track,
                    "size_mb": 25.0,
                })

        # Step 1: Parallel fetch of Artist folders -> discover Albums
        print(f"[Drive Sync] Crawling {len(direct_artists)} artist folders in parallel...")
        with ThreadPoolExecutor(max_workers=10) as ex:
            future_to_artist = {
                ex.submit(fetch_folder_contents, sess, a[0]): a[1]
                for a in direct_artists
            }
            for fut in as_completed(future_to_artist):
                artist_name = future_to_artist[fut]
                _, _, artist_children = fut.result()
                for c_id, c_name, c_type in artist_children:
                    if c_type == _GoogleDriveFile.TYPE_FOLDER:
                        albums_to_fetch.append((artist_name, c_name, c_id))
                    else:
                        ext = os.path.splitext(c_name)[1].lower()
                        if ext in AUDIO_EXTENSIONS:
                            alb = "Singles"
                            if artist_name not in artists_dict:
                                artists_dict[artist_name] = {}
                            if alb not in artists_dict[artist_name]:
                                artists_dict[artist_name][alb] = []
                            rel_track = f"{artist_name}/{alb}/{c_name}"
                            tid = hashlib.md5(rel_track.encode("utf-8")).hexdigest()[:12]
                            artists_dict[artist_name][alb].append({
                                "track_id": tid,
                                "gdrive_file_id": c_id,
                                "title": clean_track_title(c_name),
                                "artist": artist_name,
                                "album": alb,
                                "track_num": parse_track_num(c_name),
                                "format": ext.replace(".", "").upper(),
                                "file_name": c_name,
                                "rel_path": rel_track,
                                "size_mb": 25.0,
                            })

    print(f"[Drive Sync] Discovered {len(albums_to_fetch)} album folders across all artists.")

    # Step 2: Parallel fetch of Album folders -> discover Tracks and Covers
    print(f"[Drive Sync] Crawling {len(albums_to_fetch)} albums in parallel...")
    nested_subfolders = []  # For Disc 1, Disc 2, CD 1, etc.

    with ThreadPoolExecutor(max_workers=16) as ex:
        future_to_album = {
            ex.submit(fetch_folder_contents, sess, alb_id): (art, alb)
            for art, alb, alb_id in albums_to_fetch
        }
        for fut in as_completed(future_to_album):
            art, alb = future_to_album[fut]
            _, _, album_children = fut.result()
            
            for c_id, c_name, c_type in album_children:
                if c_type == _GoogleDriveFile.TYPE_FOLDER:
                    # Subfolder inside album (e.g. CD 1 / CD 2 / Disc 1)
                    nested_subfolders.append((art, alb, c_name, c_id))
                    continue

                ext = os.path.splitext(c_name)[1].lower()
                low_name = c_name.lower()

                # Native Google Drive Cover Art detection
                if any(low_name.endswith(img) for img in ('.jpg', '.jpeg', '.png')):
                    if any(k in low_name for k in COVER_NAMES) or len(album_children) <= 30:
                        key = f"{art}_{alb}".replace("/", "_").replace("\\", "_")
                        if key not in gdrive_covers:
                            gdrive_covers[key] = c_id

                # Audio Track detection
                if ext in AUDIO_EXTENSIONS:
                    if art not in artists_dict:
                        artists_dict[art] = {}
                    if alb not in artists_dict[art]:
                        artists_dict[art][alb] = []

                    rel_track = f"{art}/{alb}/{c_name}"
                    tid = hashlib.md5(rel_track.encode("utf-8")).hexdigest()[:12]
                    artists_dict[art][alb].append({
                        "track_id": tid,
                        "gdrive_file_id": c_id,
                        "title": clean_track_title(c_name),
                        "artist": art,
                        "album": alb,
                        "track_num": parse_track_num(c_name),
                        "format": ext.replace(".", "").upper(),
                        "file_name": c_name,
                        "rel_path": rel_track,
                        "size_mb": 25.0,
                    })

    # Step 3: Crawl any nested disc subfolders (if any)
    if nested_subfolders:
        print(f"[Drive Sync] Crawling {len(nested_subfolders)} nested disc subfolders...")
        with ThreadPoolExecutor(max_workers=10) as ex:
            future_to_disc = {
                ex.submit(fetch_folder_contents, sess, disc_id): (art, alb, disc_name)
                for art, alb, disc_name, disc_id in nested_subfolders
            }
            for fut in as_completed(future_to_disc):
                art, alb, disc_name = future_to_disc[fut]
                _, _, disc_children = fut.result()
                for c_id, c_name, c_type in disc_children:
                    if c_type == _GoogleDriveFile.TYPE_FOLDER:
                        continue
                    ext = os.path.splitext(c_name)[1].lower()
                    if ext in AUDIO_EXTENSIONS:
                        if art not in artists_dict:
                            artists_dict[art] = {}
                        if alb not in artists_dict[art]:
                            artists_dict[art][alb] = []
                        rel_track = f"{art}/{alb}/{disc_name}/{c_name}"
                        tid = hashlib.md5(rel_track.encode("utf-8")).hexdigest()[:12]
                        artists_dict[art][alb].append({
                            "track_id": tid,
                            "gdrive_file_id": c_id,
                            "title": clean_track_title(c_name),
                            "artist": art,
                            "album": alb,
                            "track_num": parse_track_num(c_name),
                            "format": ext.replace(".", "").upper(),
                            "file_name": c_name,
                            "rel_path": rel_track,
                            "size_mb": 25.0,
                        })

    # Step 4: Assemble unified library catalog
    print("[Drive Sync] Assembling unified library catalog...")
    artists_list = []
    total_albums = 0
    total_tracks = 0
    missing_itunes_covers = []

    for artist_name in sorted(artists_dict.keys()):
        albums_list = []
        for album_name in sorted(artists_dict[artist_name].keys()):
            tracks = artists_dict[artist_name][album_name]
            tracks.sort(key=lambda t: (t["track_num"] if t["track_num"] > 0 else 999, t["title"]))

            key = f"{artist_name}_{album_name}".replace("/", "_").replace("\\", "_")
            cover_path = os.path.join(hifi_manager.COVERS_DIR, f"{key}.jpg")
            cover_rel = f"covers/{key}.jpg"
            cover_gdrive_id = gdrive_covers.get(key)

            if not os.path.isfile(cover_path) and not cover_gdrive_id:
                missing_itunes_covers.append((artist_name, album_name, cover_path))

            album_entry = {
                "name": album_name,
                "cover_rel": cover_rel,
                "track_count": len(tracks),
                "tracks": tracks
            }
            if cover_gdrive_id:
                album_entry["cover_gdrive_id"] = cover_gdrive_id

            albums_list.append(album_entry)
            total_albums += 1
            total_tracks += len(tracks)

        artists_list.append({
            "name": artist_name,
            "album_count": len(albums_list),
            "albums": albums_list
        })

    catalog = {
        "artists": artists_list,
        "total_artists": len(artists_list),
        "total_albums": total_albums,
        "total_tracks": total_tracks,
        "updated_at": time.time(),
        "sync_elapsed_seconds": round(time.time() - start_time, 2)
    }

    # Write atomically
    tmp_catalog = hifi_manager.CATALOG_FILE + ".tmp"
    with open(tmp_catalog, "w", encoding="utf-8") as f:
        json.dump(catalog, f, indent=2)
    os.replace(tmp_catalog, hifi_manager.CATALOG_FILE)

    elapsed = time.time() - start_time
    print(f"[Drive Sync] Finished in {elapsed:.2f}s! Indexed {len(artists_list)} artists, {total_albums} albums, {total_tracks} tracks.")
    print(f"[Drive Sync] Found {len(gdrive_covers)} native Google Drive covers.")

    # Instantly notify Round HUD and Web Remote without waiting for covers!
    notify_system_of_update()

    # Background cover art fetching (non-blocking)
    if gdrive_covers or missing_itunes_covers:
        async_fetch_covers(gdrive_covers, missing_itunes_covers)

    return catalog

if __name__ == "__main__":
    folder_arg = sys.argv[1] if len(sys.argv) > 1 else None
    sync(folder_arg)
