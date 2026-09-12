import type { ComponentType } from 'react';

/**
 * The bridge to Reanimated, kept optional: the library never imports it at
 * module load, so consumers without Reanimated pay nothing and see no error.
 *
 * With Reanimated present, the native `onPositionChange` (per frame while
 * the sheet moves) is read by a `useEvent` worklet on the UI thread and
 * written into shared values — gorhom's `animatedIndex` / `animatedPosition`
 * without a single JS-thread call per frame.
 */

/** The shape of a Reanimated `SharedValue` — enough to write to one without the dependency. */
export type SharedValueLike<T> = { value: T };

type ReanimatedModule = {
  useSharedValue: <T>(initial: T) => SharedValueLike<T>;
  useEvent: (handler: (event: any) => void, eventNames: string[], rebuild?: boolean) => unknown;
  createAnimatedComponent: (component: ComponentType<any>) => ComponentType<any>;
};

let cached: ReanimatedModule | null | undefined;

/** Resolved once per app; constant afterwards, so hooks gated on it stay stable. */
export function getReanimated(): ReanimatedModule | null {
  if (cached !== undefined) return cached;
  try {
    // Lazy on purpose, so Reanimated stays an optional peer.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('react-native-reanimated');
    const api = mod?.default ?? mod;
    const useSharedValue = mod?.useSharedValue ?? api?.useSharedValue;
    const useEvent = mod?.useEvent ?? api?.useEvent;
    const createAnimatedComponent = api?.createAnimatedComponent ?? mod?.createAnimatedComponent;
    cached =
      typeof useSharedValue === 'function' &&
      typeof useEvent === 'function' &&
      typeof createAnimatedComponent === 'function'
        ? { useSharedValue, useEvent, createAnimatedComponent }
        : null;
  } catch {
    cached = null;
  }
  return cached;
}

const animatedHosts = new Map<ComponentType<any>, ComponentType<any>>();

/**
 * Reanimated worklet handlers are only delivered to components Reanimated
 * wrapped itself. The wrapped host is a transparent superset of the plain
 * one, so it is used whenever Reanimated is available — the element type
 * must never change between renders (that would remount the native sheet).
 */
export function resolveHost(host: ComponentType<any>): ComponentType<any> {
  const reanimated = getReanimated();
  if (reanimated == null) return host;
  let wrapped = animatedHosts.get(host);
  if (wrapped == null) {
    wrapped = reanimated.createAnimatedComponent(host);
    animatedHosts.set(host, wrapped);
  }
  return wrapped;
}
