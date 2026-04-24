# Rlink Web on GitHub Pages + Tilda

## 1) Push changes to `main`
After push, workflow `Deploy Web to GitHub Pages` will build and publish web app.

## 2) Enable GitHub Pages in repo settings
- Open: `Settings` -> `Pages`
- In **Build and deployment**, choose **Source: GitHub Actions**

## 3) Wait for first successful deploy
In `Actions` tab, wait until `Deploy Web to GitHub Pages` is green.

Your URL becomes:
- `https://<github-username>.github.io/<repo-name>/`

## 4) Paste ready HTML blocks into Tilda

### Block 1 (Config)
```html
<script>
  window.RLINK_WEB_APP_URL = "https://<github-username>.github.io/<repo-name>";
  window.RLINK_WEB_HEIGHT = 820;
</script>
```

### Block 2 (App)
```html
<div id="rlink-tilda-app-wrap" style="width:100%;max-width:1280px;margin:0 auto;"></div>
<script>
  (function () {
    var appUrl = (window.RLINK_WEB_APP_URL || "").replace(/\/$/, "");
    var height = Number(window.RLINK_WEB_HEIGHT || 820);
    var wrap = document.getElementById("rlink-tilda-app-wrap");

    if (!appUrl) {
      wrap.innerHTML =
        '<div style="padding:16px;border:1px solid #ddd;border-radius:10px;background:#fff;font-family:Arial,sans-serif;">' +
        "Rlink embed is not configured. Add config block first and set window.RLINK_WEB_APP_URL." +
        "</div>";
      return;
    }

    var iframe = document.createElement("iframe");
    iframe.src = appUrl + "/";
    iframe.style.width = "100%";
    iframe.style.height = height + "px";
    iframe.style.border = "0";
    iframe.style.borderRadius = "14px";
    iframe.style.background = "#0B0F1A";
    iframe.loading = "lazy";
    iframe.allow = "camera; microphone; geolocation; clipboard-read; clipboard-write";
    wrap.appendChild(iframe);
  })();
</script>
```

## 5) Publish Tilda page
Republish page and hard-reload browser cache (`Ctrl/Cmd + Shift + R`).
