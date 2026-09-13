import { describe, expect, test } from "bun:test";
import type { OpenCodeEvent, SessionInfo } from "@opencode/client";
import { createBridge, currentState } from "./bridge";

type Context = Parameters<typeof createBridge>[0];
const env = {
  OPENCODE_NVIM_BRIDGE_URL: "http://127.0.0.1:12345/opencode/session",
  OPENCODE_NVIM_BRIDGE_TOKEN: "test-token",
  OPENCODE_NVIM_INSTANCE_ID: "test-instance",
};
function fixture() {
  let route: ReturnType<Context["ui"]["router"]["current"]> = { type: "home" };
  const sessions = new Map<string, SessionInfo>();
  const toasts: unknown[] = [];
  const context: Context = {
    ui: {
      router: { current: () => route, navigate: (next) => { route = next.type === "plugin" ? { ...next, id: "test-plugin" } : next; }, register: () => () => {} },
      toast: { show: (value) => { toasts.push(value); } },
    },
    data: { session: { get: (id) => sessions.get(id) }, location: { default: () => ({ directory: "/launch" }) } },
  };
  function select(id: string, directory = "/session", workspaceID?: string) {
    // Only fields consumed by the bridge are needed in this cache fixture.
    sessions.set(id, { id, location: { directory, workspaceID } } as SessionInfo);
    route = { type: "session", sessionID: id };
  }
  return { context, select, toasts };
}
function event(type: string, sessionID: string): OpenCodeEvent {
  return { type, data: { sessionID }, id: "evt_test" } as OpenCodeEvent;
}

describe("native TUI bridge", () => {
  test("uses route/cache location, including workspace, and clears it on home", () => {
    const f = fixture();
    f.select("ses_one", "/other/project", "wrk_one");
    expect(currentState(f.context)).toEqual({ route: "session", sessionID: "ses_one", cwd: "/other/project", workspaceID: "wrk_one" });
    f.context.ui.router.navigate({ type: "home" });
    expect(currentState(f.context)).toEqual({ route: "home", sessionID: null, cwd: "/launch", workspaceID: null });
    f.context.ui.router.navigate({ type: "session", sessionID: "ses_loading" });
    expect(currentState(f.context).sessionID).toBeNull();
  });

  test("inert outside Neovim; deduplicates only successful snapshots", async () => {
    const f = fixture();
    expect(createBridge(f.context, {})).toBeUndefined();
    const calls: unknown[] = [];
    const transport = (async (_url, init) => {
      calls.push(JSON.parse(init!.body as string));
      return new Response(null, { status: calls.length === 1 ? 500 : 200 });
    }) as typeof fetch;
    const bridge = createBridge(f.context, env, transport)!;
    await bridge.sync();
    await bridge.sync();
    await bridge.sync();
    expect(calls).toHaveLength(2);
    expect(f.toasts).toHaveLength(1);
    bridge.dispose();
    await bridge.sync();
    expect(calls).toHaveLength(2);
  });

  test("filters unrelated and unowned events, including nested forms", async () => {
    const f = fixture();
    f.select("ses_active");
    const calls: Record<string, any>[] = [];
    const transport = (async (_url, init) => {
      calls.push(JSON.parse(init!.body as string));
      return new Response(null, { status: 200 });
    }) as typeof fetch;
    const bridge = createBridge(f.context, env, transport)!;
    bridge.event(event("session.execution.succeeded", "ses_other"));
    bridge.event(event("permission.asked", "ses_active"));
    bridge.event({ type: "form.created", data: { form: { sessionID: "global" } } } as OpenCodeEvent);
    bridge.event({ type: "form.created", data: { form: { sessionID: "ses_active" } } } as OpenCodeEvent);
    await bridge.sync();
    expect(calls.filter((x) => x.kind === "event").map((x) => x.event.type)).toEqual(["permission.asked", "form.created"]);
    expect(calls.every((x) => x.sessionID === "ses_active")).toBe(true);
    bridge.dispose();
  });

  test("serializes route switches and resets deduplication on a new setup", async () => {
    const f = fixture();
    f.select("ses_one");
    let release!: () => void;
    const calls: Record<string, any>[] = [];
    const transport = (async (_url, init) => {
      calls.push(JSON.parse(init!.body as string));
      if (calls.length === 1) await new Promise<void>((resolve) => { release = resolve; });
      return new Response(null, { status: 200 });
    }) as typeof fetch;
    const bridge = createBridge(f.context, env, transport)!;
    const first = bridge.sync();
    await Promise.resolve();
    f.select("ses_two");
    bridge.event(event("session.execution.started", "ses_two"));
    release();
    await first;
    await bridge.sync();
    expect(calls.map((x) => x.sessionID)).toEqual(["ses_one", "ses_two", "ses_two"]);
    bridge.dispose();
    // A fresh setup must publish even if its initial state matches an old setup.
    const next = createBridge(f.context, env, transport)!;
    await next.sync();
    expect(calls).toHaveLength(4);
    next.dispose();
  });
  test("cleanup aborts an in-flight publish without reporting an error", async () => {
    const f = fixture();
    let signal: AbortSignal | undefined;
    const transport = (async (_url, init) => {
      signal = init!.signal!;
      await new Promise((_resolve, reject) => {
        signal!.addEventListener("abort", () => reject(new Error("aborted")));
      });
      return new Response();
    }) as typeof fetch;
    const bridge = createBridge(f.context, env, transport)!;
    const pending = bridge.sync();
    await Promise.resolve();
    bridge.dispose();
    await pending;
    expect(signal?.aborted).toBe(true);
    expect(f.toasts).toHaveLength(0);
  });

});
