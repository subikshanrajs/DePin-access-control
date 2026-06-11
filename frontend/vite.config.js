import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  define: {
    // Required by some wagmi/viem internals
    global: 'globalThis',
  },
});