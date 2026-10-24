// Minimal service worker: lets the remote install as a PWA. Network-first; no offline caching of API.
self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => self.clients.claim());
self.addEventListener('fetch', e => { /* passthrough */ });
