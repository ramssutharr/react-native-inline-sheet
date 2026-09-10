import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { Animated, Easing, StyleSheet, useWindowDimensions, View, type StyleProp, type ViewStyle } from 'react-native';

/**
 * Instagram-style multi-step content inside ONE sheet: routes push and pop
 * with a horizontal slide while the sheet frame stays put. A content concern,
 * not a host concern — this is plain React + `Animated` (native driver), so
 * it works inside any container. With an `auto` detent the sheet animates to
 * each route's height because the body's laid-out size changes.
 */

export type SheetRoute<P = any> = { key: string; name: string; params?: P };

export type SheetRouterNavigation = {
  push: (name: string, params?: any) => void;
  pop: () => void;
  popToTop: () => void;
  replace: (name: string, params?: any) => void;
  canGoBack: () => boolean;
  route: SheetRoute;
};

const SheetRouterContext = createContext<SheetRouterNavigation | null>(null);

export const useSheetRouter = (): SheetRouterNavigation => {
  const value = useContext(SheetRouterContext);
  if (value == null) {
    throw new Error('useSheetRouter must be used inside a <SheetRouter>');
  }
  return value;
};

export type SheetRouterScreens = Record<string, React.ComponentType<any>>;

export type SheetRouterProps = {
  initialRoute: string;
  initialParams?: any;
  screens: SheetRouterScreens;
  style?: StyleProp<ViewStyle>;
  /** Slide duration, ms. */
  duration?: number;
};

let keyCounter = 0;
const nextKey = () => `sheet-route-${++keyCounter}`;

type Transition = { from: SheetRoute; direction: 'push' | 'pop' };

export function SheetRouter({
  initialRoute,
  initialParams,
  screens,
  style,
  duration = 260,
}: SheetRouterProps) {
  const { width } = useWindowDimensions();
  const [stack, setStack] = useState<SheetRoute[]>(() => [
    { key: nextKey(), name: initialRoute, params: initialParams },
  ]);
  const [transition, setTransition] = useState<Transition | null>(null);
  const progress = useRef(new Animated.Value(1)).current;
  const current = stack[stack.length - 1]!;

  const runTransition = useCallback(
    (from: SheetRoute, direction: 'push' | 'pop') => {
      setTransition({ from, direction });
      progress.setValue(0);
      Animated.timing(progress, {
        toValue: 1,
        duration,
        easing: Easing.out(Easing.cubic),
        useNativeDriver: true,
      }).start(({ finished }) => {
        if (finished) setTransition(null);
      });
    },
    [progress, duration],
  );

  const stackRef = useRef(stack);
  useEffect(() => {
    stackRef.current = stack;
  }, [stack]);

  const push = useCallback(
    (name: string, params?: any) => {
      const from = stackRef.current[stackRef.current.length - 1]!;
      setStack(s => [...s, { key: nextKey(), name, params }]);
      runTransition(from, 'push');
    },
    [runTransition],
  );

  const pop = useCallback(() => {
    if (stackRef.current.length <= 1) return;
    const from = stackRef.current[stackRef.current.length - 1]!;
    setStack(s => s.slice(0, -1));
    runTransition(from, 'pop');
  }, [runTransition]);

  const popToTop = useCallback(() => {
    if (stackRef.current.length <= 1) return;
    const from = stackRef.current[stackRef.current.length - 1]!;
    setStack(s => s.slice(0, 1));
    runTransition(from, 'pop');
  }, [runTransition]);

  const replace = useCallback(
    (name: string, params?: any) => {
      const from = stackRef.current[stackRef.current.length - 1]!;
      setStack(s => [...s.slice(0, -1), { key: nextKey(), name, params }]);
      runTransition(from, 'push');
    },
    [runTransition],
  );

  const navigation = useMemo<SheetRouterNavigation>(
    () => ({
      push,
      pop,
      popToTop,
      replace,
      canGoBack: () => stackRef.current.length > 1,
      route: current,
    }),
    [push, pop, popToTop, replace, current],
  );

  const Current = screens[current.name];
  const From = transition ? screens[transition.from.name] : null;

  // Incoming route sits in normal flow (it defines the router's height, which
  // is what an `auto` detent reads); the outgoing one is layered over it and
  // slides away.
  const incomingX = progress.interpolate({
    inputRange: [0, 1],
    outputRange: transition?.direction === 'pop' ? [-width * 0.3, 0] : [width, 0],
  });
  const outgoingX = progress.interpolate({
    inputRange: [0, 1],
    outputRange: transition?.direction === 'pop' ? [0, width] : [0, -width * 0.3],
  });

  return (
    <SheetRouterContext.Provider value={navigation}>
      <View style={[styles.container, style]}>
        <Animated.View
          key={current.key}
          style={transition ? { transform: [{ translateX: incomingX }] } : null}
        >
          {Current ? <Current {...(current.params ?? {})} /> : null}
        </Animated.View>
        {transition && From ? (
          <Animated.View
            key={transition.from.key}
            pointerEvents="none"
            style={[styles.outgoing, { transform: [{ translateX: outgoingX }] }]}
          >
            <From {...(transition.from.params ?? {})} />
          </Animated.View>
        ) : null}
      </View>
    </SheetRouterContext.Provider>
  );
}

const styles = StyleSheet.create({
  container: { overflow: 'hidden' },
  outgoing: { position: 'absolute', top: 0, left: 0, right: 0 },
});
