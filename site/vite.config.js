import { defineConfig } from "vite";

export default defineConfig({
  // Relative so the same build works from a repository subpath on GitHub
  // Pages, from a bucket root, and from file:// - nothing has to know where
  // it will be served from.
  base: "./",
  build: {
    outDir: "dist",
    // The GeoJSON in public/ is copied verbatim; only the JS is bundled, and
    // maplibre-gl alone is past the default warning threshold.
    chunkSizeWarningLimit: 1200,
  },
});
