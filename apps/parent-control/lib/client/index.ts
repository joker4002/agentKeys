import { EmptyBackend } from './empty';
import type { AgentKeysClient } from './types';

export type BackendKind = 'empty' | 'daemon';

export function selectBackend(): AgentKeysClient {
  const kind = (process.env.NEXT_PUBLIC_AGENTKEYS_BACKEND ?? 'empty') as BackendKind;
  if (kind === 'daemon') {
    if (typeof window !== 'undefined') {
      // eslint-disable-next-line no-console
      console.warn(
        '[agentkeys] DaemonBackend not yet wired (PR-C). Falling back to EmptyBackend.',
      );
    }
    return new EmptyBackend();
  }
  return new EmptyBackend();
}

export * from './types';
export { EmptyBackend } from './empty';
