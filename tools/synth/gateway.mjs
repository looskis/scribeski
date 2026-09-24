// Minimal Vercel AI Gateway client (OpenAI-compatible chat completions). No dependencies.
// Synthetic text only ever goes through here (DESIGN §4, BUILD_PLAN P1.9).

import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { Agent, fetch } from "undici";

const ENDPOINT = "https://ai-gateway.vercel.sh/v1/chat/completions";

export function loadKey(repoRoot, name = "AI_GATEWAY_API_KEY") {
  if (process.env[name]) return process.env[name];
  const p = resolve(repoRoot, ".env");
  if (existsSync(p)) {
    for (const line of readFileSync(p, "utf8").split("\n")) {
      const m = line.match(new RegExp(`^\\s*${name}\\s*=\\s*"?([^"\\s]+)"?`));
      if (m) return m[1];
    }
  }
  if (name === "NONE") return "none";
  throw new Error(`${name} not set (env or .env at repo root)`);
}

// provider "gateway" = Vercel AI Gateway; "vllm" = any OpenAI-compatible server (open models on a GPU).
export function makeClient(key, { log = () => {}, endpoint = ENDPOINT, provider = "gateway" } = {}) {
  const usage = { calls: 0, prompt: 0, completion: 0, cached: 0, cost: 0 };
  // HTTP/1.1 pool we can throw away: after one TLS error, Node's default HTTP/2 session kept
  // failing every later request with ERR_HTTP2_INVALID_SESSION. No header/body timeouts
  // (responses are streamed; the AbortController below is the only deadline).
  const newAgent = () => new Agent({ allowH2: false, connections: 32, keepAliveTimeout: 20_000, headersTimeout: 0, bodyTimeout: 0 });
  let agent = newAgent();

  async function chat({ model, messages, temperature = 0.9, max_tokens = 16000, json = false, reasoning = false }) {
    // Reasoning models spend max_tokens on hidden thinking; off unless asked for.
    // Streamed: Node's fetch drops a request whose headers take > 5 min (undici headersTimeout),
    // which long generations and the reasoning teacher pass exceed.
    const body = { model, messages, temperature, max_tokens, stream: true, stream_options: { include_usage: true } };
    if (provider === "gateway") body.reasoning = { enabled: reasoning };
    else {
      body.chat_template_kwargs = { enable_thinking: reasoning }; // Qwen-style templates
      body.reasoning_effort = reasoning ? "high" : "low";          // gpt-oss
    }
    if (json) body.response_format = { type: "json_object" };
    for (let attempt = 1; ; attempt++) {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 20 * 60_000);
      try {
        const res = await fetch(endpoint, {
          method: "POST",
          headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
          body: JSON.stringify(body),
          signal: ctrl.signal,
          dispatcher: agent,
        });
        if (res.status === 429 || res.status >= 500) throw Object.assign(new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`), { retry: true });
        if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 500)}`);
        let content = "";
        let finish;
        let u = {};
        let cost = 0;
        let buf = "";
        const decoder = new TextDecoder();
        for await (const chunk of res.body) {
          buf += decoder.decode(chunk, { stream: true });
          let nl;
          while ((nl = buf.indexOf("\n")) >= 0) {
            const line = buf.slice(0, nl).trim();
            buf = buf.slice(nl + 1);
            if (!line.startsWith("data:")) continue;
            const payload = line.slice(5).trim();
            if (payload === "[DONE]") continue;
            const ev = JSON.parse(payload);
            if (ev.error) throw Object.assign(new Error(`stream error: ${JSON.stringify(ev.error).slice(0, 300)}`), { retry: true });
            const c = ev.choices?.[0];
            if (c?.delta?.content) content += c.delta.content;
            if (c?.finish_reason) finish = c.finish_reason;
            if (ev.usage) u = ev.usage;
            cost = Number(ev.providerMetadata?.gateway?.cost ?? ev.usage?.cost ?? cost) || cost;
          }
        }
        usage.calls++;
        usage.prompt += u.prompt_tokens ?? 0;
        usage.completion += u.completion_tokens ?? 0;
        usage.cached += u.prompt_tokens_details?.cached_tokens ?? 0;
        usage.cost += cost;
        if (!content.trim()) throw Object.assign(new Error(`empty completion (finish=${finish})`), { retry: true });
        return { content, finish };
      } catch (e) {
        const retry = e.retry || e.name === "AbortError" || e.cause?.code === "ECONNRESET" || e.message?.includes("fetch failed") || e.message?.includes("terminated");
        if (retry && !e.retry) {
          // connection-level failure: start over with fresh sockets
          const old = agent;
          agent = newAgent();
          old.close().catch(() => {});
        }
        if (!retry || attempt >= 6) throw e;
        log(`  retry ${attempt}: ${e.message}${e.cause?.code ? ` (${e.cause.code})` : ""}`);
        await new Promise((r) => setTimeout(r, Math.min(120_000, 2000 * 2 ** attempt)));
      } finally {
        clearTimeout(timer);
      }
    }
  }

  return { chat, usage };
}

export function parseJSON(text) {
  const s = text.replace(/^```(?:json)?\s*/m, "").replace(/```\s*$/m, "").trim();
  const start = s.indexOf("{");
  const end = s.lastIndexOf("}");
  return JSON.parse(s.slice(start, end + 1));
}
