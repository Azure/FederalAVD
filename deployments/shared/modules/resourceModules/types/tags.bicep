// Preserve resource-type tag maps used by existing callers while accepting one tag set.
// Resource-type keys contain '/', which is not allowed in Azure tag names.
@export()
func getTagsForResource(tags object, resourceType string) object =>
  tags[?resourceType] ?? (empty(filter(items(tags), item => contains(item.key, '/'))) ? tags : {})
