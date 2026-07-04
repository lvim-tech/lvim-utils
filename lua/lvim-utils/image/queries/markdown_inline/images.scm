; markdown inline images: ![description](destination "title")
; @image is the whole node (its start row anchors the inline render); @image.src is the path/URL.
(image
  (link_destination) @image.src) @image
