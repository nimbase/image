## HEIF entity groups (clean-room, MIT).
## Covers the EntityToGroup framework used by collections: group box
## ('grpl') holding typed entries ('altr', 'ster', 'brst', 'tsyn',
## 'slid', 'prgr', 'pano', bracketing sets, album/favorite sets).
## Layout implemented from first principles: FullBox + grouping_type +
## group_id + entity_id list. Only v0 (u32 ids) is emitted; reader
## accepts v0/v1 with u32 ids.
import ./isobmff

type
  EntityGroup* = object
    grouping*: string ## 4CC, e.g. "altr"
    groupId*: uint32
    entityIds*: seq[uint32]

proc parseEntityGroups*(data: seq[uint8], meta: Box): seq[EntityGroup] =
  ## Collect groups from meta/grpl children. Unknown entries skipped.
  result = @[]
  for c in childBoxes(data, meta, 4):
    if not c.isTypeStr("grpl"): continue
    for g in childBoxes(data, c):
      let p = data[g.payloadOff ..< g.payloadOff + g.payloadLen]
      if p.len < 8: continue
      let v = p[0]
      if v > 1: continue
      var gtype = ""
      for i in 0 ..< 4: gtype.add(char(g.typ[i]))
      # payload: version+flags(4) + grouping_type is the box type itself,
      # then group_id(u32) + num_entities(u32) + entity_id[u32]
      if p.len < 12: continue
      let gid = (uint32(p[4]) shl 24) or (uint32(p[5]) shl 16) or
        (uint32(p[6]) shl 8) or uint32(p[7])
      let n = (uint32(p[8]) shl 24) or (uint32(p[9]) shl 16) or
        (uint32(p[10]) shl 8) or uint32(p[11])
      if n > 256: continue
      if p.len < 12 + 4 * int(n): continue
      var ids: seq[uint32] = @[]
      for i in 0 ..< int(n):
        let o = 12 + 4 * i
        ids.add((uint32(p[o]) shl 24) or (uint32(p[o+1]) shl 16) or
          (uint32(p[o+2]) shl 8) or uint32(p[o+3]))
      result.add(EntityGroup(grouping: gtype, groupId: gid, entityIds: ids))

proc buildEntityGroup*(g: EntityGroup): seq[uint8] =
  var payload: seq[uint8] = @[]
  payload.putU32BE(g.groupId)
  payload.putU32BE(uint32(g.entityIds.len))
  for id in g.entityIds: payload.putU32BE(id)
  makeFullBox(g.grouping, 0, 0, payload)

proc buildGroupsBox*(groups: seq[EntityGroup]): seq[uint8] =
  if groups.len == 0: return @[]
  var inner: seq[uint8] = @[]
  for g in groups:
    inner.putBytes(buildEntityGroup(g))
  makeBox("grpl", inner)
