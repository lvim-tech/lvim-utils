; LaTeX \includegraphics[options]{path} — the graphics_include node of tree-sitter-latex.
; @image is the command node; @image.src is the {path} argument.
(graphics_include
  (curly_group_path
    (path) @image.src)) @image
