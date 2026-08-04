import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

// The relay serves this bundle from `/room/native`, and any path without a dot falls
// back to index.html — so asset URLs have to be absolute or they resolve under /room/.
export default defineConfig({
  base: '/',
  plugins: [svelte()],
  build: {
    outDir: '../Resources/Renderer',
    emptyOutDir: true,
    // Source maps would ship the whole component tree into the app bundle for no gain.
    sourcemap: false,
    assetsDir: 'assets',
    rollupOptions: {
      output: {
        entryFileNames: 'assets/[name].[hash].js',
        chunkFileNames: 'assets/[name].[hash].js',
        assetFileNames: 'assets/[name].[hash][extname]',
      },
    },
  },
})
