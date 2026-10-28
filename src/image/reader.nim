## ImageReader + format guessing (subset of io/image_reader_type.rs + free_functions.rs)
import streams
import ./error
import ./format
import ./limits
import ./dynamic

func guessFormat*(data: openArray[uint8]): tuple[found: bool, f: ImageFormat] =
  if data.len >= 8 and data[0]==137 and data[1]==80 and data[2]==78 and
      data[3]==71 and data[4]==13 and data[5]==10 and data[6]==26 and data[7]==10:
    return (true, fmtPng)
  if data.len >= 3 and data[0]==0xFF and data[1]==0xD8 and data[2]==0xFF:
    return (true, fmtJpeg)
  if data.len >= 6 and data[0]==uint8('G') and data[1]==uint8('I') and data[2]==uint8('F'):
    return (true, fmtGif)
  if data.len >= 4 and data[0]==uint8('R') and data[1]==uint8('I') and
      data[2]==uint8('F') and data[3]==uint8('F'):
    return (true, fmtWebP)
  if data.len >= 2 and data[0]==uint8('B') and data[1]==uint8('M'):
    return (true, fmtBmp)
  if data.len >= 8 and data[0]==uint8('f') and data[1]==uint8('a') and
      data[2]==uint8('r') and data[3]==uint8('b') and data[4]==uint8('f') and
      data[5]==uint8('e') and data[6]==uint8('l') and data[7]==uint8('d'):
    return (true, fmtFarbfeld)
  if data.len >= 4 and data[0]==uint8('q') and data[1]==uint8('o') and
      data[2]==uint8('i') and data[3]==uint8('f'):
    return (true, fmtQoi)
  if data.len >= 4 and data[0]==0x52 and data[1]==0x45 and data[2]==0x44 and
      data[3]==0x20:
    return (true, fmtOpenExr)
  if data.len >= 11 and data[0]==uint8('#') and data[1]==uint8('?'):
    return (true, fmtHdr)
  if data.len >= 12 and data[4]==uint8('f') and data[5]==uint8('t') and
      data[6]==uint8('y') and data[7]==uint8('p'):
    # ftyp major brand decides; keep the list aligned with heif/isobmff
    var brand = ""
    for i in 8..<12: brand.add(char(data[i]))
    if brand == "mif1" or brand == "mif2" or brand == "msf1" or
        brand == "mif3" or brand == "heic" or brand == "heix" or
        brand == "hevc" or brand == "hevx" or brand == "vvic" or
        brand == "vvis" or brand == "avic" or brand == "avis" or
        brand == "jpeg" or brand == "j2ki" or brand == "unci" or
        brand == "miaf" or brand == "miff" or brand == "1pic" or
        brand == "pred":
      return (true, fmtHeif)
  (false, fmtPng)
