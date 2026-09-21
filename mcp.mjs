#!/usr/bin/env node
/**
 * Streamable HTTP MCP. Apple python3 stdio re-execs Python.app and the client
 * cancels initialize. Local chats use HTTP (--http). Stdio remains for tests.
 */
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PYTHON =
  process.env.CUA_PYTHON ||
  "/Library/Developer/CommandLineTools/usr/bin/python3";
const SERVER = path.join(ROOT, "server.py");
const HTTP_PORT = Number(process.env.CUA_MCP_PORT || 8765);

function dbg(line) {
  try {
    fs.appendFileSync("/tmp/cua-mcp-debug.log", `node pid=${process.pid} ${line}\n`);
  } catch {
    /* ignore */
  }
}

function writeStdio(payload) {
  const raw = Buffer.from(JSON.stringify(payload));
  const frame = Buffer.concat([
    Buffer.from(`Content-Length: ${raw.length}\r\n\r\n`, "ascii"),
    raw,
  ]);
  fs.writeSync(1, frame);
}

let toolsCache = null;
let worker = null;
let workerBuf = "";
let nextRpcId = 1;
const pending = new Map();

function ensureWorker() {
  if (worker) return;
  worker = spawn(PYTHON, ["-u", SERVER, "--rpc"], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, PYTHONUNBUFFERED: "1" },
  });
  worker.stderr.on("data", (chunk) => {
    dbg(`py-err ${String(chunk).slice(0, 400)}`);
  });
  worker.stdout.on("data", (chunk) => {
    workerBuf += String(chunk);
    let nl;
    while ((nl = workerBuf.indexOf("\n")) !== -1) {
      const line = workerBuf.slice(0, nl).trim();
      workerBuf = workerBuf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (err) {
        dbg(`bad-rpc-json ${err}`);
        continue;
      }
      const waiter = pending.get(msg.id);
      if (waiter) {
        pending.delete(msg.id);
        waiter.resolve(msg.result);
      }
    }
  });
  worker.on("exit", (code) => {
    dbg(`rpc-exit ${code}`);
    worker = null;
    for (const waiter of pending.values()) {
      waiter.reject(new Error("python rpc worker exited"));
    }
    pending.clear();
  });
}

function callTool(name, args) {
  ensureWorker();
  const id = nextRpcId++;
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`tool ${name} timed out`));
    }, 90000);
    pending.set(id, {
      resolve: (v) => {
        clearTimeout(t);
        resolve(v);
      },
      reject: (e) => {
        clearTimeout(t);
        reject(e);
      },
    });
    worker.stdin.write(JSON.stringify({ id, name, arguments: args || {} }) + "\n");
  });
}

function loadTools() {
  if (toolsCache) return toolsCache;
  const fromFile = path.join(ROOT, "tools.json");
  if (fs.existsSync(fromFile)) {
    toolsCache = JSON.parse(fs.readFileSync(fromFile, "utf8"));
    return toolsCache;
  }
  const out = spawnSync(PYTHON, ["-u", SERVER, "--tools"], {
    encoding: "utf8",
    timeout: 8000,
    env: { ...process.env, PYTHONUNBUFFERED: "1" },
  });
  if (out.status !== 0) {
    throw new Error(`--tools failed: ${out.stderr || out.status}`);
  }
  toolsCache = JSON.parse(String(out.stdout || "").trim());
  return toolsCache;
}

async function dispatch(msg) {
  const method = msg.method;
  const id = msg.id;
  if (method === "initialize") {
    const requested =
      (msg.params && msg.params.protocolVersion) || "2025-11-25";
    return {
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: requested,
        capabilities: { tools: {} },
        serverInfo: { name: "computer-use", version: "1.1.0" },
      },
    };
  }
  if (method === "notifications/initialized" || method === "notifications/cancelled") {
    return null;
  }
  if (method === "ping") {
    return { jsonrpc: "2.0", id, result: {} };
  }
  if (method === "tools/list") {
    return { jsonrpc: "2.0", id, result: loadTools() };
  }
  if (method === "tools/call") {
    const params = msg.params || {};
    try {
      const result = await callTool(String(params.name || ""), params.arguments || {});
      return { jsonrpc: "2.0", id, result };
    } catch (err) {
      return {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: String(err) }],
          isError: true,
        },
      };
    }
  }
  if (id === undefined || id === null) return null;
  return {
    jsonrpc: "2.0",
    id,
    error: { code: -32601, message: `Unknown method ${method}` },
  };
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
    "Access-Control-Allow-Headers":
      "content-type, accept, mcp-session-id, mcp-protocol-version",
    "Access-Control-Expose-Headers": "Mcp-Session-Id, mcp-session-id",
  };
}

function sessionHeaders(sid, proto = "2025-11-25") {
  return {
    ...corsHeaders(),
    "Mcp-Session-Id": sid,
    "MCP-Protocol-Version": proto,
  };
}

function startHttp() {
  try {
    process.stdin.pause();
  } catch {
    /* ignore */
  }
  const sessions = new Set();
  const server = http.createServer(async (req, res) => {
    req.on("error", (err) => dbg(`req-error ${err}`));
    res.on("error", (err) => dbg(`res-error ${err}`));
    const url = new URL(req.url || "/", "http://127.0.0.1");
    if (url.pathname !== "/mcp" && url.pathname !== "/") {
      res.writeHead(404, corsHeaders());
      res.end();
      return;
    }
    if (req.method === "OPTIONS") {
      res.writeHead(204, corsHeaders());
      res.end();
      return;
    }
    if (req.method === "GET") {
      const sid = String(req.headers["mcp-session-id"] || "");
      dbg(`http GET sid=${sid}`);
      res.writeHead(200, {
        ...corsHeaders(),
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache, no-transform",
        Connection: "keep-alive",
        "Mcp-Session-Id": sid || randomUUID(),
      });
      res.write(": connected\n\n");
      const ping = setInterval(() => {
        try {
          res.write(": keepalive\n\n");
        } catch {
          clearInterval(ping);
        }
      }, 15000);
      const stop = () => clearInterval(ping);
      req.on("close", stop);
      res.on("close", stop);
      return;
    }
    if (req.method === "DELETE") {
      const sid = req.headers["mcp-session-id"];
      if (sid) sessions.delete(String(sid));
      dbg(`http DELETE sid=${sid || ""}`);
      res.writeHead(200, corsHeaders());
      res.end();
      return;
    }
    if (req.method !== "POST") {
      res.writeHead(405, corsHeaders());
      res.end();
      return;
    }
    const chunks = [];
    try {
      for await (const chunk of req) chunks.push(chunk);
    } catch (err) {
      dbg(`http-read ${err}`);
      res.writeHead(400, corsHeaders());
      res.end();
      return;
    }
    let msg;
    try {
      msg = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
    } catch (err) {
      res.writeHead(400, {
        ...corsHeaders(),
        "Content-Type": "application/json",
      });
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: null,
          error: { code: -32700, message: String(err) },
        })
      );
      return;
    }
    const incomingSid = req.headers["mcp-session-id"]
      ? String(req.headers["mcp-session-id"])
      : "";
    const messages = Array.isArray(msg) ? msg : [msg];
    const isInit = messages.some((m) => m && m.method === "initialize");
    let sid = incomingSid;
    if (isInit && !sid) {
      sid = randomUUID();
    }
    if (!sid) {
      res.writeHead(400, {
        ...corsHeaders(),
        "Content-Type": "application/json",
      });
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: messages[0] && messages[0].id,
          error: { code: -32600, message: "Missing Mcp-Session-Id" },
        })
      );
      return;
    }
    sessions.add(sid);
    const proto =
      (messages[0] &&
        messages[0].params &&
        messages[0].params.protocolVersion) ||
      String(req.headers["mcp-protocol-version"] || "2025-11-25");
    dbg(
      `http POST ${messages.map((m) => m.method).join(",")} id=${messages.map((m) => m.id).join(",")} sid=${sid}`
    );
    try {
      const replies = [];
      for (const one of messages) {
        const reply = await dispatch(one);
        if (reply !== null) replies.push(reply);
      }
      if (replies.length === 0) {
        res.writeHead(202, sessionHeaders(sid, proto));
        res.end();
        return;
      }
      const body = Array.isArray(msg) ? replies : replies[0];
      res.writeHead(200, {
        ...sessionHeaders(sid, proto),
        "Content-Type": "application/json",
      });
      res.end(JSON.stringify(body));
    } catch (err) {
      dbg(`http-dispatch ${err}`);
      res.writeHead(200, {
        ...sessionHeaders(sid, proto),
        "Content-Type": "application/json",
      });
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: messages[0] && messages[0].id,
          error: { code: -32000, message: String(err) },
        })
      );
    }
  });
  // Clients reuse the TCP connection. Node's default keepAliveTimeout is 5s,
  // which matches the "connected" then "MCP HTTP exchange failed" gap.
  server.keepAliveTimeout = 900000;
  server.headersTimeout = 910000;
  server.requestTimeout = 0;
  server.timeout = 0;
  server.listen(HTTP_PORT, "127.0.0.1", () => {
    dbg(`http listening 127.0.0.1:${HTTP_PORT}/mcp keepAlive=${server.keepAliveTimeout}`);
  });
  server.on("error", (err) => {
    dbg(`http-error ${err}`);
    if (err && err.code === "EADDRINUSE") process.exit(1);
  });
  server.on("clientError", (err, socket) => {
    dbg(`http-clientError ${err}`);
    try {
      socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
    } catch {
      /* ignore */
    }
  });
}

function startStdio() {
  let buf = Buffer.alloc(0);
  function tryReadOne() {
    if (!buf.length) return null;
    const crlf = buf.indexOf("\r\n\r\n");
    const lf = buf.indexOf("\n\n");
    let sep = -1;
    let sepLen = 0;
    if (crlf !== -1 && (lf === -1 || crlf <= lf)) {
      sep = crlf;
      sepLen = 4;
    } else if (lf !== -1) {
      sep = lf;
      sepLen = 2;
    }
    if (sep !== -1) {
      const header = buf.slice(0, sep).toString("utf8");
      const match = header.match(/content-length:\s*(\d+)/i);
      if (match) {
        const length = Number(match[1]);
        const start = sep + sepLen;
        if (buf.length < start + length) return null;
        const body = buf.slice(start, start + length).toString("utf8");
        buf = buf.slice(start + length);
        return JSON.parse(body);
      }
    }
    if (buf[0] === 0x7b) {
      const nl = buf.indexOf(0x0a);
      if (nl === -1) return null;
      const line = buf.slice(0, nl).toString("utf8").replace(/\r$/, "");
      buf = buf.slice(nl + 1);
      return JSON.parse(line);
    }
    return null;
  }
  process.stdin.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      let msg;
      try {
        msg = tryReadOne();
      } catch (err) {
        dbg(`parse ${err}`);
        break;
      }
      if (!msg) break;
      dbg(`stdio ${msg.method} id=${msg.id}`);
      dispatch(msg)
        .then((reply) => {
          if (reply !== null) writeStdio(reply);
        })
        .catch((err) => {
          if (msg.id !== undefined && msg.id !== null) {
            writeStdio({
              jsonrpc: "2.0",
              id: msg.id,
              error: { code: -32000, message: String(err) },
            });
          }
        });
    }
  });
  process.stdin.on("end", () => {
    dbg("eof");
    if (worker) worker.kill();
    process.exit(0);
  });
  process.stdin.resume();
}

process.on("uncaughtException", (err) => {
  dbg(`uncaught ${err && err.stack ? err.stack : err}`);
});
process.on("unhandledRejection", (err) => {
  dbg(`unhandledRejection ${err}`);
});

dbg(process.argv.includes("--http") ? "start-http" : "start-stdio");
if (process.argv.includes("--http")) {
  startHttp();
} else {
  startStdio();
}
