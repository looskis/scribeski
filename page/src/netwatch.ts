// Counts network requests the page makes while we write and settle, so the host can tell the
// worker "this EHR autosaved while filling". Wraps fetch, XMLHttpRequest and sendBeacon in
// each same-origin window, and unwraps on stop. A page that cached `fetch` before we wrapped
// it is invisible to this; the count is a floor, not a guarantee.

export interface NetworkSummary {
  requests: number;
  /** Distinct origin + path of each request. Never the query string or body. */
  urls: string[];
}

export class NetWatch {
  private requests = 0;
  private urls: string[] = [];
  private active = true;
  private restores: (() => void)[] = [];

  constructor(windows: Window[]) {
    for (const w of windows) this.wrap(w as Window & typeof globalThis);
  }

  stop(): NetworkSummary {
    this.active = false;
    for (const restore of this.restores.reverse()) restore();
    this.restores = [];
    return { requests: this.requests, urls: this.urls };
  }

  private record(w: Window, url: unknown): void {
    if (!this.active) return;
    this.requests++;
    try {
      const u = new URL(String(url), w.location.href);
      const s = u.origin + u.pathname;
      if (!this.urls.includes(s)) this.urls.push(s);
    } catch {
      /* unparseable URL: counted, not listed */
    }
  }

  private wrap(w: Window & typeof globalThis): void {
    const self = this;

    const fetch = w.fetch;
    if (typeof fetch === "function") {
      const wrapped = function (this: unknown, ...args: Parameters<typeof fetch>) {
        const input = args[0];
        self.record(w, typeof input === "object" && input && "url" in input ? input.url : input);
        return fetch.apply(w, args);
      };
      w.fetch = wrapped as typeof fetch;
      this.restores.push(() => {
        if (w.fetch === wrapped) w.fetch = fetch;
      });
    }

    const xhr = w.XMLHttpRequest?.prototype;
    if (xhr) {
      const { open, send } = xhr;
      const targets = new WeakMap<XMLHttpRequest, unknown>();
      const wrappedOpen = function (this: XMLHttpRequest, ...args: unknown[]) {
        targets.set(this, args[1]);
        return (open as (...a: unknown[]) => void).apply(this, args);
      };
      const wrappedSend = function (this: XMLHttpRequest, body?: Document | XMLHttpRequestBodyInit | null) {
        self.record(w, targets.get(this) ?? "");
        return send.call(this, body);
      };
      xhr.open = wrappedOpen as typeof open;
      xhr.send = wrappedSend;
      this.restores.push(() => {
        if (xhr.open === wrappedOpen) xhr.open = open;
        if (xhr.send === wrappedSend) xhr.send = send;
      });
    }

    const nav = w.navigator;
    const beacon = nav?.sendBeacon;
    if (typeof beacon === "function") {
      const own = Object.prototype.hasOwnProperty.call(nav, "sendBeacon");
      const wrapped = function (url: string | URL, data?: BodyInit | null) {
        self.record(w, url);
        return beacon.call(nav, url, data);
      };
      nav.sendBeacon = wrapped;
      this.restores.push(() => {
        if (nav.sendBeacon !== wrapped) return;
        if (own) nav.sendBeacon = beacon;
        else delete (nav as { sendBeacon?: unknown }).sendBeacon;
      });
    }
  }
}

/** The top window and every same-origin frame window below it. */
export function sameOriginWindows(w: Window = window): Window[] {
  const out = [w];
  for (let i = 0; i < w.frames.length; i++) {
    try {
      const child = w.frames[i]!;
      void child.document; // throws when cross-origin
      out.push(...sameOriginWindows(child));
    } catch {
      /* cross-origin */
    }
  }
  return out;
}
