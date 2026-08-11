const ext = globalThis.browser ?? globalThis.chrome;
const promiseAPI = typeof globalThis.browser !== "undefined";

function invoke(target, method, ...args) {
  if (promiseAPI) return target[method](...args);
  return new Promise((resolve, reject) => {
    target[method](...args, (value) => {
      const error = globalThis.chrome?.runtime?.lastError;
      if (error) reject(new Error(error.message));
      else resolve(value);
    });
  });
}

async function configuration() {
  const stored = await invoke(ext.storage.local, "get", ["port", "secret", "takeOverDownloads"]);
  return {
    port: Number(stored.port || 29110),
    secret: String(stored.secret || ""),
    takeOverDownloads: stored.takeOverDownloads === true,
  };
}

async function cookiesFor(url) {
  try {
    const values = await invoke(ext.cookies, "getAll", { url });
    return values.map((cookie) => `${cookie.name}=${cookie.value}`).join("; ");
  } catch {
    return "";
  }
}

async function submit(url, context = {}) {
  if (!/^https?:|^ftp:|^magnet:|^ed2k:|^thunder:/i.test(url || "")) return;
  const config = await configuration();
  const response = await fetch(`http://127.0.0.1:${config.port}/add`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.secret}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      url,
      finalUrl: url,
      referer: context.referer || "",
      cookie: await cookiesFor(url),
      userAgent: navigator.userAgent,
      requestHeaders: [],
      filename: context.filename || "",
    }),
  });
  if (!response.ok) throw new Error(`Kite returned HTTP ${response.status}`);
  return response.json();
}

async function createMenus() {
  await invoke(ext.contextMenus, "removeAll");
  const entries = [
    ["kite-link", "Download Link with Kite", ["link"]],
    ["kite-page", "Download Page with Kite", ["page", "video", "audio"]],
    ["kite-selection", "Download URLs in Selection", ["selection"]],
    ["kite-all", "Download All Links with Kite", ["page"]],
  ];
  for (const [id, title, contexts] of entries) {
    ext.contextMenus.create({ id, title, contexts });
  }
}

ext.runtime.onInstalled.addListener(() => {
  createMenus().catch(console.error);
  invoke(ext.storage.local, "get", ["port"]).then((stored) => {
    if (!stored.port) invoke(ext.storage.local, "set", { port: 29110, secret: "", takeOverDownloads: false });
  });
});

ext.action.onClicked.addListener((tab) => {
  submit(tab.url, { referer: tab.url }).catch(console.error);
});

ext.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === "kite-link") await submit(info.linkUrl, { referer: tab?.url });
    if (info.menuItemId === "kite-page") await submit(info.srcUrl || info.pageUrl, { referer: info.pageUrl });
    if (info.menuItemId === "kite-selection") {
      const matches = String(info.selectionText || "").match(/(?:https?|ftp):\/\/[^\s<>"']+/g) || [];
      for (const url of [...new Set(matches)]) await submit(url, { referer: tab?.url });
    }
    if (info.menuItemId === "kite-all" && tab?.id != null) {
      const result = await invoke(ext.tabs, "sendMessage", tab.id, { type: "kite.collectLinks" });
      for (const url of result?.urls || []) await submit(url, { referer: tab.url });
    }
  } catch (error) {
    console.error(error);
  }
});

if (ext.downloads?.onCreated) {
  ext.downloads.onCreated.addListener(async (download) => {
    try {
      const config = await configuration();
      if (!config.takeOverDownloads || !/^https?:|^ftp:/i.test(download.finalUrl || download.url || "")) return;
      await invoke(ext.downloads, "cancel", download.id);
      await invoke(ext.downloads, "erase", { id: download.id });
      await submit(download.finalUrl || download.url, { filename: download.filename });
    } catch (error) {
      console.error(error);
    }
  });
}
