# Validate the schema vocabulary used by verdict.schema.json. Unknown schema
# keywords fail closed so a later contract cannot silently exceed this validator.
def matches_schema($s):
  . as $v |
  ($s | keys_unsorted - ["type", "required", "properties", "additionalProperties", "items", "enum", "minLength", "minimum"] | length == 0) and
  (if $s.type == "integer" then ($v | type == "number" and . == floor)
   else ($v | type) == $s.type end) and
  (if $s | has("enum") then ($s.enum | index($v)) != null else true end) and
  (if $s | has("minLength") then ($v | length) >= $s.minLength else true end) and
  (if $s | has("minimum") then $v >= $s.minimum else true end) and
  (if $s.type == "object" then
     all($s.required[]?; . as $key | $v | has($key)) and
     (if $s.additionalProperties == false then
        ($v | keys_unsorted - ($s.properties | keys_unsorted) | length == 0)
      else true end) and
     all($v | keys_unsorted[]; . as $key | $v[$key] | matches_schema($s.properties[$key]))
   elif $s.type == "array" then all($v[]; matches_schema($s.items))
   else true end);
select(length == 1) | .[0] |
select(type == "object" and .type == "result" and .subtype == "success" and .is_error == false) |
.structured_output |
select(matches_schema($schema[0])) |
select(.verdict != "approve" or all(.findings[]; .severity != "critical" and .severity != "high"))
