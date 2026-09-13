import { Plugin } from "@opencode/plugin/tui";
import { createBridge } from "./bridge";

export default Plugin.define({
  id: "opencode-nvim-bridge",
  setup(context) {
    const bridge = createBridge(context, process.env);
    if (!bridge) return;

    void bridge.sync();
    const unsubscribe = context.data.listen(({ details }) => bridge.event(details));
    // Polling also catches cache/location changes without owning a Solid root.
    const timer = setInterval(() => void bridge.sync(), 300);
    return () => {
      clearInterval(timer);
      unsubscribe();
      bridge.dispose();
    };
  },
});
