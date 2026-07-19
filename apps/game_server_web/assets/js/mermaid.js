// Separate esbuild entry: the 2.7MB mermaid bundle is only loaded on demand
// by the MermaidDiagram hook (admin runtime page), never as part of app.js.
import "../vendor/mermaid.min.js"
