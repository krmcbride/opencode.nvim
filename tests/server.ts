// A local native-v2 contract fixture; no model or user data is involved.
const streams = new Set<ReadableStreamDefaultController<Uint8Array>>();
const requests: { path: string; body: unknown }[] = [];
const encode = new TextEncoder();
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 0,
  async fetch(req) {
    const path = new URL(req.url).pathname;
    const body = req.method === "POST" ? await req.json() : undefined;
    if (path === "/requests") return Response.json({ data: requests });
    if (path === "/emit") {
      for (const stream of streams) stream.enqueue(encode.encode(body.raw ?? `data: ${JSON.stringify(body)}\n\n`));
      return Response.json({ ok: true });
    }
    if (path === "/disconnect") {
      for (const stream of streams) stream.close();
      streams.clear();
      return Response.json({ ok: true });
    }
    if (req.headers.get("authorization") !== `Basic ${btoa("opencode:fixture-password")}`) return new Response(null, { status: 401 });
    requests.push({ path, body });
    if (path === "/api/health") return Response.json({ healthy: true, version: "2.0.1", pid: 1 });
    if (path === "/api/event") {
      return new Response(new ReadableStream({
        start(controller) {
          streams.add(controller);
          controller.enqueue(encode.encode('data: {"type":"server.connected","data":{}}\n\n'));
        },
        cancel() { /* disposed with the fixture process */ },
      }), { headers: { "Content-Type": "text/event-stream" } });
    }
    const match = path.match(/^\/api\/session\/(ses_\w+)(\/prompt)?$/);
    if (!match) return new Response(null, { status: 404 });
    const sessionID = match[1];
    if (!match[2]) return Response.json({ data: { id: sessionID, agent: "reviewer", model: { providerID: "example", id: "current-model", variant: "medium" }, location: { directory: "/fixture" } } });
    if (sessionID === "ses_rejected") return new Response(null, { status: 409 });
    if (sessionID === "ses_malformed") return Response.json({ data: { id: "msg_wrong", sessionID: "ses_other", type: "user", delivery: "queue" } });
    if (sessionID === "ses_delayed") await Bun.sleep(100);
    return Response.json({ data: { id: "msg_admitted", sessionID, type: "user", payload: body, delivery: body.delivery, timeCreated: Date.now() } });
  },
});
console.log(server.url.href);
