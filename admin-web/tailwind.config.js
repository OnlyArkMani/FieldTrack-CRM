/** @type {import('tailwindcss').Config} */
// The FieldTrack palette lives as CSS variables (see src/index.css) so a single
// `.dark` class flips the whole theme. Tailwind tokens point at those vars.
export default {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        bg: 'var(--ft-bg)',
        surface: 'var(--ft-surface)',
        card: 'var(--ft-card)',
        border: 'var(--ft-border)',
        primary: 'var(--ft-primary)',
        'primary-fg': 'var(--ft-primary-fg)',
        secondary: 'var(--ft-secondary)',
        danger: 'var(--ft-danger)',
        'text-primary': 'var(--ft-text)',
        'text-secondary': 'var(--ft-text-secondary)',
        'status-active': 'var(--ft-status-active)',
        'status-idle': 'var(--ft-status-idle)',
        'status-offline': 'var(--ft-status-offline)',
        'status-danger': 'var(--ft-status-danger)',
        'status-battery': 'var(--ft-status-battery)',
      },
      borderRadius: {
        card: '12px',
        btn: '8px',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
      },
      boxShadow: {
        soft: '0 2px 4px var(--ft-shadow)',
        card: '0 4px 16px var(--ft-shadow)',
      },
    },
  },
  plugins: [],
};
