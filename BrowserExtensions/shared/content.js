const ext = globalThis.browser ?? globalThis.chrome;

ext.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "superdd.collectLinks") return false;
  const urls = [...new Set([...document.links].map((link) => link.href).filter(Boolean))];
  sendResponse({ urls });
  return true;
});
