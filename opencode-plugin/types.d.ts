/**
 * Minimal local type shims for the bundled TUI plugin.
 *
 * This repository does not keep a full TypeScript toolchain or the OpenCode
 * TUI plugin package's transitive type dependencies installed alongside
 * `opencode-plugin/tui.ts`, so editor tooling cannot resolve the real package
 * types from here by default.
 *
 * Keep this file intentionally small and limited to the subset of the TUI API
 * that `tui.ts` actually uses.
 */

declare const process: {
  env: Record<string, string | undefined>;
  cwd(): string;
};

declare module "@opencode-ai/plugin/tui" {
  export type TuiToast = {
    title?: string;
    message: string;
    variant?: "info" | "success" | "warning" | "error";
    duration?: number;
  };

  export type TuiRouteCurrent =
    | { name: "home" }
    | {
        name: "session";
        params: {
          sessionID: string;
          initialPrompt?: unknown;
        };
      };

  type SessionEvent = {
    type: "session.status" | "session.idle" | "session.error";
    properties?: {
      sessionID?: unknown;
    };
  };

  type PermissionEvent = {
    type: "permission.asked" | "permission.replied";
    properties?: {
      sessionID?: unknown;
    };
  };

  type QuestionEvent = {
    type: "question.asked" | "question.replied";
    properties?: {
      sessionID?: unknown;
    };
  };

  type MessageEvent = {
    type: "message.updated";
    properties?: {
      sessionID?: unknown;
      info?: {
        role?: unknown;
      };
    };
  };

  export type TuiEvent =
    | SessionEvent
    | PermissionEvent
    | QuestionEvent
    | MessageEvent;

  export type TuiPluginApi = {
    route: {
      readonly current: TuiRouteCurrent;
    };
    ui: {
      toast(input: TuiToast): void;
    };
    event: {
      on<Type extends TuiEvent["type"]>(
        type: Type,
        handler: (event: Extract<TuiEvent, { type: Type }>) => void,
      ): () => void;
    };
    lifecycle: {
      onDispose(fn: () => void): () => void;
    };
  };

  export type TuiPlugin = (
    api: TuiPluginApi,
    options: unknown,
    meta: unknown,
  ) => Promise<void>;

  export type TuiPluginModule = {
    id?: string;
    tui: TuiPlugin;
    server?: never;
  };
}
