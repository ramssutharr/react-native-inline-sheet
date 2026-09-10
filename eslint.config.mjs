import tseslint from 'typescript-eslint';
import reactHooks from 'eslint-plugin-react-hooks';

export default tseslint.config(
  { ignores: ['node_modules/**', 'lib/**', 'android/build/**'] },
  ...tseslint.configs.recommended,
  reactHooks.configs.flat['recommended-latest'],
  {
    files: ['src/**/*.{ts,tsx}'],
    rules: {
      // The public surface mirrors gorhom's untyped `present(data)` payload and
      // hosts arbitrary React content; `any` at those boundaries is deliberate.
      '@typescript-eslint/no-explicit-any': 'off',
    },
  },
);
