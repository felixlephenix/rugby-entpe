// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
export default defineConfig({
  site: 'https://felixlephenix.github.io',
  base: '/rugby-entpe',
  vite: {
    plugins: [tailwindcss()]
  }
});