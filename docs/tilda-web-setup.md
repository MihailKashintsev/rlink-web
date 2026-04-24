# Rlink Web for Tilda

## Build
- Run with base href for hosted subpath:
  - `RLINK_WEB_BASE_HREF=/rlink_web/ bash scripts/build_tilda_web_bundle.sh`
- Bundle output: `dist/tilda-web`

## Publish
- Upload all files from `dist/tilda-web` to your static hosting.
- Confirm the app opens by URL: `https://your-domain/rlink_web/index.html`

## Ready-to-paste Tilda HTML blocks

### Block 1 (Config)
Paste contents of `docs/tilda/rlink-tilda-block-config.html` into a Tilda HTML block.
Set:
- `window.RLINK_WEB_APP_URL` to your hosted folder URL (example: `https://rendergames.online/rlink_web`).
- optional `window.RLINK_WEB_HEIGHT`.

### Block 2 (App)
Paste contents of `docs/tilda/rlink-tilda-block-app.html` into the next Tilda HTML block.

This mode uses an iframe and is the most stable for Tilda pages.

### Optional: direct script embed (advanced)
You can also use `docs/tilda/rlink-tilda-embed.html` for direct bootstrap script mode.

## Notes
- Web mode uses internet relay transport only.
- Browser keeps a local persistent account marker and cache.
- BLE/Wi-Fi Direct flows are disabled in web embedding mode.
- If Google Sign-In is needed in web mode, ensure OAuth web origin includes your hosted domain.
- In Tilda config always use `https://` URL. `http://` can be blocked as mixed content.
