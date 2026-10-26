## Decoder / encoder concepts mirroring io/decoder.rs + io/encoder.rs
import std/options
import ./error
import ./io as iol
import ./color
import ./limits
import ./animation
import ./metadata

type
  DecodedMetadataHint* = enum
    mhUnsupported
    mhInHeader
    mhPerImage
    mhNone

  FormatAttributes* = object
    supportsAnimation*: bool
    supportsSequence*: bool
    icc*: DecodedMetadataHint
    exif*: DecodedMetadataHint
    xmp*: DecodedMetadataHint
    iptc*: DecodedMetadataHint

  DecodedAnimationAttributes* = object
    loopCount*: LoopCount

  DecodedImageAttributes* = object
    x*, y*: uint32
    delay*: Option[Delay]
    orientation*: Option[Orientation]
    originalColor*: Option[ExtendedColorType]

func defaultFormatAttributes*(): FormatAttributes = FormatAttributes()
func defaultImageAttributes*(): DecodedImageAttributes = DecodedImageAttributes()
