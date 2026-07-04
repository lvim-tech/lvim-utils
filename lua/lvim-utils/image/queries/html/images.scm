; HTML <img src="..."> — both the open-tag form (void element) and the self-closing form.
; @image is the element node; @image.src is the quoted src attribute value.
(element
  (start_tag
    (tag_name) @_tag
    (attribute
      (attribute_name) @_name
      (quoted_attribute_value (attribute_value) @image.src)))
  (#eq? @_tag "img")
  (#eq? @_name "src")) @image

(element
  (self_closing_tag
    (tag_name) @_tag
    (attribute
      (attribute_name) @_name
      (quoted_attribute_value (attribute_value) @image.src)))
  (#eq? @_tag "img")
  (#eq? @_name "src")) @image
