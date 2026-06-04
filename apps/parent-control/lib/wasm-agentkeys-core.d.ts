declare module '@/lib/wasm/agentkeys-web-core/agentkeys_web_core' {
  export class WebCore {
    constructor(brokerUrl: string);
    capMemoryPut(bearer: string, req: unknown): Promise<unknown>;
    capMemoryGet(bearer: string, req: unknown): Promise<unknown>;
    pairingClaim(bearer: string, req: unknown): Promise<unknown>;
    pendingBindings(bearer: string): Promise<unknown>;
    ackBinding(bearer: string, requestId: string): Promise<unknown>;
  }
}

declare module '@/lib/wasm/agentkeys-web-core/agentkeys_web_core.js' {
  import { WebCore } from '@/lib/wasm/agentkeys-web-core/agentkeys_web_core';

  export { WebCore };
  export default function init(wasmUrl: string): Promise<void>;
}
