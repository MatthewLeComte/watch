import type { Env } from "./env";

const INSTRUCTIONS =
  "Watch library. list, get, edit, rematch, and delete movies on watch.cornerstonecoatings.com. " +
  "rematch runs ingest once. It does not upload video and it does not deploy the worker.";

export async function handleWatchMcp(request: Request, env: Env): Promise<Response> {
  if (request.method === "GET") {
    return json({
      ok: true,
      transport: "json-rpc-http",
      name: "watch",
      title: "watch",
      version: "1.0.0",
      tools: TOOLS.map((tool) => ({ name: tool.name, title: tool.title, description: tool.description })),
    });
  }
  if (request.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  let msg: Record<string, unknown>;
  try {
    msg = (await request.json()) as Record<string, unknown>;
  } catch {
    return rpc(null, undefined, { code: -32700, message: "parse error" }, 400);
  }
  const id = msg.id ?? null;
  const method = String(msg.method || "");
  const params = (msg.params || {}) as Record<string, unknown>;

  if (method === "initialize") {
    return rpc(id, {
      protocolVersion: params.protocolVersion || "2025-06-18",
      capabilities: { tools: {} },
      serverInfo: { name: "watch", title: "watch", version: "1.0.0" },
      instructions: INSTRUCTIONS,
    });
  }
  if (method === "notifications/initialized" || method === "ping") return rpc(id, {});
  if (method === "tools/list") return rpc(id, { tools: TOOLS });
  if (method !== "tools/call") {
    return rpc(id, undefined, { code: -32601, message: `Method not found: ${method}` });
  }

  const name = String(params.name || "");
  const args = (params.arguments || {}) as Record<string, unknown>;
  try {
    return rpc(id, await callTool(name, args, env));
  } catch (err) {
    return rpc(id, text({ ok: false, error: err instanceof Error ? err.message : "failed" }, true));
  }
}

const TOOLS = [
  {
    name: "list",
    title: "List movies",
    description: "Movies in the watch library, newest first. Includes match notes and subtitle tracks. No video bytes.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get",
    title: "Get one movie",
    description: "One movie by id.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "Movie id." } },
      required: ["id"],
      additionalProperties: false,
    },
  },
  {
    name: "edit",
    title: "Edit movie details",
    description: "Set title, year, and overview. Marks the row manual. Does not run ingest.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        title: { type: "string" },
        year: { type: ["integer", "null"] },
        overview: { type: "string" },
      },
      required: ["id"],
      additionalProperties: false,
    },
  },
  {
    name: "rematch",
    title: "Match again",
    description: "Run ingest once for this movie. One Jev call at most, and only if the filename is ambiguous.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" } },
      required: ["id"],
      additionalProperties: false,
    },
  },
  {
    name: "delete",
    title: "Delete movie",
    description: "Remove the movie, its poster, and its subtitles from the library.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" } },
      required: ["id"],
      additionalProperties: false,
    },
  },
];

async function callTool(name: string, args: Record<string, unknown>, env: Env): Promise<Record<string, unknown>> {
  const id = String(args.id || "").trim();
  if (name !== "list" && !/^[0-9a-f-]{36}$/i.test(id)) {
    return text({ ok: false, error: "id_required" }, true);
  }
  const api = await import("./worker");
  if (name === "list") return fromResponse(await api.listItems(env));
  if (name === "get") return fromResponse(await api.oneItem(env, id));
  if (name === "delete") return fromResponse(await api.deleteItem(env, id));
  if (name === "rematch") return fromResponse(await api.rematch(env, id));
  if (name === "edit") {
    const body: Record<string, unknown> = {};
    if (typeof args.title === "string") body.title = args.title;
    if (typeof args.overview === "string") body.overview = args.overview;
    if (args.year === null || typeof args.year === "number") body.year = args.year;
    const request = new Request(`https://watch.cornerstonecoatings.com/v1/items/${id}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    return fromResponse(await api.patchItem(request, env, id));
  }
  return text({ ok: false, error: "unknown_tool", name }, true);
}

async function fromResponse(response: Response): Promise<Record<string, unknown>> {
  const raw = await response.text();
  let data: unknown = raw;
  try {
    data = raw ? JSON.parse(raw) : null;
  } catch {
    /* keep text */
  }
  return text(data, response.status >= 400);
}

function text(value: unknown, isError = false): Record<string, unknown> {
  const result: Record<string, unknown> = {
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) }],
  };
  if (isError) result.isError = true;
  return result;
}

function rpc(id: unknown, result?: unknown, error?: { code: number; message: string }, status = 200): Response {
  const body = error ? { jsonrpc: "2.0", id, error } : { jsonrpc: "2.0", id, result };
  return json(body, status);
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
